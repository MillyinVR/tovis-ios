import SwiftUI
import TovisKit

/// Resolve the authenticated consult before opening its existing flow.
struct ConsultNotificationView: View {
    let consultId: String
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var thread: ConsultThread?
    @State private var failed = false
    var body: some View {
        Group {
            if let thread, let lookId = thread.book.lookPostId {
                ConsultFlowView(anchor: .look(lookId), professionalId: thread.professionalId)
            } else if let thread, let bookingId = thread.messages.compactMap(\.bookingId).first {
                ConsultFlowView(bookingId: bookingId, professionalId: thread.professionalId)
            } else if failed || thread != nil {
                VStack(spacing: 16) {
                    Text("This consultation is unavailable.")
                    Button("Try again") { Task { await load() } }
                    Button("Close") { dismiss() }
                }
            } else { ProgressView() }
        }.task { await load() }.tint(BrandColor.accent)
    }
    private func load() async {
        failed = false
        do { thread = try await session.client.consult.thread(consultId: consultId) }
        catch { failed = true }
    }
}
