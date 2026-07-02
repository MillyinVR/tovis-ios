// ShotGuides — the "directed shoot." Instead of a freeform shutter, the AI
// photographer walks the pro through a curated list of angles for the service
// (front, profiles, back, detail), so every booking comes back with a complete,
// consistent set — and the SAME angles before and after, so they line up.
//
// The guide is resolved from the booking's base service name (keyword match) with
// a sensible generic fallback — or built from a server-driven trending shot pack
// (see `ShotGuide.init(pack:)`). Pure data + selection logic; the camera view
// owns progress + the on-screen bar.
import Foundation
import TovisKit

/// What the current directed shot should contain — lets the coach judge "ready
/// for THIS shot" (a back-of-cut wants no face and a filled frame; a detail
/// shot wants extra sharpness and doesn't care about the backdrop) instead of
/// scoring every frame like a generic portrait.
struct ShotExpectations: Sendable, Equatable {
    enum Face: Sendable, Equatable {
        /// The subject's face belongs in this shot (front / profile work).
        case required
        /// The face should NOT drive judgment (back-of-head; a stray mirror
        /// face must not trigger headroom/centering rules).
        case absent
        /// Face optional — judge it when present, don't miss it when not.
        case either
    }

    let face: Face
    /// Target subject-fill band (person segmentation), nil = don't judge fill.
    let fillBand: ClosedRange<Double>?
    /// Detail/macro shot: demand extra sharpness, ignore the backdrop.
    let isDetail: Bool
    /// Closed eyes are intended here (lash work) — post-capture QC skips the
    /// blink check.
    let allowsClosedEyes: Bool
    /// Pose rules (from a trending shot pack) the coach enforces — readiness
    /// holds until the subject is actually in the pose. Empty = no pose brief.
    let poseRules: [PoseRule]

    init(face: Face, fillBand: ClosedRange<Double>?, isDetail: Bool,
         allowsClosedEyes: Bool = false, poseRules: [PoseRule] = []) {
        self.face = face
        self.fillBand = fillBand
        self.isDetail = isDetail
        self.allowsClosedEyes = allowsClosedEyes
        self.poseRules = poseRules
    }

    static let portrait = ShotExpectations(face: .required, fillBand: 0.22...0.85, isDetail: false)
    static let backOfHead = ShotExpectations(face: .absent, fillBand: 0.22...0.9, isDetail: false)
    static let detail = ShotExpectations(face: .either, fillBand: nil, isDetail: true)
    static let neutral = ShotExpectations(face: .either, fillBand: nil, isDetail: false)
    /// Close eye work (lash/brow) — detail-sharp, closed lids intended.
    static let eyesClosed = ShotExpectations(face: .either, fillBand: nil, isDetail: true,
                                             allowsClosedEyes: true)
}

/// One directed shot in a guide.
struct ShotStep: Identifiable, Sendable, Equatable {
    let id: String
    let title: String   // e.g. "Left profile"
    let hint: String    // e.g. "45° to the window, chin slightly down"
    let icon: String    // SF Symbol hinting the angle / framing
    /// What this shot should contain — conditions the coach + post-capture QC.
    let expects: ShotExpectations

    init(_ title: String, _ hint: String, icon: String,
         expects: ShotExpectations = .neutral) {
        self.id = title
        self.title = title
        self.hint = hint
        self.icon = icon
        self.expects = expects
    }
}

/// A named, ordered set of shots for a kind of service.
struct ShotGuide: Sendable, Equatable {
    let name: String
    let steps: [ShotStep]

    /// Resolve a guide from a service name (e.g. "Balayage", "Gel manicure"),
    /// keyword-matched to a profession. Falls back to a generic portrait set.
    static func resolve(forServiceNamed name: String?) -> ShotGuide {
        let s = (name ?? "").lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }

