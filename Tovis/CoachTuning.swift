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
//
// The tunable values are `nonisolated(unsafe) static var` so the DEBUG-only
// tuning console (CoachTuningHUD) can adjust them live on-device — edit the
// slider, watch the ring, then write the numbers back here. Release builds
// never mutate them; cross-queue reads of a scalar are benign here.
import CoreGraphics

enum CoachTuning {
    // MARK: - Frame cadence / cost (structural — captured at analyzer init, not live-tunable)

    /// Light signals (whole-frame luma, face, sharpness) analyzed per second.
    static let analysisFPS: Double = 6
    /// Heavy Vision passes (person segmentation + body pose) per second; the last
    /// result is reused on the frames in between. Raise for snappier background/pose
    /// tips, lower if the frame queue can't keep up.
    static let heavyFPS: Double = 2.5
    /// Longest side the CoreImage / Vision aggregate math runs at — full-res frames
    /// are needless cost for luma/edge/segmentation averages.
    nonisolated static let workingMaxDim: CGFloat = 480
    /// Minimum spacing between auto-harvested keepers (seconds). The floor
    /// under BOTH ways into the Session Reel — the readiness peak and the
    /// steady-hold backstop (`CoachHarvestGate`).
    static let minHarvestInterval: Double = 2.5
    /// Cap on the UNREVIEWED auto-harvest tray (reviewing re-opens headroom).
    static let maxHarvest = 24
    /// How many frames the guided auto-shot may take to get one past QC.
    static let autoCaptureAttempts = 3

    // MARK: - Readiness / harvest

    /// Readiness at/above this reads as "good to shoot" — the green ring.
    nonisolated(unsafe) static var readyThreshold: Double = 0.8
    /// Readiness below this is the red ring; in between is amber.
    nonisolated(unsafe) static var readyWarnThreshold: Double = 0.5
    /// How long (seconds) the shot must hold good before the guided flow auto-fires
    /// the shutter — long enough to avoid catching motion, short enough to feel snappy.
    ///
    /// Also arms the Session Reel's steady-hold backstop (`CoachHarvestGate`),
    /// deliberately off the SAME number rather than a second knob beside it: if a
    /// hold has been good and still long enough to earn an automatic shutter, it
    /// has been good and still long enough to be worth a frame in the reel. Both
    /// directions a device pass might drag this are bounded — longer just arms the
    /// backstop later, and shorter can still never outpace `minHarvestInterval`.
    nonisolated(unsafe) static var autoCaptureHoldSeconds: Double = 0.7
    /// Readiness at/above which the Session Reel takes a frame on its own merit,
    /// with no hold behind it — a fleeting excellent frame is worth keeping even
    /// if the pro never settles.
    ///
    /// ⚠️ This is NO LONGER the reel's floor. It sits above `readyThreshold`, and
    /// an ordinary salon frame (mixed light + busy backdrop + a few degrees of
    /// hand tilt) measures **0.826** — in between — so on this threshold alone a
    /// pro could shoot a whole session that read green throughout and end with an
    /// empty tray. `CoachHarvestGate` closes that band with a steady-green-hold
    /// backstop; see that file for what the two ways in cost each other.
    nonisolated(unsafe) static var harvestThreshold: Double = 0.85

    // MARK: - How the one coach line behaves
    //
    // These are BEHAVIOURAL, not perception: they're set by how long a person
    // takes to read a line and start acting on it, not by what the sensor
    // measures. The salon pass doesn't invalidate them — a stopwatch would.

