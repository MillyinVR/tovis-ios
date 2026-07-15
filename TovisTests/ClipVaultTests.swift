import Foundation
import Testing
import TovisKit
@testable import Tovis

// ClipVault owns recorded clips from "stop recording" until the server confirms
// the upload — so a crash / kill / offline / dismissed sheet never loses a take.
// These exercise the pure custody logic (move, filename keying, stranded sweep,
// in-flight guard, cleanup) on the filesystem; no camera needed.
@Suite(.serialized) @MainActor
struct ClipVaultTests {
    private func makeTempMov() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mov")
        try Data("fake-movie".utf8).write(to: url)
        return url
    }

    /// Drop every clip this test left behind (in-flight ones too) so the shared
    /// vault dir + static in-flight set don't leak across the serialized suite.
    private func cleanup(_ bookingId: String) {
        for clip in ClipVault.strandedClips(bookingId: bookingId) {
            ClipVault.endUpload(clip.url)
            ClipVault.remove(clip.url)
        }
    }

    @Test func stashMovesFileIntoVaultKeyedByBookingAndPhase() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }
        let src = try makeTempMov()

        let dest = ClipVault.stash(src, bookingId: booking, phase: .before)

        #expect(dest != src)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        // MOVED into custody, not copied — tmp isn't safe storage.
        #expect(!FileManager.default.fileExists(atPath: src.path))

        let parts = dest.deletingPathExtension().lastPathComponent
            .components(separatedBy: "__")
        #expect(parts.count == 3)
        #expect(parts[0] == booking)
        #expect(parts[1] == MediaPhase.before.rawValue)
        #expect(dest.pathExtension == "mov")
    }

    @Test func strandedClipsReturnsBookingClipsOldestFirstAndExcludesOthers() throws {
        let booking = "bkg-\(UUID().uuidString)"
        let other = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking); cleanup(other) }

        let older = ClipVault.stash(try makeTempMov(), bookingId: booking, phase: .before)
        let newer = ClipVault.stash(try makeTempMov(), bookingId: booking, phase: .after)
        _ = ClipVault.stash(try makeTempMov(), bookingId: other, phase: .before)

        // Pin creation dates so the oldest-first ordering is deterministic.
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)

        let stranded = ClipVault.strandedClips(bookingId: booking)
        #expect(stranded.count == 2)                        // other booking excluded
        #expect(stranded.map(\.phase) == [.before, .after]) // oldest first
    }

    @Test func inFlightClipsAreExcludedUntilReleased() throws {
        let booking = "bkg-\(UUID().uuidString)"
        defer { cleanup(booking) }
        let dest = ClipVault.stash(try makeTempMov(), bookingId: booking, phase: .before)

        #expect(ClipVault.beginUpload(dest) == true)
        // A second claim is refused — two presigns would mint two assets.
        #expect(ClipVault.beginUpload(dest) == false)
        #expect(ClipVault.strandedClips(bookingId: booking).isEmpty)

        ClipVault.endUpload(dest)
        #expect(ClipVault.strandedClips(bookingId: booking).map(\.url) == [dest])
    }

    @Test func removeDeletesTheFile() throws {
        let booking = "bkg-\(UUID().uuidString)"
        let dest = ClipVault.stash(try makeTempMov(), bookingId: booking, phase: .before)

        ClipVault.remove(dest)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(ClipVault.strandedClips(bookingId: booking).isEmpty)
    }
}
