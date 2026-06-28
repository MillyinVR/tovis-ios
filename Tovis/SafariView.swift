// A thin SwiftUI wrapper around SFSafariViewController — used to present the
// hosted Stripe Checkout page in-app. The page's success/cancel redirect bounces
// to the `tovis://checkout/return` scheme (see tovis-app app/checkout/return),
// which iOS hands to the app via `.onOpenURL`; the presenter dismisses this and
// refetches the booking. `onFinish` covers the manual "Done" tap as a fallback.
import SwiftUI
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.preferredControlTintColor = UIColor(BrandColor.accent)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
