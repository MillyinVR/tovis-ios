// Claude-vision camera features (Phase D) — shared consent + payload plumbing
// for the two flows that send a photo OFF the device for AI analysis: the
// "Match a look" AI-enhance (ProCapturePhotosView) and the wrap-up set
// critique (ProSessionHubView). Everything else in the camera stays on-device.
//
// Consent: one explicit opt-in (persisted) covers both flows; the first use
// shows a plain one-line disclosure before anything uploads. The server
// analyzes in-flight and stores nothing (tovis-app PR #454).
import TovisKit
import UIKit

enum CameraVisionConsent {
    private static let key = "tovis.camera.ai.consented"

    /// The one-line disclosures (single photo / photo set variants).
    static let lookDisclosure =
        "This photo leaves your device for AI analysis by Claude (Anthropic). It isn't stored."
    static let critiqueDisclosure =
        "These photos leave your device for AI analysis by Claude (Anthropic). They aren't stored."

    static var granted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum CameraVisionPayload {
    /// Downscale + JPEG-encode an image for an analysis request body. Claude
    /// reads nothing above ~1568 px on the long edge, and the request has to
    /// stay well under the server's body cap — so shrink before base64.
    static func imagePayload(_ image: UIImage, maxDimension: CGFloat,
                             quality: CGFloat) -> ProCameraVisionImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded(.down)),
                            height: max(1, (size.height * scale).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        guard let jpeg = scaled.jpegData(compressionQuality: quality) else { return nil }
        return ProCameraVisionImage(base64: jpeg.base64EncodedString())
    }
}
