// Shared Vision extraction for the live coach (per-frame) and the reference-
// look analyzer (still images) — one implementation of face + body-pose
// reading so a picked reference is measured with EXACTLY the eyes the live
// camera judges with. Callers build the handler (live frames: cvPixelBuffer +
// .right orientation; stills: upright CIImage), this owns the requests and the
// upright top-left normalization.
import CoreGraphics
import Vision

/// `nonisolated` as a whole: both callers named above run off the main actor
/// (the live frame queue and the analyzer's detached task), and nothing here
/// holds state — the handler comes in as an argument.
nonisolated enum VisionDetect {
    /// Largest face, normalized with a TOP-LEFT origin in the handler's
    /// (oriented) space. Nil when no face is found.
    static func largestFace(performing handler: VNImageRequestHandler) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try? handler.perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }
        let largest = faces.max {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }
        guard let bb = largest?.boundingBox else { return nil }
        // Vision origin is bottom-left → flip Y to top-left.
        return CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
    }

    /// The band a face's EYES and BROWS occupy, normalized TOP-LEFT in the
    /// handler's (oriented) space. Nil when no face, or when the face carries no
    /// eye/brow landmarks.
    ///
    /// 🔴 This is a landmarks read (`VNDetectFaceLandmarksRequest`), NOT the
    /// face box `largestFace` returns, and the difference is the whole reason it
    /// exists. Where the brow line sits inside a face box moves with head tilt,
    /// hairline and how much forehead is in frame, so a fixed fraction of the box
    /// clips a brow on a real person often enough to be useless. The landmark
    /// regions ARE the eyes and the brows.
    ///
    /// Returned RAW — the union of the four regions and nothing else. Padding it
    /// out to a photographable band is the caller's job
    /// (`ConsultCaptureCrop.band`), so this stays a measurement and the band
    /// stays tunable without touching Vision.
    ///
    /// Runs its own request rather than extending `largestFace`: landmarks are
    /// materially more expensive than rectangles, and `largestFace` is on the
    /// LIVE frame path at `CoachTuning.analysisFPS`. This one runs once, on a
    /// captured still.
    static func eyeAndBrowBand(performing handler: VNImageRequestHandler) -> CGRect? {
        let request = VNDetectFaceLandmarksRequest()
        try? handler.perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }
        let largest = faces.max {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }
        guard let face = largest, let landmarks = face.landmarks else { return nil }

        let box = face.boundingBox
        var union: CGRect?
        for region in [landmarks.leftEye, landmarks.rightEye,
                       landmarks.leftEyebrow, landmarks.rightEyebrow] {
            guard let points = region?.normalizedPoints, !points.isEmpty else { continue }
            for point in points {
                // Landmark points are normalized to the FACE BOX, not the image
                // — the single easiest thing to get wrong here, and it fails
                // quietly by producing a band near the frame's top-left corner.
                let x = box.minX + point.x * box.width
                let y = box.minY + point.y * box.height
                let dot = CGRect(x: x, y: y, width: 0, height: 0)
                union = union.map { $0.union(dot) } ?? dot
            }
        }
        guard let band = union, band.width > 0, band.height > 0 else { return nil }
        // Vision origin is bottom-left → flip Y to top-left, matching
        // `largestFace` and everything downstream of it.
        return CGRect(x: band.minX, y: 1 - band.maxY,
                      width: band.width, height: band.height)
    }

    /// Body-pose read (upright, top-left normalized). Nil unless a body is
    /// confidently detected. Drives the clipping tip AND the pose rules.
    static func poseSignal(performing handler: VNImageRequestHandler) -> PoseSignal? {
        let request = VNDetectHumanBodyPoseRequest()
        try? handler.perform([request])
        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else { return nil }

        func point(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > CoachTuning.poseJointConfidence else { return nil }
            // Vision origin bottom-left → flip Y to top-left.
            return CGPoint(x: p.location.x, y: 1 - p.location.y)
        }

        let mapping: [(VNHumanBodyPoseObservation.JointName, PoseJoint)] = [
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.neck, .neck), (.nose, .nose),
        ]
        var joints: [PoseJoint: CGPoint] = [:]
        for (vision, joint) in mapping {
            if let p = point(vision) { joints[joint] = p }
        }
        guard !joints.isEmpty else { return nil }

        // Clipping: a confident TORSO/ARM joint hard against a frame edge
        // (nose excluded — a close-up face isn't "clipped").
        let edgePad = CoachTuning.poseEdgePad
        let clipped = joints
            .filter { $0.key != .nose }
            .values
            .contains { $0.x <= edgePad || $0.x >= 1 - edgePad || $0.y <= edgePad || $0.y >= 1 - edgePad }

        return PoseSignal(edgeClipped: clipped, joints: joints)
    }
}
