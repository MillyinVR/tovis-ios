// Color-theme preference — ports the web's theme system (lib/brand/theme.ts +
// ThemeToggle): System / Light / Dark, where "System" follows the device and an
// explicit choice persists. BrandColor already defines every token for both
// modes, so flipping this re-themes the whole app.
import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// What to hand SwiftUI's `.preferredColorScheme`. `nil` = follow the device
    /// (mirrors the web's `prefers-color-scheme`).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Persisted theme preference, observed by the app root. Default is `.system`
/// to match the web (its default preference is "system").
@MainActor
@Observable
final class ThemeStore {
    private static let key = "tovis.theme.preference"

    var preference: ThemePreference {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: Self.key) }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        self.preference = raw.flatMap(ThemePreference.init(rawValue:)) ?? .system
    }

    var colorScheme: ColorScheme? { preference.colorScheme }
}