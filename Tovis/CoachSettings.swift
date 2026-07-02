// How the AI photographer guides the pro — toggleable, persisted. The pro picks
// the modes that fit how they work (hands/eyes busy → voice; quiet salon → just
// the on-screen ring). Mirrors the "real photographer guiding you" intent.
import SwiftUI

@Observable
final class CoachSettings {
    /// Show the single prioritized coaching tip as an on-screen chip.
    var showNudge: Bool { didSet { persist(\.showNudge, "showNudge") } }
    /// Show the at-a-glance fundamentals checklist (light/level/frame/focus/…).
    var showChecklist: Bool { didSet { persist(\.showChecklist, "showChecklist") } }
    /// Show the directed ShotGuide bar (front / profile / back / detail).
    var showGuides: Bool { didSet { persist(\.showGuides, "showGuides") } }
    /// Speak the tip aloud (AVSpeechSynthesizer) — for hands-busy work.
    var speak: Bool { didSet { persist(\.speak, "speak") } }
    /// Haptic tap when a new tip appears + a success tap when the shot is ready.
    var haptics: Bool { didSet { persist(\.haptics, "haptics") } }
    /// Draw a rule-of-thirds grid over the preview.
    var showGrid: Bool { didSet { persist(\.showGrid, "showGrid") } }
    /// Draw the publish-crop safe areas (4:5 feed · 9:16 reel) so the money
    /// shot stays inside what survives the crop.
    var showCropGuide: Bool { didSet { persist(\.showCropGuide, "showCropGuide") } }
    /// Show the readiness ring around the shutter (green = good to shoot).
    var showReadinessRing: Bool { didSet { persist(\.showReadinessRing, "showReadinessRing") } }
    /// Draw the level / horizon indicator (turns green when the camera is level).
    var showLevel: Bool { didSet { persist(\.showLevel, "showLevel") } }
    /// Guided auto-capture: when the current guided shot holds good + steady, the
    /// camera takes it for you (full quality) and moves to the next — the
    /// "photographer is shooting for you" core.
    var autoCapture: Bool { didSet { persist(\.autoCapture, "autoCapture") } }
    /// Auto-harvest extra stills (video-res) when quality peaks — a background
    /// safety net, off by default now that guided auto-capture is the primary flow.
    var autoHarvest: Bool { didSet { persist(\.autoHarvest, "autoHarvest") } }
    /// "Match a look" AI enhance (Phase D): also send the picked reference to
    /// Claude for the parts geometry can't measure (expression, head angle,
    /// hands, light direction). Consent-gated on first use — the photo is
    /// analyzed in-flight and never stored.
    var aiEnhanceLooks: Bool { didSet { persist(\.aiEnhanceLooks, "aiEnhanceLooks") } }

    init() {
        let d = UserDefaults.standard
        showNudge = d.object(forKey: Self.key("showNudge")) as? Bool ?? true
        showChecklist = d.object(forKey: Self.key("showChecklist")) as? Bool ?? true
        showGuides = d.object(forKey: Self.key("showGuides")) as? Bool ?? true
        speak = d.object(forKey: Self.key("speak")) as? Bool ?? false
        haptics = d.object(forKey: Self.key("haptics")) as? Bool ?? true
        showGrid = d.object(forKey: Self.key("showGrid")) as? Bool ?? false
        showCropGuide = d.object(forKey: Self.key("showCropGuide")) as? Bool ?? false
        showReadinessRing = d.object(forKey: Self.key("showReadinessRing")) as? Bool ?? true
        showLevel = d.object(forKey: Self.key("showLevel")) as? Bool ?? true
        autoCapture = d.object(forKey: Self.key("autoCapture")) as? Bool ?? true
        autoHarvest = d.object(forKey: Self.key("autoHarvest")) as? Bool ?? false
        aiEnhanceLooks = d.object(forKey: Self.key("aiEnhanceLooks")) as? Bool ?? true
    }

    private static func key(_ name: String) -> String { "tovis.coach.\(name)" }
    private func persist(_ keyPath: KeyPath<CoachSettings, Bool>, _ name: String) {
        UserDefaults.standard.set(self[keyPath: keyPath], forKey: Self.key(name))
    }
}