        if has(["nail", "mani", "pedi", "gel", "acrylic"]) { return .nails }
        // "wax" alone is deliberately NOT a keyword — a leg/body wax would get
        // the eye-focused shot list ("brow wax" still matches via "brow").
        if has(["lash", "brow", "tint", "lamination"]) { return .lashesBrows }
        if has(["facial", "skin", "peel", "derma", "makeup", "glam"]) { return .face }
        if has(["hair", "cut", "color", "colour", "balayage", "blowout",
                "braid", "style", "barber", "fade", "extensions", "weave"]) { return .hair }
        return .generic
    }

    // MARK: - Trending packs (server-driven)

    /// Build a directed guide from a trending shot pack: steps map 1:1 into
    /// the existing guide machinery (expectations condition the coaches; pose
    /// rules gate readiness). Unknown pose-rule kinds are dropped here — the
    /// server can ship new vocabulary ahead of this build.
    init(pack: ProShotPack) {
        self.name = pack.name
        self.steps = pack.steps.map { step in
            let face: ShotExpectations.Face
            switch step.face {
            case "required": face = .required
            case "absent": face = .absent
            default: face = .either
            }
            var band: ClosedRange<Double>?
            if let lo = step.fillBandMin, let hi = step.fillBandMax, lo < hi {
                band = lo...hi
            }
            let rules: [PoseRule] = step.pose.compactMap { wire in
                guard let kind = PoseRule.Kind(rawValue: wire.kind) else { return nil }
                return PoseRule(kind: kind, params: wire.params ?? [:], tip: wire.tip)
            }
            return ShotStep(step.title, step.hint, icon: step.icon,
                            expects: ShotExpectations(face: face, fillBand: band,
                                                      isDetail: step.isDetail,
                                                      allowsClosedEyes: step.allowsClosedEyes,
                                                      poseRules: rules))
        }
    }

    /// The default catalog init (custom inits above suppress the memberwise one).
    init(name: String, steps: [ShotStep]) {
        self.name = name
        self.steps = steps
    }

    /// The packs relevant to this booking's base service (keyword match, same
    /// contract as `resolve`).
    static func matchingPacks(_ packs: [ProShotPack], serviceName: String?) -> [ProShotPack] {
        let service = (serviceName ?? "").lowercased()
        guard !service.isEmpty else { return [] }
        return packs.filter { pack in
            pack.serviceKeywords.contains { service.contains($0) }
        }
    }

    // MARK: - Catalog

    static let generic = ShotGuide(name: "Portrait set", steps: [
        ShotStep("Front", "Square to the camera, eyes level", icon: "person.fill", expects: .portrait),
        ShotStep("Left profile", "Turn 45° to their left", icon: "arrow.turn.up.left", expects: .portrait),
        ShotStep("Right profile", "Turn 45° to their right", icon: "arrow.turn.up.right", expects: .portrait),
        ShotStep("Back", "From behind, frame head & shoulders", icon: "arrow.uturn.down", expects: .backOfHead),
        ShotStep("Detail", "Move in close on the finished work", icon: "magnifyingglass", expects: .detail),
    ])

    static let hair = ShotGuide(name: "Hair set", steps: [
        ShotStep("Front", "Window to the side for shine, shoulders square", icon: "person.fill", expects: .portrait),
        ShotStep("Left side", "45° left — light raking across to show dimension", icon: "arrow.turn.up.left", expects: .portrait),
        ShotStep("Right side", "45° right — light raking across to show dimension", icon: "arrow.turn.up.right", expects: .portrait),
        ShotStep("Back of cut", "The money shot — full canvas of the color & shape", icon: "arrow.uturn.down", expects: .backOfHead),
        ShotStep("Detail", "Close on texture/part line; keep the ends sharp", icon: "magnifyingglass", expects: .detail),
    ])

    static let nails = ShotGuide(name: "Nail set", steps: [
        ShotStep("Both hands", "Hands together, nails toward the light", icon: "hands.sparkles.fill"),
        ShotStep("Top-down", "Straight above the spread fingers", icon: "arrow.down"),
        ShotStep("Detail", "Macro on one nail — show the finish", icon: "magnifyingglass", expects: .detail),
        ShotStep("Side angle", "Low angle to catch the shine", icon: "arrow.turn.up.right"),
    ])

    static let lashesBrows = ShotGuide(name: "Lash & brow set", steps: [
        ShotStep("Eyes open", "Front on, looking straight at the lens", icon: "eye.fill", expects: .portrait),
        ShotStep("Eyes closed", "Lashes/brow shape from the front", icon: "eye.slash.fill", expects: .eyesClosed),
        ShotStep("Left eye", "Close on the left eye, looking down", icon: "arrow.turn.up.left", expects: .eyesClosed),
        ShotStep("Right eye", "Close on the right eye, looking down", icon: "arrow.turn.up.right", expects: .eyesClosed),
    ])

    static let face = ShotGuide(name: "Face set", steps: [
        ShotStep("Front", "Soft light for catchlights in the eyes, eyes level", icon: "person.fill", expects: .portrait),
        ShotStep("Eye look", "Crop in close — sharp on the eyes, show the blend", icon: "eye.fill", expects: .detail),
        ShotStep("Lips", "Close on the lip — true color, catch the gloss", icon: "mouth.fill", expects: .detail),
        ShotStep("Profile", "45° to show contour & sculpting", icon: "arrow.turn.up.right", expects: .portrait),
    ])
}