    /// How long (seconds) the locked focus-ladder rung must read continuously
    /// PASSING before the coach advances off it (docs/design's sequential
    /// focus coaching, 2026-08-06). A momentary good reading — sensor noise,
    /// not a real fix — must not advance the ladder prematurely; this is what
    /// makes "stable-good" mean something. Longer than a single analyzed
    /// frame, short enough the pro isn't left hanging once they've actually
    /// fixed it.
    nonisolated(unsafe) static var focusStabilityWindow: Double = 1.5
    /// How long (seconds) a rung EARLIER than the current lock must read
    /// continuously BROKEN before the ladder jumps back to it. Shorter than
    /// `focusStabilityWindow` — a real regression (they moved and lighting's
    /// genuinely bad again) deserves a fairly quick correction — but still
    /// long enough that two borderline rungs can't ping-pong the lock between
    /// them.
    nonisolated(unsafe) static var focusRegressionWindow: Double = 1.0
    /// How long (seconds) the coach keeps saying the same correction while the
    /// rung it is about shows NO measurable improvement, before it says it once
    /// more plainly — and then, after the same span again, stops saying it and
    /// coaches the next thing instead (camera plan P4.3, `CoachBackOff`).
    ///
    /// A NEW knob rather than a reuse, deliberately, and #357's reuse of
    /// `autoCaptureHoldSeconds` is the reason it has to be argued: that reuse
    /// worked because both consumers meant the SAME thing ("a hold good and
    /// still long enough to earn a shutter"). Nothing here means the same thing
    /// as anything above it. `focusStabilityWindow` (1.5) and
    /// `focusRegressionWindow` (1.0) ask "is this reading real?" — they are set
    /// by sensor noise. This asks "how long is too long to be saying the same
    /// sentence?", which is set by a stopwatch on a person, and it is an order
    /// of magnitude larger. Sharing either would couple a human-patience number
    /// to a debounce and drag one wherever the device pass drags the other.
    ///
    /// 20s: long enough that a real physical adjustment — walking closer,
    /// turning the chair, moving a client — has time to land and register as an
    /// improvement, so an ordinary correction is never cut short. The pro hears
    /// the tip at most once per category per 9s (`CoachSpeechScheduler`), so a
    /// full first stage is roughly "you've been shown this line twice and the
    /// number hasn't moved". Behavioural, not perceptual: the salon pass does
    /// not invalidate it — watching a pro with a stopwatch would.
    nonisolated(unsafe) static var coachPatienceSeconds: Double = 20
    /// Minimum spacing (seconds) between coaching haptics. The buzz is for
    /// news; without a floor, a re-rank storm is felt as a continuous vibration.
    nonisolated(unsafe) static var nudgeHapticMinInterval: Double = 2.0
    /// Minimum spacing (seconds) between spoken settle lines (a match look's
    /// `ready` direction). The line fires on the transition INTO ready; without
    /// a floor, readiness flickering around the threshold would re-speak it on
    /// every crossing.
    nonisolated(unsafe) static var settleLineMinInterval: Double = 12.0

    // MARK: - Lighting

    /// Whole-frame luma below this = "too dark".
    nonisolated(unsafe) static var lumaTooDark: Double = 0.22
    /// …above this = "too bright". Set lower than the dark cutoff is high, because
    /// clipped (blown-out) highlights are unrecoverable — protect them.
    nonisolated(unsafe) static var lumaTooBright: Double = 0.78
    /// Centre of the ideal exposure band. Biased slightly below mid-grey to favour
    /// protecting highlights (lift shadows later) over blowing them out.
    nonisolated(unsafe) static var lumaIdeal: Double = 0.47
    /// How fast the lighting score decays per unit of luma distance from ideal.
    nonisolated(unsafe) static var lumaFalloff: Double = 1.6
    /// Backlit if the face is darker than `scene × ratio` AND below `maxLuma`.
    nonisolated(unsafe) static var backlitFaceRatio: Double = 0.6
    nonisolated(unsafe) static var backlitFaceMaxLuma: Double = 0.4
    /// EV bias applied while exposure is metering a face — slightly under to
    /// protect highlights (hair shine / skin sheen clip unrecoverably).
    nonisolated(unsafe) static var faceExposureBias: Float = -0.3

    // MARK: - Composition (face placement, normalized top-left)

    /// Face top above this = too little headroom.
    nonisolated(unsafe) static var minHeadroom: Double = 0.04
    /// Face mid below this = subject sitting too low.
    nonisolated(unsafe) static var maxSubjectLow: Double = 0.72
    /// Horizontal "near centre" half-width.
    nonisolated(unsafe) static var centerTolerance: Double = 0.16
    /// Horizontal "near a third" half-width.
    nonisolated(unsafe) static var thirdTolerance: Double = 0.1
    /// A segmented subject filling less than this fraction of the frame = "get
    /// closer, fill the frame" (the #1 amateur framing mistake).
    nonisolated(unsafe) static var minSubjectFill: Double = 0.22

    // MARK: - Sharpness

    /// Edge-energy mean that reads as "tack sharp" — the normalizing divisor that
    /// maps raw edge energy onto 0…1. Higher-contrast sensors → raise this.
    nonisolated(unsafe) static var sharpnessReference: Double = 0.12
    /// Below this normalized sharpness = clearly soft (firm nudge).
    nonisolated(unsafe) static var sharpnessSoft: Double = 0.22
    /// …below this = a touch soft (gentle nudge).
    nonisolated(unsafe) static var sharpnessSlightlySoft: Double = 0.4
    /// Detail/macro shots multiply the sharpness cutoffs by this — a close-up
    /// of the work must be crisper than a portrait to pass.
    nonisolated(unsafe) static var detailSharpnessFactor: Double = 1.25

    // MARK: - Background

