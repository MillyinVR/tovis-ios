// Lets a screen pushed inside a role shell hide that shell's footer while it is
// on screen. Honored by BOTH shells — `ProMainTabView` (`ProTabBar`) and
// `MainTabView` (`TovisTabBar`).
//
// Why this is needed: each shell installs its bar as a `.safeAreaInset(edge:
// .bottom)` on the `TabView` — OUTSIDE each tab's `NavigationStack`. The bar
// paints the bottom ~114pt of the screen (its 80pt layout height, plus the
// home-indicator strip its background extends into via `.ignoresSafeArea`, plus
// the raised centre button overhanging its top edge), but a view pushed inside a
// tab is only handed ~82pt of bottom safe area. So a pushed screen that pins its
// own bottom bar with `.safeAreaInset(edge: .bottom)` lays that bar out ~30pt
// UNDER the footer — and with the keyboard up both bars bottom-align on the same
// edge, so the footer covers the screen's own bar completely (measured on an
// iPhone 17 Pro: footer 760–874, create bar 700–791; keyboard up, footer 466–546
// vs create bar 455–546).
//
// Padding around it would mean re-deriving the footer's true reach at every call
// site — the same magic number the tab-root scroll views already hand-pad. A
// pushed full-screen form (or a conversation) gets the screen instead, which is
// also the platform convention (`.toolbar(.hidden, for: .tabBar)` for a real tab
// bar; Messages.app hides the bar when you push into a thread).
import SwiftUI

/// Preference a pushed screen sets to ask its shell to hide the footer.
///
/// Preferences travel UP the view tree, so this crosses the `NavigationStack`
/// boundary that keeps the pushed screen from seeing the footer's real height.
struct HidesShellFooterKey: PreferenceKey {
    static let defaultValue = false

    /// Any descendant asking for a hidden footer wins — a pushed screen's request
    /// must not be cancelled by the sibling tab roots reporting `false`.
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Hide the shell footer (`ProTabBar` / `TovisTabBar`) while this screen is on
    /// screen.
    ///
    /// Use on a pushed screen that pins its own bottom bar. The footer comes back
    /// when the screen is popped. No effect inside a `.sheet` — a sheet is its own
    /// presentation (preferences don't cross into the presenter's tree) and never
    /// had the footer over it.
    ///
    /// Also hides the SYSTEM tab bar for this screen. Both shells ask for that
    /// globally, but on iOS 26+ the system bar still draws its empty floating
    /// capsule — invisible only because the opaque custom bar sits on top of it.
    /// Remove the custom bar without this and the bare capsule shows through under
    /// the screen's own bottom bar.
    /// Takes no "unhide" argument on purpose: asking for `.automatic` here would
    /// override the shell's own `.toolbar(.hidden, for: .tabBar)` and put the empty
    /// system capsule back on screen.
    func hidesShellFooter() -> some View {
        self
            .toolbar(.hidden, for: .tabBar)
            .preference(key: HidesShellFooterKey.self, value: true)
    }
}
