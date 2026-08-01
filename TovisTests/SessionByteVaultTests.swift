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
            jpeg("owed"), bookingId: booking, phase: .after, focal: nil))

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
            jpeg(), bookingId: booking, phase: .before, focal: nil))

        // Caches is OS-reclaimable: the system may evict it under disk pressure,
        // which would lose the photo just as surely as reset() did.
        #expect(!pending.path.contains("/Caches/"))
    }

    // MARK: - Recovering enough to finish the upload

    @Test func strandedUploadRoundTripsPhaseAndFocal() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }
        let focal = try #require(MediaFocalPoint(x: 0.512_345, y: 0.421_098))

        _ = SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .after, focal: focal)

        let stranded = SessionByteVault.strandedUploads(bookingId: booking)
        #expect(stranded.count == 1)
        #expect(stranded.first?.phase == .after)
        // Micro-unit encoding, so the focal survives to ~1e-6 — far finer than
        // the cover-crop needs, and with no locale-sensitive float formatting.
        #expect(abs((stranded.first?.focal?.x ?? 0) - focal.x) < 0.000_01)
        #expect(abs((stranded.first?.focal?.y ?? 0) - focal.y) < 0.000_01)
    }

    @Test func facelessShotRoundTripsAsNoFocal() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }

        _ = SessionByteVault.writePendingUpload(
            jpeg(), bookingId: booking, phase: .other, focal: nil)

        let stranded = SessionByteVault.strandedUploads(bookingId: booking)
        #expect(stranded.count == 1)
        // nil focal must stay nil — the server omits the field and the feed
        // cover-crop stays centered. A bogus 0,0 would crop to the corner.
        #expect(stranded.first?.focal == nil)
    }

    @Test func strandedUploadsAreScopedToTheBookingAndOldestFirst() throws {
        let booking = "bkg-\(UUID().uuidString)"
        let other = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking, other) }

        let older = try #require(SessionByteVault.writePendingUpload(
            jpeg("older"), bookingId: booking, phase: .before, focal: nil))
        let newer = try #require(SessionByteVault.writePendingUpload(
            jpeg("newer"), bookingId: booking, phase: .after, focal: nil))
        _ = SessionByteVault.writePendingUpload(
            jpeg("elsewhere"), bookingId: other, phase: .after, focal: nil)

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
            jpeg(), bookingId: booking, phase: .after, focal: nil))
        SessionByteVault.remove(pending)

        #expect(SessionByteVault.strandedUploads(bookingId: booking).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
    }
}
