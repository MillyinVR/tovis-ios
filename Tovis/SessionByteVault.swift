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
        /// CLIENT consult capture shots whose issue→upload→attach→quality chain
        /// hasn't finished. Durable, and deliberately a SEPARATE directory from
        /// `.pendingUpload`: that bucket is drained by `SessionUploadQueue`
        /// against the PRO media endpoints, and a consult shot landing in it
        /// would be presigned as booking media. Two owed-photo queues, two
        /// namespaces, no way for one to pick up the other's work.
        case consultCapture = "consult-captures"

        /// Harvest is disposable, so Caches (OS-reclaimable) is correct.
        /// Un-uploaded photos are the pro's work — Application Support, like
        /// `ClipVault`, because Caches can be evicted under disk pressure. A
        /// consult shot is the CLIENT's work and owed to the server in exactly
        /// the same way, so it gets the same durable domain.
        var domain: FileManager.SearchPathDirectory {
            switch self {
            case .harvest: return .cachesDirectory
            case .pendingUpload, .consultCapture: return .applicationSupportDirectory
            }
        }
    }

    /// One photo still owed to the server, recovered from disk.
    struct PendingUpload: Equatable {
        let url: URL
        /// The custody namespace these bytes were written under — a bookingId
        /// for a session shoot, `"practice"` for the standalone camera. The
        /// app-level uploader reads it to decide which endpoint owes them.
        let scope: String
        let phase: MediaPhase
        let focal: MediaFocalPoint?
        /// Device-claimed capture time — nil when the caller genuinely has no
        /// trustworthy one (a library import; see `writePendingUpload`), or when
        /// this file predates the field and was recovered via the legacy 4-part
        /// filename fallback (the file's own creation date, not a real claim).
        let capturedAt: Date?
    }

    private static func directory(_ bucket: Bucket) -> URL? {
        guard let root = FileManager.default.urls(
            for: bucket.domain, in: .userDomainMask
        ).first else { return nil }
        var dir = root.appendingPathComponent(bucket.rawValue, isDirectory: true)
        if let suffix = ConsultCaptureVaultIsolation.suffix {
            dir = dir.appendingPathComponent(suffix, isDirectory: true)
        }
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
    /// retry it in a LATER camera session:
    /// `<bookingId>__<phase>__<focal>__<capturedAt>__<uuid>.jpg`.
    /// (Same filename-as-metadata idiom as `ClipVault`, so there's one convention
    /// for pending camera work rather than two.)
    ///
    /// `capturedAt` is required (not defaulted) so every call site makes a
    /// deliberate choice: a real device timestamp for an actual camera capture,
    /// or explicit `nil` for a library import, which has no trustworthy capture
    /// time to claim (see `ProCapturePhotosView.importFromLibrary`). It has to be
    /// persisted here, not resampled at upload time — bytes can retry hours or
    /// days later (background retry, or the stranded-upload sweep on a later
    /// relaunch), and resampling would silently replace "when this was captured"
    /// with "when this happened to upload".
    static func writePendingUpload(
        _ data: Data,
        bookingId: String,
        phase: MediaPhase,
        focal: MediaFocalPoint?,
        capturedAt: Date?
    ) -> URL? {
        guard let dir = directory(.pendingUpload) else { return nil }
        let name = [
            bookingId, phase.rawValue, encode(focal), encode(capturedAt), UUID().uuidString,
        ].joined(separator: "__")
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
    ///
    /// Parses two filename shapes: the current 5-part one (with an encoded
    /// `capturedAt`), and the 4-part one written before that field existed — a
    /// file already sitting in `.pendingUpload` when the app updates. A legacy
    /// file's `capturedAt` falls back to the file's own creation date: this vault
    /// write already happened synchronously right after capture (same as today),
    /// so the filesystem timestamp is a reasonable proxy for a build that simply
    /// didn't encode the real one yet — distinct from a library import's
    /// deliberate `nil`, which is "no trustworthy claim available", not "unknown
    /// because of when this file was written".
    static func strandedUploads(bookingId: String) -> [PendingUpload] {
        pendingUploads(scope: bookingId)
    }

    /// Every photo still owed to the server, across ALL scopes — what the
    /// app-level uploader drains. Oldest first, same as `strandedUploads`.
    ///
    /// 🔴 This is deliberately not scoped to a booking: the whole point of the
    /// durable queue is that it keeps uploading after the camera closes, after
    /// the session is closed out, and after a relaunch — none of which have a
    /// "current booking" to filter on. Each entry carries its own `scope`.
    static func allPendingUploads() -> [PendingUpload] {
        pendingUploads(scope: nil)
    }

    /// Shared filename parser. `scope == nil` lists every namespace.
    ///
    /// Parses two filename shapes: the current 5-part one (with an encoded
    /// `capturedAt`), and the 4-part one written before that field existed — a
    /// file already sitting in `.pendingUpload` when the app updates. A legacy
    /// file's `capturedAt` falls back to the file's own creation date: this vault
    /// write already happened synchronously right after capture (same as today),
    /// so the filesystem timestamp is a reasonable proxy for a build that simply
    /// didn't encode the real one yet — distinct from a library import's
    /// deliberate `nil`, which is "no trustworthy claim available", not "unknown
    /// because of when this file was written".
    private static func pendingUploads(scope: String?) -> [PendingUpload] {
        guard let dir = directory(.pendingUpload),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.creationDateKey]
              ) else { return [] }
        return entries
            .compactMap { url -> (PendingUpload, Date)? in
                let parts = url.deletingPathExtension().lastPathComponent
                    .components(separatedBy: "__")
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast

                guard parts.count == 5 || parts.count == 4 else { return nil }
                guard scope == nil || parts[0] == scope,
                      let phase = MediaPhase(rawValue: parts[1]) else { return nil }
                let upload = PendingUpload(
                    url: url,
                    scope: parts[0],
                    phase: phase,
                    focal: decode(parts[2]),
                    // A 4-part name predates the capturedAt segment entirely.
                    capturedAt: parts.count == 5 ? decodeCapturedAt(parts[3]) : created
                )
                return (upload, created)
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

    // MARK: - Consult capture custody

    /// One consult shot still owed to the server, recovered from disk.
    ///
    /// ⚠️ Unlike `.pendingUpload`, the metadata does NOT ride in the filename.
    /// A consult item carries seven fields — including a server-defined
    /// `shotKey` and three idempotency keys — and a `__`-joined name would put
    /// the whole chain at the mercy of a future pack key that happens to
    /// contain the separator. So each item is a pair: `<uuid>.jpg` holding the
    /// bytes and `<uuid>.json` holding the manifest. The directory listing is
    /// still the whole source of truth (there is no central index to lose), and
    /// the JPEG is still the thing that says "this is owed".
    struct ConsultCaptureItem: Codable, Equatable, Identifiable {
        let id: UUID
        let consultId: String
        let shotKey: ConsultCaptureShotKey
        let shotPackVersion: Int
        let schemaVersion: Int
        let sizeBytes: Int
        let capturedAt: Date
        /// The three keys the whole chain replays under. Rotated ONLY when the
        /// server says this ticket is past saving; see the queue.
        var keys: ConsultCaptureMutationKeys
        /// The issued ticket, once leg 1 has run.
        var uploadSessionId: String?
        /// The object path the signed URL wrote to — how a background task that
        /// outlived its process is matched back to this item.
        var storagePath: String?
        /// Set once storage has accepted the bytes (or is believed to have).
        var bytesUploaded: Bool
        /// Set once the attach leg has bound a `ConsultCapture` row.
        var captureId: String?
        /// Set once the server has REFUSED this photo in a way retrying cannot
        /// fix. The bytes are kept: a refusal is the one case where this copy
        /// is the only one that exists.
        var blockedReason: String?

        var isBlocked: Bool { blockedReason != nil }
    }

    /// Spill a consult shot the instant the shutter fires, with everything the
    /// chain needs to finish it in a later process.
    ///
    /// Order matters: the manifest is written FIRST and the bytes second, so a
    /// crash between the two can only ever leave a manifest with no photo —
    /// swept below — never a photo whose identity is unknowable.
    static func writeConsultCapture(
        _ data: Data,
        consultId: String,
        shotKey: ConsultCaptureShotKey,
        shotPackVersion: Int,
        schemaVersion: Int,
        capturedAt: Date
    ) -> ConsultCaptureItem? {
        guard let dir = directory(.consultCapture), !data.isEmpty else { return nil }
        let item = ConsultCaptureItem(
            id: UUID(),
            consultId: consultId,
            shotKey: shotKey,
            shotPackVersion: shotPackVersion,
            schemaVersion: schemaVersion,
            sizeBytes: data.count,
            capturedAt: capturedAt,
            keys: ConsultCaptureMutationKeys(),
            uploadSessionId: nil,
            storagePath: nil,
            bytesUploaded: false,
            captureId: nil,
            blockedReason: nil
        )
        guard saveConsultCapture(item) else { return nil }
        guard write(data, to: dir, named: "\(item.id.uuidString).jpg") != nil else {
            try? FileManager.default.removeItem(at: consultManifestURL(item.id, in: dir))
            return nil
        }
        return item
    }

    /// Persist a changed manifest. Atomic, so a kill mid-write leaves the
    /// previous manifest rather than a truncated one.
    @discardableResult
    static func saveConsultCapture(_ item: ConsultCaptureItem) -> Bool {
        guard let dir = directory(.consultCapture),
              let encoded = try? JSONEncoder().encode(item) else { return false }
        do {
            try encoded.write(to: consultManifestURL(item.id, in: dir), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The bytes for one consult item.
    static func consultCaptureBytes(_ id: UUID) -> URL? {
        guard let dir = directory(.consultCapture) else { return nil }
        let url = consultBytesURL(id, in: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every consult shot still owed, across every consult. Oldest first, so a
    /// pack uploads in the order it was shot.
    ///
    /// 🔴 Deliberately not scoped to one consult: the whole point of the durable
    /// queue is that it keeps working after the flow is closed and after a
    /// relaunch, neither of which has a "current consult" to filter on.
    static func allConsultCaptures() -> [ConsultCaptureItem] {
        guard let dir = directory(.consultCapture),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil
              ) else { return [] }
        let decoder = JSONDecoder()
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { manifest -> ConsultCaptureItem? in
                guard let data = try? Data(contentsOf: manifest),
                      let item = try? decoder.decode(ConsultCaptureItem.self, from: data)
                else { return nil }
                // A manifest whose photo is gone is a crash between the two
                // writes, or bytes released without their manifest. Nothing is
                // owed for it, and leaving it would re-offer a photo that no
                // longer exists on every launch.
                guard FileManager.default.fileExists(
                    atPath: consultBytesURL(item.id, in: dir).path
                ) else {
                    try? FileManager.default.removeItem(at: manifest)
                    return nil
                }
                return item
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Release one consult item — bytes and manifest — once the server has a
    /// quality verdict for it, or when the client withdraws consent.
    static func removeConsultCapture(_ id: UUID) {
        guard let dir = directory(.consultCapture) else { return }
        try? FileManager.default.removeItem(at: consultBytesURL(id, in: dir))
        try? FileManager.default.removeItem(at: consultManifestURL(id, in: dir))
    }

    private static func consultBytesURL(_ id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("\(id.uuidString).jpg")
    }

    private static func consultManifestURL(_ id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
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

    // MARK: - capturedAt encoding

    /// `capturedAt` as a filename-safe token: epoch milliseconds (an Int, so no
    /// locale-sensitive float formatting — same reasoning as the focal encoding
    /// above), or "none" for a deliberate no-claim (a library import).
    private static func encode(_ capturedAt: Date?) -> String {
        guard let capturedAt else { return "none" }
        return String(Int((capturedAt.timeIntervalSince1970 * 1000).rounded()))
    }

    private static func decodeCapturedAt(_ token: String) -> Date? {
        guard let millis = Int(token) else {
            return nil   // "none", or a token written by a build that predates this
        }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
