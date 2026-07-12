import UIKit

extension UIApplication {
    /// The top-most presented view controller — the anchor UIKit SDKs (Stripe
    /// PaymentSheet, Google Sign-In) need in order to present over the SwiftUI
    /// hierarchy. Prefers the foreground-active scene's key window, then walks the
    /// presentation chain to whatever is on top.
    static func topPresentedViewController() -> UIViewController? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
