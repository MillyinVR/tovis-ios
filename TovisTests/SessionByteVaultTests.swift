import Foundation
import Testing
import TovisKit
@testable import Tovis

// SessionByteVault holds camera bytes off-heap. Its two buckets have different
// lifetimes and that difference is the whole point of these tests.
//
// The bug they pin: `.pendingUpload` used to live in Caches alongside `.harvest`
// and be swept by the same `reset()` — which runs on every camera start. So a
// photo whose upload the server refused was queued behind a Retry button that
// could never win, dismissed without warning, and then DELETED the next time the
// camera opened. `resetKeepsPendingUploads` is the regression guard; the rest
// cover the metadata that lets a stranded photo finish uploading in a later
// session (it can't be re-derived — the capture is long gone).
@Suite(.serialized)
struct SessionByteVaultTests {
    private func jpeg(_ marker: String = "bytes") -> Data { Data(marker.utf8) }

    /// Drop everything this test left in the shared vault dirs.
    private func cleanup(_ bookingIds: String...) {
        for id in bookingIds {
            for pending in SessionByteVault.strandedUploads(bookingId: id) {
                SessionByteVault.remove(pending.url)
            }
        }
        SessionByteVault.reset()
    }

    // MARK: - The regression

    @Test func resetKeepsPendingUploadsAndSweepsHarvest() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }

        let harvested = try #require(SessionByteVault.write(jpeg("harvest"), to: .harvest))
        let pending = try #require(SessionByteVault.writePendingUpload(
            jpeg("owed"), bookingId: booking, phase: .after, focal: nil, capturedAt: nil))

        SessionByteVault.reset()

        // Harvest is a disposable proposal — sweeping it is correct.
        #expect(!FileManager.default.fileExists(atPath: harvested.path))
        // The un-uploaded photo is the pro's WORK. Deleting it here is the bug.
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(SessionByteVault.read(pending) == jpeg("owed"))
    }

    @Test func pendingUploadsLiveOutsideCaches() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }

        let pending = try #require(SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .before, focal: nil, capturedAt: nil))

        // Caches is OS-reclaimable: the system may evict it under disk pressure,
        // which would lose the photo just as surely as reset() did.
        #expect(!pending.path.contains("/Caches/"))
    }

    // MARK: - Recovering enough to finish the upload

    @Test func strandedUploadRoundTripsPhaseFocalAndCapturedAt() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }
        let focal = try #require(MediaFocalPoint(x: 0.512_345, y: 0.421_098))
        // Millisecond precision, truncated to match the encoding's own rounding —
        // a sub-millisecond `Date` would never compare equal after round-tripping
        // through an Int-millis filename token.
        let capturedAt = Date(timeIntervalSince1970: 1_755_000_000.123)

        _ = SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .after, focal: focal, capturedAt: capturedAt)

        let stranded = SessionByteVault.strandedUploads(bookingId: booking)
        #expect(stranded.count == 1)
        #expect(stranded.first?.phase == .after)
        // Micro-unit encoding, so the focal survives to ~1e-6 — far finer than
        // the cover-crop needs, and with no locale-sensitive float formatting.
        #expect(abs((stranded.first?.focal?.x ?? 0) - focal.x) < 0.000_01)
        #expect(abs((stranded.first?.focal?.y ?? 0) - focal.y) < 0.000_01)
        // Millisecond round-trip — the encoding is Int epoch-millis, so it's
        // exact to the millisecond, not merely "close".
        let roundTripped = try #require(stranded.first?.capturedAt)
        #expect(abs(roundTripped.timeIntervalSince1970 - capturedAt.timeIntervalSince1970) < 0.001)
    }

    @Test func facelessShotRoundTripsAsNoFocal() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }

        _ = SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .other, focal: nil, capturedAt: nil)

        let stranded = SessionByteVault.strandedUploads(bookingId: booking)
        #expect(stranded.count == 1)
        // nil focal must stay nil — the server omits the field and the feed
        // cover-crop stays centered. A bogus 0,0 would crop to the corner.
        #expect(stranded.first?.focal == nil)
    }

    @Test func libraryImportRoundTripsAsNoCapturedAtClaim() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }

        _ = SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .other, focal: nil, capturedAt: nil)

        let stranded = SessionByteVault.strandedUploads(bookingId: booking)
        #expect(stranded.count == 1)
        // A deliberate no-claim (library import) must stay nil, not silently
        // become "now" or some other invented value.
        #expect(stranded.first?.capturedAt == nil)
    }

    @Test func legacyFourPartFilenameFallsBackToFileCreationDate() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }
        // Simulate a file written by a build that predates the capturedAt
        // field — the 4-part filename `writePendingUpload` produced before this
        // change. Written directly rather than via the current API, which can no
        // longer produce this shape.
        let dir = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first).appendingPathComponent("pending-uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyURL = dir.appendingPathComponent(
            "\(booking)__AFTER__none__\(UUID().uuidString).jpg")
        try jpeg("legacy").write(to: legacyURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: legacyURL) }

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: created], ofItemAtPath: legacyURL.path)

        let stranded = SessionByteVault.strandedUploads(bookingId: booking)
        #expect(stranded.count == 1)
        #expect(stranded.first?.phase == .after)
        let fallback = try #require(stranded.first?.capturedAt)
        #expect(abs(fallback.timeIntervalSince1970 - created.timeIntervalSince1970) < 1)
    }

    @Test func strandedUploadsAreScopedToTheBookingAndOldestFirst() throws {
        let booking = "bkg-\(UUID().uuidString)"
        let other = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking, other) }

        let older = try #require(SessionByteVault.writePendingUpload(
            jpeg("older"), bookingId: booking, phase: .before, focal: nil, capturedAt: nil))
        let newer = try #require(SessionByteVault.writePendingUpload(
            jpeg("newer"), bookingId: booking, phase: .after, focal: nil, capturedAt: nil))
        _ = SessionByteVault.writePendingUpload(
            jpeg("elsewhere"), bookingId: other, phase: .after, focal: nil, capturedAt: nil)

        // Pin creation dates so oldest-first is deterministic.
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)

        let stranded = SessionByteVault.strandedUploads(bookingId: booking)
        #expect(stranded.map(\.url) == [older, newer])
        // Another booking's owed photos must never surface in this session.
        #expect(!stranded.contains { $0.url.lastPathComponent.contains(other) })
    }

    @Test func removeReleasesAConfirmedUpload() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }

        let pending = try #require(SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .after, focal: nil, capturedAt: nil))
        SessionByteVault.remove(pending)

        #expect(SessionByteVault.strandedUploads(bookingId: booking).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
    }

    // MARK: - Draining every scope, not just one booking

    // The app-level queue drains photos with no "current booking" in hand — it
    // runs at launch, after the camera is closed, after the session is closed
    // out. `strandedUploads(bookingId:)` cannot serve it: filtering by a booking
    // is exactly what left photos stranded forever once the pro moved on.

    @Test func allPendingUploadsSpansScopesAndTagsEachWithItsOwn() throws {
        let bookingA = "bkg-\(UUID().uuidString)"
        let bookingB = "bkg-\(UUID().uuidString)"
        let practice = "practice"
        defer { cleanup(bookingA, bookingB, practice) }

        _ = SessionByteVault.writePendingUpload(
            jpeg("a"), bookingId: bookingA, phase: .before, focal: nil, capturedAt: nil)
        _ = SessionByteVault.writePendingUpload(
            jpeg("b"), bookingId: bookingB, phase: .after, focal: nil, capturedAt: nil)
        _ = SessionByteVault.writePendingUpload(
            jpeg("p"), bookingId: practice, phase: .other, focal: nil, capturedAt: nil)

        let mine = SessionByteVault.allPendingUploads()
            .filter { [bookingA, bookingB, practice].contains($0.scope) }
        #expect(mine.count == 3)
        #expect(mine.first { $0.scope == bookingA }?.phase == .before)
        #expect(mine.first { $0.scope == bookingB }?.phase == .after)
        // Practice photos are owed to the server too — a queue that skipped them
        // would leave the standalone camera exactly as broken as before.
        #expect(mine.first { $0.scope == practice }?.phase == .other)
    }

    @Test func strandedUploadsStillFiltersToItsOwnBooking() throws {
        let mine = "bkg-\(UUID().uuidString)"
        let theirs = "bkg-\(UUID().uuidString)"
        defer { cleanup(mine, theirs) }

        _ = SessionByteVault.writePendingUpload(
            jpeg("mine"), bookingId: mine, phase: .before, focal: nil, capturedAt: nil)
        _ = SessionByteVault.writePendingUpload(
            jpeg("theirs"), bookingId: theirs, phase: .before, focal: nil, capturedAt: nil)

        let scoped = SessionByteVault.strandedUploads(bookingId: mine)
        #expect(scoped.count == 1)
        #expect(scoped.first?.scope == mine)
    }

    @Test func allPendingUploadsCarriesTheMetadataNeededToFinishTheUpload() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }
        let moment = Date(timeIntervalSince1970: 1_787_265_806.478)
        let focal = try #require(MediaFocalPoint(x: 0.25, y: 0.75))

        _ = SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .after, focal: focal, capturedAt: moment)

        let found = try #require(
            SessionByteVault.allPendingUploads().first { $0.scope == booking })
        #expect(found.phase == .after)
        #expect(found.focal == focal)
        // The real shutter moment, not whenever the upload happens to run.
        #expect(abs((found.capturedAt ?? .distantPast).timeIntervalSince(moment)) < 0.01)
    }
}
