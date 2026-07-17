import Foundation
import Testing
import UIKit
@testable import Tovis

// The QR generator is pure rendering, so the coverage worth having is: a real
// invite URL produces a square, upscaled image, and blank input produces nil
// (so the invite card simply hides the QR rather than showing a broken box).
@Suite struct QRCodeImageTests {
    @Test func generatesASquareUpscaledImageForAnInviteURL() {
        guard let image = QRCodeImage.generate(from: "https://www.tovis.app/c/7Q4KX2M9") else {
            Issue.record("expected a QR image for a valid invite URL")
            return
        }
        // A QR symbol is NxN modules; upscaled it stays square and well above the
        // raw ~25-module grid.
        #expect(image.size.width == image.size.height)
        #expect(image.size.width > 40)
    }

    @Test func returnsNilForEmptyOrBlankInput() {
        #expect(QRCodeImage.generate(from: "") == nil)
        #expect(QRCodeImage.generate(from: "   \n\t ") == nil)
    }
}
