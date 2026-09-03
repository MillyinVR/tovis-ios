// Book the Look, slice B8 — presenting what a look's Book tap resolved to.
//
// ONE presenter for both look surfaces (the feed slide and the single-look
// detail), for the same reason `LookBooking` and `LookConsultEntry` are one
// each: the two render the same button, and a second copy of "which screen does
// a COMPLETED consult open" is how they drift apart.
import SwiftUI
import TovisKit

/// Everything the presenter needs, boxed so a bare destination can drive a
/// `.sheet(item:)` — the same idiom the look surfaces already use for the
/// booking sheet and the look detail.
struct LookConsultLaunch: Identifiable {
    let destination: LookConsultEntryDestination
    let lookPostId: String
    let professionalId: String
    /// The look's primary media — the booking sheet's cover comes from it.
    let lookMediaId: String?

    var id: String { destination.consultId }
}

struct LookConsultSheet: View {
    let launch: LookConsultLaunch

    var body: some View {
        switch launch.destination {
        case .resumeFlow:
            // The flow brings its own NavigationStack and Close button, and
            // create-or-resume is the server's answer — so this hands it the
            // LOOK, not the consult id it already resolved, and lets the same
            // idempotent call place the flow where it belongs.
            ConsultFlowView(
                anchor: .look(launch.lookPostId),
                professionalId: launch.professionalId,
                lookMediaId: launch.lookMediaId
            )
        case let .bookingProposal(consultId):
            ConsultBookingSheet(consultId: consultId, lookMediaId: launch.lookMediaId)
        }
    }
}

/// A client-only tap (Book) made while acting as PRO, on an account the server
/// says can also act as a client (`WORKSPACE_MISMATCH`). One presenter for both
/// look surfaces, for the same reason as the consult sheet above: the button is
/// the same, and two copies of "what does the switch offer" is how they drift.
///
/// Confirming switches workspaces and buffers a deep link back to THIS look with
/// booking started, so the client shell lands where the tap was headed rather
/// than on its home tab — the web's provider replays the refused request; this
/// is the native equivalent.
struct WorkspaceSwitchPrompt: Identifiable, Equatable {
    /// Where the client shell resumes once the switch lands.
    let resumeAt: PushDeepLink
    let id = UUID()

    static func bookLook(id lookPostId: String) -> WorkspaceSwitchPrompt {
        WorkspaceSwitchPrompt(resumeAt: PushDeepLink(target: .look(id: lookPostId, book: true)))
    }
}

extension View {
    func workspaceSwitchPrompt(_ prompt: Binding<WorkspaceSwitchPrompt?>) -> some View {
        modifier(WorkspaceSwitchPromptModifier(prompt: prompt))
    }
}

private struct WorkspaceSwitchPromptModifier: ViewModifier {
    @Environment(SessionModel.self) private var session
    @Binding var prompt: WorkspaceSwitchPrompt?

    func body(content: Content) -> some View {
        content.alert(
            "Switch to client to continue",
            isPresented: Binding(
                get: { prompt != nil },
                set: { if !$0 { prompt = nil } }
            ),
            presenting: prompt
        ) { prompt in
            Button("Switch to client") {
                Task { await session.switchWorkspace(to: .client, thenOpen: prompt.resumeAt) }
            }
            Button("Not now", role: .cancel) {}
        } message: { _ in
            Text("Booking lives in your client view. Switch now and this look opens ready to book.")
        }
    }
}

/// The booking door, presented as a sheet from a look. `ConsultBookingView`
/// pushes (a message thread, the picker), so it needs a stack of its own; when
/// it is reached from the consult RESULTS it is pushed onto the flow's stack
/// instead and brings none.
private struct ConsultBookingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let consultId: String
    let lookMediaId: String?

    var body: some View {
        NavigationStack {
            ConsultBookingView(consultId: consultId, lookMediaId: lookMediaId)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
                .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        }
        .tint(BrandColor.accent)
    }
}
