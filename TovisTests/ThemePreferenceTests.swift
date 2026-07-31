import SwiftUI
import Testing
@testable import Tovis

// The theme preference the pro Profile / client Settings picker writes, and the
// `ColorScheme?` it hands `.preferredColorScheme` in `ContentView`.
//
// 🔴 Why this suite exists: verifying K9's swatches in both modes meant flipping
// the app's appearance, and I briefly concluded — wrongly — that the app ignored
// the device. It doesn't. `defaults delete` from a `simctl spawn`ed process does
// not clear the domain the app reads (cfprefsd serves a stale value), so every
// probe resting on "the preference is now absent" was measuring something else.
// A unit test over the store settles in milliseconds what a simulator probe got
// wrong three times: this is the seam, and it is pure.
//
// What this does NOT cover, deliberately: that the segmented `Picker` in
// `ProProfileTabView` is bound to `theme.preference`. That is four lines of
// declarative SwiftUI (`get:`/`set:` straight onto the stored property) with no
// logic to get wrong, and no unit test can observe a SwiftUI binding firing.
@Suite struct ThemePreferenceTests {

    private static let storeKey = "tovis.theme.preference"

    @Test("system means FOLLOW THE DEVICE — nil, not a hardcoded light")
    func systemMapsToNil() {
        // The default preference. `nil` is what makes `.preferredColorScheme`
        // defer to the device; returning `.light` here would pin every user who
        // never opens the picker to paper, on a brand that leans dark.
        #expect(ThemePreference.system.colorScheme == nil)
        #expect(ThemePreference.light.colorScheme == .light)
        #expect(ThemePreference.dark.colorScheme == .dark)
    }

    @Test("the three cases are exactly what the picker offers, in order")
    func casesAreStableAndOrdered() {
        // `allCases` IS the picker's content, and the raw values are the
        // persisted wire — reordering is cosmetic, renaming a raw value silently
        // resets everyone's saved choice to .system.
        #expect(ThemePreference.allCases == [.system, .light, .dark])
        #expect(ThemePreference.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(ThemePreference.allCases.map(\.label) == ["System", "Light", "Dark"])
    }

    @Test("an unrecognized stored value falls back to system, never to a fixed mode")
    func unknownStoredValueFallsBackToSystem() {
        // A future build's preference read by an older one. Falling back to
        // `.system` keeps following the device; falling back to `.light` would
        // strand the user in a mode they never chose.
        #expect(ThemePreference(rawValue: "solarized") == nil)
        #expect((ThemePreference(rawValue: "solarized") ?? .system) == .system)
    }

    @MainActor
    @Test("what the picker SETS is what the next launch READS")
    func preferenceRoundTripsThroughDefaults() {
        // The actual picker path: its `set:` closure assigns `theme.preference`,
        // whose `didSet` persists — and `init` reads it back on the next launch.
        // ⚠️ `didSet` does NOT fire from within `init`, so "assign then re-init"
        // is the only honest way to exercise both halves.
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: Self.storeKey)
        defer {
            if let original { defaults.set(original, forKey: Self.storeKey) }
            else { defaults.removeObject(forKey: Self.storeKey) }
        }

        for choice in ThemePreference.allCases {
            ThemeStore().preference = choice          // what the picker does
            #expect(defaults.string(forKey: Self.storeKey) == choice.rawValue)
            #expect(ThemeStore().preference == choice) // what the next launch sees
            #expect(ThemeStore().colorScheme == choice.colorScheme)
        }
    }

    @MainActor
    @Test("a store with nothing saved defaults to system, matching the web")
    func freshInstallFollowsTheDevice() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: Self.storeKey)
        defer {
            if let original { defaults.set(original, forKey: Self.storeKey) }
            else { defaults.removeObject(forKey: Self.storeKey) }
        }
        defaults.removeObject(forKey: Self.storeKey)

        let store = ThemeStore()

        #expect(store.preference == .system)
        #expect(store.colorScheme == nil)   // ⇒ the device decides
    }
}
