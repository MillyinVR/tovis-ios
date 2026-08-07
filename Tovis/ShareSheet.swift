// Thin SwiftUI wrapper over UIActivityViewController for sharing files/text
// (e.g. exporting the Finance CSV to Files/Mail/AirDrop). Present via
// `.sheet { ShareSheet(items: [url]) }`.
import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Fires once the activity controller is dismissed, shared or not — for a
    /// caller whose `items` are temp files it owns (e.g. a rendered export)
    /// and needs to clean up once Instagram/Messages/AirDrop is done reading
    /// them. `nil` for a caller with nothing to clean up (the default, so
    /// existing callers are unaffected).
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onDismiss?() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
