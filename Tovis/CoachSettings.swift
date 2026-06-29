// How the AI photographer guides the pro — toggleable, persisted. The pro picks
// the modes that fit how they work (hands/eyes busy → voice; quiet salon → just
// the on-screen ring). Mirrors the "real photographer guiding you" intent.
import SwiftUI

@Observable
final class CoachSettings {
    /// Show the single prioritized coaching tip as an on-screen chip.
    var showNudge: Bool { didSet { persist(\.showNudge, "showNudge") } }
    /// Speak the tip aloud (AVSpeechSynthesizer) — for hands-busy work.
    var speak: Bool { didSet { persist(\.speak, "speak") } }
    /// Haptic tap when a new tip appears + a success tap when the shot is ready.
    var haptics: Bool { didSet { persist(\.haptics, "haptics") } }
    /// Draw a rule-of-thirds grid over the preview.
    var showGrid: Bool { didSet { persist(\.showGrid, "showGrid") } }
    /// Show the readiness ring around the shutter (green = good to shoot).
    var showReadinessRing: Bool { didSet { persist(\.showReadinessRing, "showReadinessRing") } }
    /// Auto-harvest a still when quality peaks (the Session Reel core — B2).
    var autoHarvest: Bool { didSet { persist(\.autoHarvest, "autoHarvest") } }

    init() {
        let d = UserDefaults.standard
        showNudge = d.object(forKey: Self.key("showNudge")) as? Bool ?? true
        speak = d.object(forKey: Self.key("speak")) as? Bool ?? false
        haptics = d.object(forKey: Self.key("haptics")) as? Bool ?? true
        showGrid = d.object(forKey: Self.key("showGrid")) as? Bool ?? false
        showReadinessRing = d.object(forKey: Self.key("showReadinessRing")) as? Bool ?? true
        autoHarvest = d.object(forKey: Self.key("autoHarvest")) as? Bool ?? true
    }

    private static func key(_ name: String) -> String { "tovis.coach.\(name)" }
    private func persist(_ keyPath: KeyPath<CoachSettings, Bool>, _ name: String) {
        UserDefaults.standard.set(self[keyPath: keyPath], forKey: Self.key(name))
    }
}
