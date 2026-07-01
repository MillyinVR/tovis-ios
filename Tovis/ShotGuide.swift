// ShotGuides — the "directed shoot." Instead of a freeform shutter, the AI
// photographer walks the pro through a curated list of angles for the service
// (front, profiles, back, detail), so every booking comes back with a complete,
// consistent set — and the SAME angles before and after, so they line up.
//
// The guide is resolved from the booking's base service name (keyword match) with
// a sensible generic fallback. Pure data + selection logic; the camera view owns
// progress + the on-screen bar.
import Foundation

/// One directed shot in a guide.
struct ShotStep: Identifiable, Sendable, Equatable {
    let id: String
    let title: String   // e.g. "Left profile"
    let hint: String    // e.g. "45° to the window, chin slightly down"
    let icon: String    // SF Symbol hinting the angle / framing

    init(_ title: String, _ hint: String, icon: String) {
        self.id = title
        self.title = title
        self.hint = hint
        self.icon = icon
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

    // MARK: - Catalog

    static let generic = ShotGuide(name: "Portrait set", steps: [
        ShotStep("Front", "Square to the camera, eyes level", icon: "person.fill"),
        ShotStep("Left profile", "Turn 45° to their left", icon: "arrow.turn.up.left"),
        ShotStep("Right profile", "Turn 45° to their right", icon: "arrow.turn.up.right"),
        ShotStep("Back", "From behind, frame head & shoulders", icon: "arrow.uturn.down"),
        ShotStep("Detail", "Move in close on the finished work", icon: "magnifyingglass"),
    ])

    static let hair = ShotGuide(name: "Hair set", steps: [
        ShotStep("Front", "Window to the side for shine, shoulders square", icon: "person.fill"),
        ShotStep("Left side", "45° left — light raking across to show dimension", icon: "arrow.turn.up.left"),
        ShotStep("Right side", "45° right — light raking across to show dimension", icon: "arrow.turn.up.right"),
        ShotStep("Back of cut", "The money shot — full canvas of the color & shape", icon: "arrow.uturn.down"),
        ShotStep("Detail", "Close on texture/part line; keep the ends sharp", icon: "magnifyingglass"),
    ])

    static let nails = ShotGuide(name: "Nail set", steps: [
        ShotStep("Both hands", "Hands together, nails toward the light", icon: "hands.sparkles.fill"),
        ShotStep("Top-down", "Straight above the spread fingers", icon: "arrow.down"),
        ShotStep("Detail", "Macro on one nail — show the finish", icon: "magnifyingglass"),
        ShotStep("Side angle", "Low angle to catch the shine", icon: "arrow.turn.up.right"),
    ])

    static let lashesBrows = ShotGuide(name: "Lash & brow set", steps: [
        ShotStep("Eyes open", "Front on, looking straight at the lens", icon: "eye.fill"),
        ShotStep("Eyes closed", "Lashes/brow shape from the front", icon: "eye.slash.fill"),
        ShotStep("Left eye", "Close on the left eye, looking down", icon: "arrow.turn.up.left"),
        ShotStep("Right eye", "Close on the right eye, looking down", icon: "arrow.turn.up.right"),
    ])

    static let face = ShotGuide(name: "Face set", steps: [
        ShotStep("Front", "Soft light for catchlights in the eyes, eyes level", icon: "person.fill"),
        ShotStep("Eye look", "Crop in close — sharp on the eyes, show the blend", icon: "eye.fill"),
        ShotStep("Lips", "Close on the lip — true color, catch the gloss", icon: "mouth.fill"),
        ShotStep("Profile", "45° to show contour & sculpting", icon: "arrow.turn.up.right"),
    ])
}
