import UIKit

/// Thin wrappers over UIKit's feedback generators, so the app's haptic moments
/// stay consistent instead of each call site picking its own generator + style.
///
/// Only the follow controls route through here today. `ProCapturePhotosView` and
/// `CoachEngine` still hand-roll their own (and `ProCalendarTimeGrid` uses
/// SwiftUI's `.sensoryFeedback`, which is the better tool inside a view body) —
/// folding those in is a follow-up, not this change.
enum Haptics {
    /// An optimistic control had to roll back because the request failed.
    ///
    /// The rollback is *visible* — the pill flips back on its own — but on its
    /// own that reads like a mis-tap rather than a failure, so this disambiguates
    /// it. Deliberately not a message: a follow lives on surfaces (the fullscreen
    /// looks pager) with nowhere to put one, and the failure is low-stakes and
    /// retryable by tapping again.
    @MainActor
    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
