// Off-heap custody for session-scoped JPEG bytes the camera would otherwise pin
// in RAM: auto-harvested best shots and failed-upload retries. A full-sensor
// capture is ~5–10 MB, and holding dozens of them (a 24-shot harvest tray, a
// retry queue that grows on a dead connection) is exactly what has jetsam-killed
// this camera mid-session. So the bytes live in a Caches subdirectory and only
// lightweight references (a 640px tray thumbnail, a retry URL) stay in memory.
//
// Unlike `ClipVault` — which keeps recorded clips in Application Support across
// crashes until the server confirms them — these buckets are session-scoped:
// the store is swept when a camera session starts (`reset()`), so bytes never
// outlive the session that produced them. Caches is the right home for that
// (OS-reclaimable, matches the "discarded on exit" contract of both buckets).
//
// Keyed by UUID filenames, so every operation is independent — no shared mutable
// state, callable from any thread (the frame/harvest queues and the main actor).
import Foundation

enum SessionByteVault {
    /// The two kinds of spilled bytes. Each gets its own subdirectory so a sweep
    /// (or a stray listing) never crosses the streams.
    enum Bucket: String {
        /// Auto-harvested best-shot stills awaiting review.
        case harvest = "harvested-shots"
        /// Captured photos whose upload failed, kept for the retry pill.
        case pendingUpload = "pending-uploads"
    }

    private static func directory(_ bucket: Bucket) -> URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = caches.appendingPathComponent(bucket.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Spill `data` to disk and return its URL — nil if it couldn't be written,
    /// so the caller only ever records a reference to bytes that actually exist.
    static func write(_ data: Data, to bucket: Bucket) -> URL? {
        guard let dir = directory(bucket) else { return nil }
        let url = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Read spilled bytes back (for upload). Nil if the file is gone.
    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Release one spilled file once its bytes are safely uploaded (or discarded).
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Wipe every session-scoped bucket — called when a camera session starts, so
    /// anything stranded by a previous dismiss or crash clears itself then. (Only
    /// one camera session is ever live, so this never races an active session.)
    static func reset() {
        for bucket in [Bucket.harvest, .pendingUpload] {
            guard let dir = directory(bucket),
                  let entries = try? FileManager.default.contentsOfDirectory(
                      at: dir, includingPropertiesForKeys: nil
                  ) else { continue }
            for url in entries { try? FileManager.default.removeItem(at: url) }
        }
    }
}
