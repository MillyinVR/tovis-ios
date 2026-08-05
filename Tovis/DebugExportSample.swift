#if DEBUG
import CoreGraphics
import Foundation
import TovisKit
import UIKit

/// DEBUG ONLY — a synthetic before/after so the social export sheet can be
/// opened, looked at and screenshotted without a camera, a signed-in pro, a
/// booking, or a running local stack.
///
/// Reached by `SIMCTL_CHILD_TOVIS_DEBUG_OPEN_EXPORT=1`. It exists for the same
/// reason as `DebugSessionSeed` and `TOVIS_DEBUG_OPEN_PRACTICE`: on this machine
/// the simulator cannot be driven by synthetic taps, and a screen nobody can
/// reach is a screen that ships build-green and never once seen.
///
/// It supplies only the SOURCE PIXELS. The crop, the layout and the signature all
/// come from the real `SocialExportRenderer`, so a screenshot of this sheet is an
/// honest picture of what a pro's export will look like — the sample is fake, the
/// rendering is not.
enum DebugExportSample {
    /// A model already carrying an identity, so both tiers can be screenshotted.
    /// `TOVIS_DEBUG_EXPORT_TIER=free` shows the platform mark; anything else (the
    /// default) shows the member treatment.
    @MainActor
    static func model() -> ProMediaExportModel {
        let model = ProMediaExportModel()
        let environment = ProcessInfo.processInfo.environment
        model.applyDebugIdentity(
            tier: environment["TOVIS_DEBUG_EXPORT_TIER"] ?? "member",
            handle: environment["TOVIS_DEBUG_EXPORT_HANDLE"] ?? "toristyles"
        )
        return model
    }

    static func context() -> ProMediaExportContext {
        ProMediaExportContext(
            main: .bytes(jpeg(hair: 0.80, skin: 0.78)),
            focal: MediaFocalPoint(x: 0.5, y: 0.36),
            before: .bytes(jpeg(hair: 0.22, skin: 0.72)),
            beforeFocal: MediaFocalPoint(x: 0.5, y: 0.36)
        )
    }

    /// A 3:4 "portrait": a studio falloff behind a head-and-shoulders silhouette,
    /// bright top-left to deep shadow bottom-right — so the signature corner is
    /// judged over a dark field and the rest over a light one.
    private static func jpeg(hair: CGFloat, skin: CGFloat) -> Data {
        let size = CGSize(width: 900, height: 1200)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            return format
        }())

        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: space, colors: [
                UIColor(white: 0.92, alpha: 1).cgColor,
                UIColor(white: 0.11, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: []
            )
            UIColor(white: hair, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 180, y: 120, width: 540, height: 670)).fill()
            UIColor(red: skin, green: skin * 0.80, blue: skin * 0.70, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 270, y: 240, width: 360, height: 430)).fill()
            UIColor(white: hair * 0.7, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 45, y: 870, width: 810, height: 580)).fill()
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }
}
#endif
