// Shared Vision extraction for the live coach (per-frame) and the reference-
// look analyzer (still images) — one implementation of face + body-pose
// reading so a picked reference is measured with EXACTLY the eyes the live
// camera judges with. Callers build the handler (live frames: cvPixelBuffer +
// .right orientation; stills: upright CIImage), this owns the requests and the
// upright top-left normalization.
import CoreGraphics
import Vision

enum VisionDetect {
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
