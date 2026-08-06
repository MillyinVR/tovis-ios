// Off-heap custody for camera JPEG bytes that would otherwise be pinned in RAM:
// auto-harvested best shots and photos whose upload hasn't landed yet. A
// full-sensor capture is ~5–10 MB, and holding dozens of them (a 24-shot harvest
// tray, a retry queue that grows on a dead connection) is exactly what has
// jetsam-killed this camera mid-session. So the bytes live on disk and only
// lightweight references (a 640px tray thumbnail, a retry URL) stay in memory.
//
// ⚠️ The two buckets have DIFFERENT lifetimes, and the difference is load-bearing:
//
//   • `.harvest` — session-scoped, in Caches. Auto-harvested stills are proposals
//     the pro either promotes or ignores; nothing is lost by discarding them, so
//     they're swept on the next camera start (`reset()`) and Caches' OS-reclaimable
//     contract is exactly right.
//
//   • `.pendingUpload` — DURABLE, in Application Support, keyed by booking. These
//     are photos the pro already took and the server has not accepted yet. They
//     used to live in Caches and be swept by the same `reset()`, which meant a
//     shot whose upload failed was deleted the next time the camera opened —
//     silently, with no warning on exit and no way to get it back. Custody now
//     matches `ClipVault`'s: bytes survive a crash, a kill, offline, and a
//     dismissed sheet, and are released only once the upload is confirmed or the
//     pro explicitly discards them.
//
// Keyed by UUID filenames, so every operation is independent — no shared mutable
// state, callable from any thread (the frame/harvest queues and the main actor).
// The "don't re-upload something already in flight" guard lives with the queue
// that owns it (the capture view's `failedUploads`), not here.
import Foundation
import TovisKit

enum SessionByteVault {
    /// The two kinds of spilled bytes. Each gets its own directory — in a
    /// different domain — so a sweep never crosses the streams.
    enum Bucket: String {
        /// Auto-harvested best-shot stills awaiting review. Session-scoped.
        case harvest = "harvested-shots"
        /// Captured photos whose upload hasn't been confirmed. Durable.
        case pendingUpload = "pending-uploads"

        /// Harvest is disposable, so Caches (OS-reclaimable) is correct.
        /// Un-uploaded photos are the pro's work — Application Support, like
        /// `ClipVault`, because Caches can be evicted under disk pressure.
        var domain: FileManager.SearchPathDirectory {
            switch self {
            case .harvest: return .cachesDirectory
            case .pendingUpload: return .applicationSupportDirectory
            }
        }
    }

    /// One photo still owed to the server, recovered from disk.
    struct PendingUpload: Equatable {
        let url: URL
        let phase: MediaPhase
        let focal: MediaFocalPoint?
    }

    private static func directory(_ bucket: Bucket) -> URL? {
        guard let root = FileManager.default.urls(
            for: bucket.domain, in: .userDomainMask
        ).first else { return nil }
        let dir = root.appendingPathComponent(bucket.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Spill `data` to disk and return its URL — nil if it couldn't be written,
    /// so the caller only ever records a reference to bytes that actually exist.
    /// For `.pendingUpload` prefer `writePendingUpload`, which also records the
    /// booking/phase/focal needed to finish the upload after a relaunch.
    static func write(_ data: Data, to bucket: Bucket) -> URL? {
        guard let dir = directory(bucket) else { return nil }
        return write(data, to: dir, named: "\(UUID().uuidString).jpg")
    }

    /// Spill a photo whose upload hasn't landed, tagged with everything needed to
    /// retry it in a LATER camera session: `<bookingId>__<phase>__<focal>__<uuid>.jpg`.
    /// (Same filename-as-metadata idiom as `ClipVault`, so there's one convention
    /// for pending camera work rather than two.)
    static func writePendingUpload(
        _ data: Data,
        bookingId: String,
        phase: MediaPhase,
        focal: MediaFocalPoint?
    ) -> URL? {
        guard let dir = directory(.pendingUpload) else { return nil }
        let name = [bookingId, phase.rawValue, encode(focal), UUID().uuidString]
            .joined(separator: "__")
        return write(data, to: dir, named: "\(name).jpg")
    }

    private static func write(_ data: Data, to dir: URL, named name: String) -> URL? {
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Read spilled bytes back (for upload). Nil if the file is gone.
    nonisolated static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Release one spilled file once its bytes are safely uploaded (or discarded).
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Photos still owed to the server for this booking — stranded by a crash, a
    /// kill, an offline exit, or exhausted retries. Oldest first, so the session's
    /// story uploads in the order it was shot.
    static func strandedUploads(bookingId: String) -> [PendingUpload] {
        guard let dir = directory(.pendingUpload),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.creationDateKey]
              ) else { return [] }
        return entries
            .compactMap { url -> (PendingUpload, Date)? in
                let parts = url.deletingPathExtension().lastPathComponent
                    .components(separatedBy: "__")
                guard parts.count == 4, parts[0] == bookingId,
                      let phase = MediaPhase(rawValue: parts[1]) else { return nil }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast
                return (PendingUpload(url: url, phase: phase, focal: decode(parts[2])), created)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Wipe the session-scoped bucket — called when a camera session starts, so
    /// harvest spills stranded by a previous dismiss or crash clear themselves
    /// then. (Only one camera session is ever live, so this never races an active
    /// one.)
    ///
    /// 🔴 `.pendingUpload` is deliberately NOT swept: those bytes are photos the
    /// server hasn't accepted yet, and deleting them here is precisely how a
    /// failed AFTER photo used to vanish between sessions. They're released by
    /// `remove(_:)` on a confirmed upload or an explicit discard — nowhere else.
    static func reset() {
        guard let dir = directory(.harvest),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil
              ) else { return }
        for url in entries { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Focal encoding

    /// Focal as a filename-safe token. Coordinates are validated to a finite
    /// [0,1] by `MediaFocalPoint`, so fixed-point micro-units round-trip without
    /// a separator clash or any locale-sensitive float formatting.
    private static func encode(_ focal: MediaFocalPoint?) -> String {
        guard let focal else { return "none" }
        return "\(Int((focal.x * 1_000_000).rounded()))-\(Int((focal.y * 1_000_000).rounded()))"
    }

    private static func decode(_ token: String) -> MediaFocalPoint? {
        let parts = token.components(separatedBy: "-")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            return nil   // "none", or a token written by a build that predates this
        }
        return MediaFocalPoint(x: x / 1_000_000, y: y / 1_000_000)
    }
}
