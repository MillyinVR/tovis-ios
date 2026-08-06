// Writes a captured JPEG to the pro's own photo library.
//
// This is the camera's escape hatch, not a feature: when the server REFUSES a
// photo (a 4xx it will repeat forever), retrying can never work, so the only
// honest options are "leave with the photo" or "drop it". Before this existed
// there was no way to get refused bytes off the device at all — they sat behind
// a Retry button that couldn't win and were deleted on the next camera launch.
//
// Add-only authorization on purpose: the camera never needs to READ the pro's
// library here, and add-only is the narrower prompt (`NSPhotoLibraryAddUsage-
// Description`). Reading — the "match a look" picker — goes through SwiftUI's
// `PhotosPicker`, which is out-of-process and needs no permission at all.
import Photos

enum PhotoLibrarySaver {
    /// Save one JPEG. `false` covers both a declined prompt and a failed write —
    /// the caller keeps custody of the bytes either way, so a refusal here never
    /// loses the photo.
    static func save(_ jpeg: Data) async -> Bool {
        guard await authorized() else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                // `forAsset` + raw resource data keeps the original JPEG bytes —
                // including the EXIF orientation the web gallery reads — instead
                // of a UIImage round-trip that would re-encode and drop it.
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .photo, data: jpeg, options: nil)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Save one video, from a FILE URL rather than `Data` — unlike a photo
    /// resource, Photos needs a real container on disk to import a video from;
    /// the raw-`Data` overload has no file-extension hint for it to read the
    /// format from. `false` covers both a declined prompt and a failed write,
    /// same as `save(_:)` — the caller keeps custody of the file either way.
    static func saveVideo(fileURL: URL) async -> Bool {
        guard await authorized() else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .video, fileURL: fileURL, options: nil)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Current add-only permission, prompting once if the pro hasn't been asked.
    private static func authorized() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            return granted(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
        }
        return granted(current)
    }

    /// `.limited` grants adding too — treat it as permission, not a refusal.
    private static func granted(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }
}
