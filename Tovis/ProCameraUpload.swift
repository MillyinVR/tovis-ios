// The one place a shot leaves the camera.
//
// Three surfaces upload a still: the shutter path in `ProCapturePhotosView`, the
// best-shots tray, and the frame scrubber. Before the standalone camera existed
// each called `proMedia.uploadSessionPhoto(bookingId:phase:…)` directly, which
// was fine while there was only ever a booking to send it to. There isn't now —
// so the choice of endpoint lives here, once, keyed on the destination.
//
// Deliberately NOT a protocol or an injected client: it is a pure fan-out over
// `ProCameraDestination`, and the interesting behaviour (retry classification,
// the byte vault, custody) stays with the caller that owns the bytes.
import Foundation
import TovisKit

enum ProCameraUpload {
    /// Send one JPEG to wherever this shoot's shots belong.
    ///
    /// `phaseOverride` exists for the session case only: a BEFORE photo stranded
    /// by a crash gets swept up during a later AFTER shoot and must still land in
    /// BEFORE. Practice has no phases, so it is ignored there.
    ///
    /// Throws whatever the underlying service throws — `APIError.isRetryable`
    /// still classifies a dropped connection vs a refusal, which is what the
    /// caller's custody logic branches on.
    static func photo(
        _ data: Data,
        focal: MediaFocalPoint?,
        to destination: ProCameraDestination,
        phaseOverride: MediaPhase? = nil,
        client: TovisClient
    ) async throws {
        switch destination {
        case let .session(bookingId, phase):
            try await client.proMedia.uploadSessionPhoto(
                bookingId: bookingId,
                phase: phaseOverride ?? phase,
                imageData: data,
                focal: focal
            )
        case .practice:
            try await client.proPractice.upload(imageData: data, focal: focal)
        }
    }
}
