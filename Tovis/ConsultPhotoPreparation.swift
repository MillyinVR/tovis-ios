// Turning a captured still into the bytes the consult uploads: decode upright,
// optionally crop to the shot's band (P3), downscale, encode under the wire cap.
//
// Moved out of ConsultFlowView.swift when P3 gave it a Vision dependency — a
// pure image utility has no business living in a view file, and the view has no
// business importing Vision.

import CoreGraphics
import TovisKit
import UIKit
import Vision

/// A captured frame, ready for the durable queue.
nonisolated struct ConsultPreparedPhoto: Sendable, Equatable {
    /// The bytes that go to the server, and the bytes the thumbnail is decoded
    /// from — so what the client sees in her checklist is exactly what the
    /// quality gate is judging.
    let upload: Data
    /// The uncropped frame, kept when `upload` is a crop of it.
    ///
    /// INSPECTION ONLY (Tori, 2026-09-06): retake means reshoot, so nothing
    /// re-derives an upload from this. It exists so a client whose auto-crop
    /// came out wrong can see the whole photograph she actually took instead of
    /// a strip that looks like a bug. Nil when no crop happened, because then
    /// `upload` already IS the full frame — never a second copy of the same
    /// pixels.
    let fullFrame: Data?
    /// Where the crop came from, or nil when the frame was uploaded as framed.
    let cropSource: ConsultCaptureCrop.Source?
}

enum ConsultPhotoPreparation {
    /// Claude reads nothing above ~1568px on the long edge, and the request has
    /// to stay under the server's body cap.
    static let maximumDimension: CGFloat = 1_568
    private static let qualities: [CGFloat] = [0.9, 0.78, 0.65, 0.52]

    /// Prepare a still with no crop — the inspiration and camera-roll paths,
    /// which have no shot band at all.
    static func jpeg(from data: Data) async -> Data? {
        await prepare(data, plan: .fullFrame)?.upload
    }

    /// The crop plan for a shot, measured off the captured still.
    ///
    /// The Vision read happens HERE, on the upright decode of the captured
    /// bytes — never on a live frame. That is what makes this path
    /// orientation-proof: `UIImage(data:)` applies the still's own EXIF, so the
    /// image the landmarks are measured in is the image `prepare` cuts from,
    /// whichever camera took it and whatever the connection did with rotation.
    static func plan(
        _ data: Data,
        for shot: ConsultCaptureShot
    ) async -> ConsultCaptureCrop.Plan {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                // Only the eyes shot has anything to measure; every other plan
                // is decided without paying for a landmarks pass at all.
                guard shot.framingOrDefault == .tightCrop, shot.key == .eyesCloseup,
                      let image = UIImage(data: data),
                      let cgImage = uprightCGImage(image)
                else { return ConsultCaptureCrop.plan(for: shot, landmarkBand: nil) }
                let band = VisionDetect.eyeAndBrowBand(
                    performing: VNImageRequestHandler(cgImage: cgImage, options: [:])
                )
                return ConsultCaptureCrop.plan(for: shot, landmarkBand: band)
            }
        }.value
    }

    /// Cut, scale and encode for a decided plan.
    static func prepare(
        _ data: Data,
        plan: ConsultCaptureCrop.Plan
    ) async -> ConsultPreparedPhoto? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                guard let image = UIImage(data: data) else { return nil }
                switch plan {
                case .fullFrame:
                    guard let jpeg = encode(image) else { return nil }
                    return ConsultPreparedPhoto(
                        upload: jpeg, fullFrame: nil, cropSource: nil
                    )
                case let .crop(rect, source):
                    guard let cropped = cut(image, to: rect),
                          let jpeg = encode(cropped),
                          let full = encode(image) else { return nil }
                    return ConsultPreparedPhoto(
                        upload: jpeg, fullFrame: full, cropSource: source
                    )
                }
            }
        }.value
    }

    // MARK: - Pixels

    /// An UPRIGHT CGImage, with the decode's orientation baked in.
    ///
    /// 🔴 `UIImage.cgImage` is the raw, UNROTATED buffer — handing that straight
    /// to Vision measures a sideways face, and the band comes back rotated 90°
    /// with nothing to say it went wrong. Redrawing through the renderer applies
    /// `imageOrientation`, which is what makes the returned rect mean the same
    /// thing as the rect `cut` later applies.
    static func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let redrawn = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return redrawn.cgImage
    }

    /// Cut a normalized top-left rect out of an image, upright.
    static func cut(_ image: UIImage, to rect: CGRect) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let origin = CGPoint(x: (rect.minX * size.width).rounded(.down),
                             y: (rect.minY * size.height).rounded(.down))
        let target = CGSize(width: max(1, (rect.width * size.width).rounded(.down)),
                            height: max(1, (rect.height * size.height).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Drawing the image shifted by the crop origin into a target-sized
        // canvas both applies `imageOrientation` and cuts in one pass — a
        // `cgImage.cropping(to:)` would cut the UNROTATED buffer and produce the
        // wrong region for any still that is not already `.up`.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(x: -origin.x, y: -origin.y,
                                  width: size.width, height: size.height))
        }
    }

    /// Downscale to the wire ceiling and encode under the byte cap.
    ///
    /// ⚠️ `format.scale = 1` is load-bearing and is a CHANGE (P3). Without a
    /// format, `UIGraphicsImageRenderer` renders at the main screen's scale — 3
    /// on every phone this ships to — so drawing into a `maximumDimension`-point
    /// canvas produced a ~4700px JPEG, not the 1568px one the constant names.
    /// The byte cap then clawed it back by dropping QUALITY, which is the worst
    /// of both: an oversized frame encoded badly, for a model that reads nothing
    /// above 1568px. Pinning the scale makes the constant mean what it says.
    private static func encode(_ image: UIImage) -> Data? {
        let scale = min(1, maximumDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale),
                          height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in qualities {
            if let jpeg = rendered.jpegData(compressionQuality: quality),
               jpeg.count <= ConsultService.maximumPhotoBytes {
                return jpeg
            }
        }
        return nil
    }
}
