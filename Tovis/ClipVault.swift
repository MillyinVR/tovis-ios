// Owns recorded session clips from "stop recording" until they're confirmed
// uploaded. tmp isn't safe custody: files there can vanish on exit and the old
// review flow deleted them on close — which silently lost clips. Clips move
// here the moment recording stops, upload in the background, and are removed
// only after the server confirms — so a crash, a killed app, offline, or a
// dismissed sheet never loses a take. Anything stranded (crash mid-upload,
// upload that kept failing) is re-queued the next time the camera opens for
// that booking.
import AVFoundation
import UIKit
import TovisKit

@MainActor
enum ClipVault {
    /// Clips awaiting upload, one file per take: `<bookingId>__<phase>__<uuid>.mov`.
    private static var baseDir: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = support.appendingPathComponent("pending-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Uploads currently in flight — a stranded-clip sweep must never re-launch
    /// a clip that's already uploading (two presigns would mint two assets).
    private static var inFlight: Set<URL> = []

    /// Move a just-recorded tmp clip into the vault. Falls back to the original
    /// URL if the move fails — uploading from tmp beats losing the take.
    static func stash(_ url: URL, bookingId: String, phase: MediaPhase) -> URL {
        guard let dir = baseDir else { return url }
        let name = "\(bookingId)__\(phase.rawValue)__\(UUID().uuidString).mov"
        let destination = dir.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    /// The clip is safely recorded server-side — release the local copy.
    static func remove(_ url: URL) {
        inFlight.remove(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// Clips stranded by a crash, offline exit, or exhausted retries — oldest
    /// first so the session's story uploads in order.
    static func strandedClips(bookingId: String) -> [(url: URL, phase: MediaPhase)] {
        guard let dir = baseDir,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.creationDateKey]
              ) else { return [] }
        return entries
            .filter { !inFlight.contains($0) }
            .compactMap { url -> (URL, MediaPhase, Date)? in
                let parts = url.deletingPathExtension().lastPathComponent
                    .components(separatedBy: "__")
                guard parts.count == 3, parts[0] == bookingId,
                      let phase = MediaPhase(rawValue: parts[1]) else { return nil }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast
                return (url, phase, created)
            }
            .sorted { $0.2 < $1.2 }
            .map { ($0.0, $0.1) }
    }

    /// Claim a clip for upload. False = someone already has it in flight.
    static func beginUpload(_ url: URL) -> Bool {
        inFlight.insert(url).inserted
    }

    static func endUpload(_ url: URL) {
        inFlight.remove(url)
    }

    /// JPEG poster frame for the clip's gallery tile — galleries can't decode a
    /// frame out of a signed .mov URL, so the row carries a real image thumb.
    /// Bounded decode (≤720px) like every other display path in the camera.
    nonisolated static func poster(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8)
    }
}
