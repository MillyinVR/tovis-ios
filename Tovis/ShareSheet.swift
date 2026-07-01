// Thin SwiftUI wrapper over UIActivityViewController for sharing files/text
// (e.g. exporting the Finance CSV to Files/Mail/AirDrop). Present via
// `.sheet { ShareSheet(items: [url]) }`.
import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
