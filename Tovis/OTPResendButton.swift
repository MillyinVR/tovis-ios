import SwiftUI
import TovisKit

/// The "Resend code" control for both SMS one-time-code surfaces — the
/// post-signup `PhoneVerificationView` and the passwordless `PhoneLoginView`.
/// Shared so the two can't drift; web's twins already have (one says
/// "Resend in 0:42", the other "Resend code in 0:42" — see verify-phone/page.tsx
/// and _components/login/PhoneLoginForm.tsx). One label here, deliberately.
///
/// ## Why TimelineView
/// `OTPResendCooldown` derives everything from a `now` it's handed, so the view
/// needs no countdown state of its own — `TimelineView(.periodic)` supplies the
/// clock and redraws once a second, and the label/disabled state fall out of it.
/// That also means the countdown is correct after the app has been backgrounded:
/// the deadline doesn't care that no timer was running, whereas a stored
/// "seconds remaining" that ticks down would resume stale and offer a resend the
/// server still refuses.
///
/// Not ticking at all until a cooldown has been started keeps the common case
/// (nothing sent yet) free of a once-a-second redraw.
struct OTPResendButton: View {
    let cooldown: OTPResendCooldown
    /// Suppresses the tap while a request is already running.
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        if cooldown.deadline == nil {
            label(remaining: nil)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                label(remaining: cooldown.remainingLabel(now: context.date))
            }
        }
    }

    private func label(remaining: String?) -> some View {
        Button {
            action()
        } label: {
            Text(remaining.map { "Resend code in \($0)" } ?? "Resend code")
        }
        .font(BrandFont.body(14))
        .foregroundStyle(BrandColor.accent)
        .disabled(remaining != nil || isWorking)
        .opacity(remaining != nil || isWorking ? 0.5 : 1)
    }
}