    /// Background edge density that reads as "fully cluttered" — the normalizing
    /// divisor mapping raw background edge energy onto 0…1.
    ///
    /// Measured 2026-08-23 (docs/camera-tuning-bench.md): across the 21 corpus
    /// PORTRAITS — the only frames with a segmented person, and so the only ones
    /// with a real background — raw background edge energy runs 0.0000 … 0.0968
    /// with a median of 0.0371. At the old 0.18 a frame had to reach 0.108 to
    /// read busy, which **0 of 21 did**: `BackgroundCoach` could not fire on a
    /// portrait at all, so the backdrop was un-coachable.
    ///
    /// 0.125 puts the busy line at `clutterBusy × this` = 0.075 — about TWICE
    /// the measured median, not at it. That distinction is the whole lesson of
    /// `mixedLightSpread`, which was set on the median of ordinary photographs
    /// and therefore fired on half of them until it read as noise. Here it wakes
    /// the coach on the busiest 3/21 (14%) instead of 0.
    ///
    /// ⚠️ Deliberately the CONSERVATIVE end of "fires at all". The corpus is
    /// watch-face and sample assets, whose backdrops are cleaner than a working
    /// salon's shelves, bottles and mirrors — so the same number will fire MORE
    /// often on real frames, not less. The salon pass should expect to lower
    /// this further only after watching it, never to raise it blind.
    nonisolated(unsafe) static var clutterReference: Double = 0.125
    /// Background must occupy at least this fraction of the frame to bother judging
    /// clutter (subject fills the frame → skip).
    nonisolated(unsafe) static var minBackgroundFraction: Double = 0.05
    /// Normalized clutter above this = "busy background".
    nonisolated(unsafe) static var clutterBusy: Double = 0.6

    // MARK: - Pose

    /// Minimum Vision joint confidence to trust a body point.
    nonisolated static let poseJointConfidence: Float = 0.3
    /// A confident joint within this normalized distance of any edge = clipping.
    nonisolated(unsafe) static var poseEdgePad: Double = 0.02

    // MARK: - Color (light quality / white balance)

    /// Warm↔cool spread across the frame above which it reads as mixed light (the
    /// #1 real-world beauty-photo killer — warm bulb on one side, cool window the
    /// other). The most robust color signal; the cast cutoffs below are stricter.
    nonisolated(unsafe) static var mixedLightSpread: Double = 0.13
    /// Global green tint above which it reads as a fluorescent cast.
    nonisolated(unsafe) static var greenCastTint: Double = 0.08
    /// Global warmth above which it reads as a warm/yellow (incandescent) cast —
    /// daylight (~5000–5600K, near-neutral) is the beauty target.
    nonisolated(unsafe) static var warmCastWarmth: Double = 0.30

    // MARK: - Light matching (before/after credibility)

    /// |Δ luma| vs the before shot within this = "light matches".
    nonisolated(unsafe) static var lightMatchLumaTolerance: Double = 0.08
    /// |Δ warmth| vs the before shot within this = "light matches".
    nonisolated(unsafe) static var lightMatchWarmthTolerance: Double = 0.07

    // MARK: - Calibration drift (re-scan nudge)

    /// |Δ warmth| vs the card-scan moment that reads as "the light changed"
    /// (sun moved, overheads flipped) — the calibration is going stale.
    nonisolated(unsafe) static var calibrationDriftWarmth: Double = 0.12
    /// The drift must hold this long (seconds) before nudging a re-scan —
    /// someone walking past a window shouldn't trigger it.
    nonisolated(unsafe) static var calibrationDriftSeconds: Double = 8

    // MARK: - Post-capture QC (verifies the ACTUAL capture, not the preview)

    /// Normalized sharpness below this on the captured image = offer a retake.
    /// Deliberately looser than the live `sharpnessSoft` — QC only flags clear
    /// failures, it doesn't re-nag.
    nonisolated(unsafe) static var qcSharpnessMin: Double = 0.15
    /// Captured luma outside this band = retake offer.
    nonisolated(unsafe) static var qcLumaMin: Double = 0.14
    nonisolated(unsafe) static var qcLumaMax: Double = 0.88

    // MARK: - Device level (horizon)

    /// Device roll (degrees off level) above which the shot reads as clearly tilted
    /// — a firm "straighten the camera" nudge.
    nonisolated(unsafe) static var tiltBadDegrees: Double = 6
    /// …above this (but below `tiltBadDegrees`) = slightly off level (gentle nudge).
    nonisolated(unsafe) static var tiltWarnDegrees: Double = 2.5
    /// Within this many degrees of level the on-screen horizon line snaps green.
    nonisolated(unsafe) static var tiltLevelDegrees: Double = 1.5
}
