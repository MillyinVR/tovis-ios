// The crop window RENDERED, not just computed.
//
// `LookFeedLayoutTests` pins the arithmetic and `MediaDisplayCropTests` pins the
// focal remap, and both would stay green if the VIEW drew the numbers wrong —
// a swapped offset, a frame applied in the wrong order, a clip in the wrong
// place. `CropWindowLayer` is what every look on every surface is now seen
// through (the feed, every 3:4 tile, both heroes, the pro's own library), so
// what it puts on screen is worth asserting in pixels.
//
// 🔴 The failure this exists to catch does not crash and does not look wrong in
// a diff. It shows the wrong part of somebody's photograph.
//
// Method: the source image encodes its own coordinates — red = x/1000, green =
// y/1000 — so any rendered pixel names the source pixel it came from. Same
// worked crop as web's `cropWindow.test.ts`, and the expected window box is the
// SAME 500×400 at (−140, 0) that `RemoteImage.test.tsx` asserts on the web side.
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Tovis
@testable import TovisKit

@MainActor
@Suite struct CropWindowLayerRenderTests {
    /// The worked crop, shared with web and with `MediaCropRectTests`.
    private static let workedCrop = MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4)!
    /// (0.60, 0.20) on the uncropped frame, remapped into that crop's space.
    private static let focalInCrop = MediaFocalPoint(x: 0.7, y: 0.25)!

    private static let sourceSide: CGFloat = 1000
    private static let container = CGSize(width: 300, height: 400)

    /// A 1000×1000 image whose every pixel names its own coordinates:
    /// red = x/1000 × 255, green = y/1000 × 255. Blue is constant so a pixel
    /// that came from nowhere (transparent, or the backdrop) is obvious.
    private func coordinateImage() -> UIImage {
        let side = Self.sourceSide
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { ctx in
                // 10pt bands: fine enough to locate a pixel to ±10/1000 of the
                // frame, coarse enough to draw quickly.
                let step: CGFloat = 10
                var y: CGFloat = 0
                while y < side {
                    var x: CGFloat = 0
                    while x < side {
                        UIColor(
                            red: (x + step / 2) / side,
                            green: (y + step / 2) / side,
                            blue: 0.5,
                            alpha: 1
                        ).setFill()
                        ctx.fill(CGRect(x: x, y: y, width: step, height: step))
                        x += step
                    }
                    y += step
                }
            }
    }

    private func render(crop: MediaCropRect?, focal: MediaFocalPoint?) throws -> UIImage {
        let view = CropWindowLayer(
            image: coordinateImage(),
            crop: crop,
            container: Self.container,
            fit: .cover,
            focal: focal
        )
        .frame(width: Self.container.width, height: Self.container.height)
        .clipped()

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    /// The source coordinates a rendered pixel came from, in [0,1] of the frame.
    ///
    /// `point` is in UIKit's coordinates — origin TOP-left, the same space the
    /// view was laid out in. CGContext's origin is BOTTOM-left, so the row is
    /// flipped on the way in. Without that flip this reader reports every
    /// sample mirrored vertically, which looks exactly like a sign error in the
    /// layout under test — it was measured as one before being tracked down:
    /// the x readings were already exact while the y readings came back as the
    /// two sample points' values swapped.
    private func sourcePoint(of image: UIImage, at point: CGPoint) throws -> (x: Double, y: Double) {
        let cg = try #require(image.cgImage)
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(
            CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let flippedY = CGFloat(cg.height) - 1 - point.y
        context.draw(
            cg,
            in: CGRect(x: -point.x, y: -flippedY, width: CGFloat(cg.width), height: CGFloat(cg.height))
        )
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0)
    }

    @Test func showsTheCropWindowAndNotTheWholeFrame() throws {
        let image = try render(crop: Self.workedCrop, focal: Self.focalInCrop)

        // Window 500×400 covering a 300×400 box → scale 1, so the 200pt of
        // horizontal overflow is spent by the focal's x (0.7 → left = −140).
        // Container x 0…300 therefore reads window x 140…440 of 500, which is
        // source x 0.25 + (140…440)/500 × 0.50 = 0.39 … 0.69.
        // Container y 0…400 reads the whole window height: source y 0.10 … 0.50.
        let topLeft = try sourcePoint(of: image, at: CGPoint(x: 1, y: 1))
        #expect(abs(topLeft.x - 0.39) < 0.02, "top-left came from x \(topLeft.x), expected ~0.39")
        #expect(abs(topLeft.y - 0.10) < 0.02, "top-left came from y \(topLeft.y), expected ~0.10")

        let bottomRight = try sourcePoint(of: image, at: CGPoint(x: 298, y: 398))
        #expect(abs(bottomRight.x - 0.69) < 0.02, "bottom-right came from x \(bottomRight.x), expected ~0.69")
        #expect(abs(bottomRight.y - 0.50) < 0.02, "bottom-right came from y \(bottomRight.y), expected ~0.50")

        // 🔴 The consent statement, in pixels: NOTHING outside the published
        // rect (x 0.25…0.75, y 0.10…0.50) reaches the screen.
        for x in stride(from: 2.0, to: 299.0, by: 37.0) {
            for y in stride(from: 2.0, to: 399.0, by: 49.0) {
                let p = try sourcePoint(of: image, at: CGPoint(x: x, y: y))
                #expect(p.x >= 0.25 - 0.02 && p.x <= 0.75 + 0.02, "leaked source x \(p.x)")
                #expect(p.y >= 0.10 - 0.02 && p.y <= 0.50 + 0.02, "leaked source y \(p.y)")
            }
        }
    }

    @Test func aNilCropIsTheFullFrame_theInvariantEverySurfaceReliesOn() throws {
        // Every row in the database is here today: no rect means the whole photo
        // cover-cropped on the focal, which must be what these surfaces drew
        // before they honoured a rect at all.
        let image = try render(crop: nil, focal: MediaFocalPoint(x: 0.5, y: 0.5)!)

        // A square source covering a 300×400 box → scale 400/1000, so the
        // rendered width is 400 and the 100pt of overflow is split evenly.
        // Container x 0…300 reads source x 0.125 … 0.875; y reads 0 … 1.
        let topLeft = try sourcePoint(of: image, at: CGPoint(x: 1, y: 1))
        #expect(abs(topLeft.x - 0.125) < 0.02, "top-left came from x \(topLeft.x)")
        #expect(abs(topLeft.y - 0.0) < 0.02, "top-left came from y \(topLeft.y)")

        let bottomRight = try sourcePoint(of: image, at: CGPoint(x: 298, y: 398))
        #expect(abs(bottomRight.x - 0.875) < 0.02, "bottom-right came from x \(bottomRight.x)")
        #expect(abs(bottomRight.y - 1.0) < 0.02, "bottom-right came from y \(bottomRight.y)")
    }

    @Test func theFocalMOVESTheWindow() throws {
        // Anchored left instead of on the subject: the same crop must now show
        // the LEFT edge of its own window. If the focal were ignored — or spent
        // on the wrong axis — these two renders would be identical.
        let onSubject = try render(crop: Self.workedCrop, focal: Self.focalInCrop)
        let onLeft = try render(crop: Self.workedCrop, focal: MediaFocalPoint(x: 0, y: 0.25)!)

        let a = try sourcePoint(of: onSubject, at: CGPoint(x: 1, y: 1))
        let b = try sourcePoint(of: onLeft, at: CGPoint(x: 1, y: 1))
        #expect(abs(b.x - 0.25) < 0.02, "left-anchored top-left came from x \(b.x), expected the rect's own left edge")
        #expect(a.x > b.x + 0.1, "the focal did not move the window: \(a.x) vs \(b.x)")
    }
}
