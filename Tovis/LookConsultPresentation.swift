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
