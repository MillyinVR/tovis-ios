// Every device-dependent number the AI-photographer coach uses, in ONE place so a
// tuning pass against real salon footage is a single file to edit + rebuild — no
// hunting magic numbers across the coaches and the analyzer.
//
// ⚠️ These defaults were set WITHOUT a device. The perception thresholds (luma
// bands, the sharpness/clutter reference divisors, the pose tilt) depend on the
// real camera + lighting and almost certainly need adjusting once you watch the
// live readiness ring + nudges on hardware. The per-coach SCORE weights (0.3/0.5/…)
// stay inline in `ShotCoach.swift` — those are design weights, not perception
// calibration, so they don't belong here.
import CoreGraphics

enum CoachTuning {
    // MARK: - Frame cadence / cost

    /// Light signals (whole-frame luma, face, sharpness) analyzed per second.
    static let analysisFPS: Double = 6
    /// Heavy Vision passes (person segmentation + body pose) per second; the last
    /// result is reused on the frames in between. Raise for snappier background/pose
    /// tips, lower if the frame queue can't keep up.
    static let heavyFPS: Double = 2.5
    /// Longest side the CoreImage / Vision aggregate math runs at — full-res frames
    /// are needless cost for luma/edge/segmentation averages.
    static let workingMaxDim: CGFloat = 480

    // MARK: - Readiness / harvest

    /// Readiness at/above this reads as "good to shoot" — the green ring.
    static let readyThreshold: Double = 0.8
    /// Readiness below this is the red ring; in between is amber.
    static let readyWarnThreshold: Double = 0.5
    /// Auto-harvest (Session Reel) only grabs frames at/above this readiness.
    static let harvestThreshold: Double = 0.85
    /// Minimum spacing between auto-harvested keepers (seconds).
    static let minHarvestInterval: Double = 2.5
    /// Cap on the auto-harvest tray so it stays curated.
    static let maxHarvest = 24

    // MARK: - Lighting

    /// Whole-frame luma below this = "too dark".
    static let lumaTooDark: Double = 0.22
    /// …above this = "too bright". Set lower than the dark cutoff is high, because
    /// clipped (blown-out) highlights are unrecoverable — protect them.
    static let lumaTooBright: Double = 0.78
    /// Centre of the ideal exposure band. Biased slightly below mid-grey to favour
    /// protecting highlights (lift shadows later) over blowing them out.
    static let lumaIdeal: Double = 0.47
    /// How fast the lighting score decays per unit of luma distance from ideal.
    static let lumaFalloff: Double = 1.6
    /// Backlit if the face is darker than `scene × ratio` AND below `maxLuma`.
    static let backlitFaceRatio: Double = 0.6
    static let backlitFaceMaxLuma: Double = 0.4

    // MARK: - Composition (face placement, normalized top-left)

    /// Face top above this = too little headroom.
    static let minHeadroom: Double = 0.04
    /// Face mid below this = subject sitting too low.
    static let maxSubjectLow: Double = 0.72
    /// Horizontal "near centre" half-width.
    static let centerTolerance: Double = 0.16
    /// Horizontal "near a third" half-width.
    static let thirdTolerance: Double = 0.1
    /// A segmented subject filling less than this fraction of the frame = "get
    /// closer, fill the frame" (the #1 amateur framing mistake).
    static let minSubjectFill: Double = 0.22

    // MARK: - Sharpness

    /// Edge-energy mean that reads as "tack sharp" — the normalizing divisor that
    /// maps raw edge energy onto 0…1. Higher-contrast sensors → raise this.
    static let sharpnessReference: Double = 0.12
    /// Below this normalized sharpness = clearly soft (firm nudge).
    static let sharpnessSoft: Double = 0.22
    /// …below this = a touch soft (gentle nudge).
    static let sharpnessSlightlySoft: Double = 0.4

    // MARK: - Background

    /// Background edge density that reads as "fully cluttered" — the normalizing
    /// divisor mapping raw background edge energy onto 0…1.
    static let clutterReference: Double = 0.18
    /// Background must occupy at least this fraction of the frame to bother judging
    /// clutter (subject fills the frame → skip).
    static let minBackgroundFraction: Double = 0.05
    /// Normalized clutter above this = "busy background".
    static let clutterBusy: Double = 0.6

    // MARK: - Pose

    /// Minimum Vision joint confidence to trust a body point.
    static let poseJointConfidence: Float = 0.3
    /// A confident joint within this normalized distance of any edge = clipping.
    static let poseEdgePad: Double = 0.02

    // MARK: - Device level (horizon)

    /// Device roll (degrees off level) above which the shot reads as clearly tilted
    /// — a firm "straighten the camera" nudge.
    static let tiltBadDegrees: Double = 6
    /// …above this (but below `tiltBadDegrees`) = slightly off level (gentle nudge).
    static let tiltWarnDegrees: Double = 2.5
    /// Within this many degrees of level the on-screen horizon line snaps green.
    static let tiltLevelDegrees: Double = 1.5
}
