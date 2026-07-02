// "Match a look" — the pro picks any photo (a screenshot of a viral post, a
// portfolio shot they admire) and the camera guides them to recreate it. The
// reference is measured ENTIRELY ON-DEVICE (nothing uploads, it never enters
// the media pipeline — a private posing aid) with the exact perception stack
// the live coach uses (VisionDetect/FrameMath), then synthesized into the same
// brief vocabulary as the trending packs: expectations + pose rules + a light
// target — so the whole existing coaching machinery (directives, readiness
// gating, auto-capture, light-match pill, onion-skin ghost) drives the shoot.
//
// v1 matches the shot's STRUCTURE (framing/fill, the pose-rule vocabulary,
// brightness, warmth) — not expression, exact head tilt, or editing. Phase D
// (Claude vision) upgrades this same flow with a richer brief.
import CoreImage
import UIKit
import Vision

/// A look the pro wants to recreate, measured into a guided one-shot brief.
struct ReferenceLook {
    /// The picked image — ghosted over the live preview for visual line-up.
    let image: UIImage
    /// Reference light target (same scales the live coach reads).
    let luma: Double
    let warmth: Double
    /// One-step directed guide carrying the synthesized brief.
    let guide: ShotGuide
}

enum ReferenceLookAnalyzer {
    /// Measure a picked photo into a `ReferenceLook`. Nil when the bytes don't
    /// decode. Runs off the caller's actor.
    static func analyze(_ data: Data) async -> ReferenceLook? {
        await Task.detached(priority: .userInitiated) { analyzeSync(data) }.value
    }

    private static func analyzeSync(_ data: Data) -> ReferenceLook? {
        guard let uiImage = UIImage(data: data),
              let full = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let working = FrameMath.downscaled(full, maxDim: 640)
        let extent = working.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let aspect = Double(extent.width / extent.height)
        let context = FrameMath.context

        let luma = FrameMath.averageLuma(working, context: context)
        let rgb = FrameMath.averageRGB(working, context: context) ?? (0.5, 0.5, 0.5)
        let warmth = FrameMath.warmth(rgb)

        // Same eyes as the live coach (stills are already upright after EXIF).
        func handler() -> VNImageRequestHandler {
            VNImageRequestHandler(ciImage: working, options: [:])
        }
        let face = VisionDetect.largestFace(performing: handler())
        let pose = VisionDetect.poseSignal(performing: handler())

        var fill: Double?
        let segRequest = VNGeneratePersonSegmentationRequest()
        segRequest.qualityLevel = .balanced
        segRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? handler().perform([segRequest])
        if let maskBuffer = segRequest.results?.first?.pixelBuffer,
           let seg = FrameMath.segmentation(maskBuffer: maskBuffer, working: working,
                                            context: context) {
            fill = seg.subjectFill
        }

        let eyesClosed = face != nil && PhotoQC.eyesClosedRead(in: working)
        let step = brief(face: face, pose: pose, fill: fill, aspect: aspect,
                         eyesClosed: eyesClosed)
        return ReferenceLook(image: uiImage, luma: luma, warmth: warmth,
                             guide: ShotGuide(name: "Match the look", steps: [step]))
    }

    /// Synthesize the shot brief: what the reference measurably IS becomes
    /// what the coach directs toward — big body geometry first, hands after
    /// (direction order = rule order).
    private static func brief(
        face: CGRect?, pose: PoseSignal?, fill: Double?, aspect: Double, eyesClosed: Bool
    ) -> ShotStep {
        var rules: [PoseRule] = []
        if let pose {
            if let angle = PoseGeometry.shoulderAngleDegrees(pose, aspect: aspect) {
                if abs(angle) >= 8 {
                    rules.append(PoseRule(
                        kind: .shouldersTilted,
                        params: ["minDegrees": max(4, abs(angle) - 4)],
                        tip: "Tilt their shoulders like the reference"))
                } else if abs(angle) <= 4 {
                    rules.append(PoseRule(
                        kind: .shouldersLevel,
                        params: ["maxDegrees": 6],
                        tip: "Square their shoulders like the reference"))
                }
            }
            if let face {
                let center = CGPoint(x: face.midX, y: face.midY)
                let faceWidth = PoseGeometry.faceWidth(face, aspect: aspect)
                let faceHeight = PoseGeometry.faceHeight(face)

                let shoulderDistances = [pose.joints[.leftShoulder], pose.joints[.rightShoulder]]
                    .compactMap { $0 }
                    .map { PoseGeometry.distance($0, center, aspect: aspect) }
                if faceWidth > 0, let nearest = shoulderDistances.min(),
                   nearest <= 1.3 * faceWidth {
                    rules.append(PoseRule(
                        kind: .faceNearShoulder,
                        params: ["maxFaceWidths": 1.3],
                        tip: "Chin toward the shoulder — match the look-back"))
                }

                let wristDistances = [pose.joints[.leftWrist], pose.joints[.rightWrist]]
                    .compactMap { $0 }
                    .map { PoseGeometry.distance($0, center, aspect: aspect) }
                if faceHeight > 0, let nearest = wristDistances.min(),
                   nearest <= 1.5 * faceHeight {
                    rules.append(PoseRule(
                        kind: .handNearFace,
                        params: ["maxFaceHeights": max(0.8, nearest / faceHeight + 0.35)],
                        tip: "Bring their hand up by the face"))
                }
            }
            if pose.joints[.leftWrist] != nil, pose.joints[.rightWrist] != nil {
                rules.append(PoseRule(
                    kind: .bothHandsVisible, params: [:],
                    tip: "Both hands in frame — like the reference"))
            }
        }

        // No face AND no body → a detail/close-up reference (nail macro,
        // texture shot): demand detail sharpness, ignore backdrop and fill.
        let isDetail = face == nil && pose == nil
        let faceExpectation: ShotExpectations.Face =
            face != nil ? .required : (pose != nil ? .absent : .either)
        var band: ClosedRange<Double>?
        if !isDetail, let fill, fill > 0.02 {
            let lower = max(0.05, fill - 0.12)
            let upper = min(0.98, fill + 0.12)
            if lower < upper { band = lower...upper }
        }

        return ShotStep("Reference look", "Line them up with the ghosted reference",
                        icon: "photo.fill",
                        expects: ShotExpectations(face: faceExpectation, fillBand: band,
                                                  isDetail: isDetail,
                                                  allowsClosedEyes: eyesClosed,
                                                  poseRules: rules))
    }
}
