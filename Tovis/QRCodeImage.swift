// Renders a QR code image for a string using CoreImage's built-in generator —
// no third-party dependency. Used by the client invite card to show the
// /c/{code} share URL as a scannable code, matching the web referrals
// InviteLinkCard's inline QR (which encodes the same absolute URL via
// lib/media/qr `qrSvgFor`). Error-correction level "M" matches web's.
import CoreImage.CIFilterBuiltins
import UIKit

enum QRCodeImage {
    /// A crisp black-on-white QR image encoding `string`, or nil when it can't be
    /// produced (empty/blank input, or a payload too large for the generator).
    ///
    /// `scale` upsamples the raw module grid (CoreImage emits ~1px per module) so
    /// the image stays sharp when drawn at display size; render it with
    /// `.interpolation(.none)` to keep the modules square. The image is always
    /// square (a QR symbol is NxN modules).
    static func generate(from string: String, scale: CGFloat = 12) -> UIImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(trimmed.utf8)
        filter.correctionLevel = "M"   // parity with web's errorCorrectionLevel: 'M'

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
