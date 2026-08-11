// Framework-agnostic expectations shared by every live-coached capture surface.
//
// This used to live beside the pro-only ShotGuide catalog. Keeping the value
// type independent lets a booking-attached client consult ask the same coaches
// to judge "ready for this shot" without depending on a pro destination,
// persisted pro settings, or pro upload state.
import Foundation

nonisolated struct ShotExpectations: Sendable, Equatable {
    enum Face: Sendable, Equatable {
        /// The subject's face belongs in this shot (front / profile work).
        case required
        /// A detected face must not drive framing judgment (back/crown work).
        case absent
        /// Face optional — judge it when present, don't miss it when not.
        case either
    }

    let face: Face
    /// Target subject-fill band (person segmentation), nil = don't judge fill.
    let fillBand: ClosedRange<Double>?
    /// Detail/macro shot: demand extra sharpness, ignore the backdrop.
    let isDetail: Bool
    /// Closed eyes are intended here (lash work) — post-capture QC skips blink.
    let allowsClosedEyes: Bool
    /// Optional pro shot-pack pose rules. Client consult shots leave this empty.
    let poseRules: [PoseRule]

    init(face: Face, fillBand: ClosedRange<Double>?, isDetail: Bool,
         allowsClosedEyes: Bool = false, poseRules: [PoseRule] = []) {
        self.face = face
        self.fillBand = fillBand
        self.isDetail = isDetail
        self.allowsClosedEyes = allowsClosedEyes
        self.poseRules = poseRules
    }

    static let portrait = ShotExpectations(
        face: .required, fillBand: 0.22...0.85, isDetail: false
    )
    static let backOfHead = ShotExpectations(
        face: .absent, fillBand: 0.22...0.9, isDetail: false
    )
    static let detail = ShotExpectations(face: .either, fillBand: nil, isDetail: true)
    static let neutral = ShotExpectations(face: .either, fillBand: nil, isDetail: false)
    static let eyesClosed = ShotExpectations(
        face: .either, fillBand: nil, isDetail: true, allowsClosedEyes: true
    )
}
