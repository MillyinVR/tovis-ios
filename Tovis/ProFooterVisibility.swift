// Lets a screen pushed inside the pro shell hide the pro footer while it is on
// screen.
//
// Why this is needed: `ProMainTabView` installs `ProTabBar` as a
// `.safeAreaInset(edge: .bottom)` on the `TabView` — OUTSIDE each tab's
// `NavigationStack`. The bar paints the bottom ~114pt of the screen (its 80pt
// layout height, plus the home-indicator strip its background extends into via
// `.ignoresSafeArea`, plus the raised session coin overhanging 20pt above its top
// edge), but a view pushed inside a tab is only handed ~82pt of bottom safe area.
// So a pushed screen that pins its own primary action with `.safeAreaInset(edge:
// .bottom)` lays that bar out ~30pt UNDER the footer — and with the keyboard up
// both bars bottom-align on the same edge, so the footer covers the screen's
// action bar completely (measured on an iPhone 17 Pro: footer 760–874, create bar
// 700–791; keyboard up, footer 466–546 vs create bar 455–546).
//
// Padding around it would mean re-deriving the footer's true reach at every call
// site — the same magic number the tab-root scroll views already hand-pad. A
// pushed full-screen form gets the screen instead, which is also the platform
// convention (`.toolbar(.hidden, for: .tabBar)` for a real tab bar).
import SwiftUI

/// Preference a pushed screen sets to ask the pro shell to hide its footer.
///
/// Preferences travel UP the view tree, so this crosses the `NavigationStack`
/// boundary that keeps the pushed screen from seeing the footer's real height.
struct HidesProFooterKey: PreferenceKey {
    static let defaultValue = false

    /// Any descendant asking for a hidden footer wins — a pushed screen's request
    /// must not be cancelled by the sibling tab roots reporting `false`.
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Hide the pro footer (`ProTabBar`) while this screen is on screen.
    ///
    /// Use on a pushed screen that pins its own bottom action bar. The footer
    /// comes back when the screen is popped. No effect inside a `.sheet` — a
    /// sheet is its own presentation and never had the footer over it.
    ///
    /// Also hides the SYSTEM tab bar for this screen. `ProMainTabView` asks for
    /// that globally, but on iOS 26+ the system bar still draws its empty floating
    /// capsule — invisible only because the opaque `ProTabBar` sits on top of it.
    /// Remove the custom bar without this and the bare capsule shows through under
    /// the screen's own action bar.
    /// Takes no "unhide" argument on purpose: asking for `.automatic` here would
    /// override the shell's own `.toolbar(.hidden, for: .tabBar)` and put the empty
    /// system capsule back on screen.
    func hidesProFooter() -> some View {
        self
            .toolbar(.hidden, for: .tabBar)
            .preference(key: HidesProFooterKey.self, value: true)
    }
}
