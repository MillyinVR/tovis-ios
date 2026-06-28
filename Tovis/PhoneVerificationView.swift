// Post-signup phone verification. Shown as a root state (SessionModel.state ==
// .needsVerification) for a signed-in-but-not-fully-verified account — the common
// case being Sign in with Apple, which verifies the email but leaves the phone
// unverified. Enter phone → set it + receive an SMS code → verify → into the app.
//
// Uses the authenticated /auth/phone/{correct,send,verify} endpoints (distinct
// from the passwordless phone-LOGIN flow in PhoneLoginView).
import SwiftUI

struct PhoneVerificationView: View {
    @Environment(SessionModel.self) private var session

    private enum Step { case phone, code }
    @State private var step: Step = .phone
    @State private var phone = ""
    @State private var code = ""

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer().frame(height: 8)
                TovisEye(size: 60)

                switch step {
                case .phone:
                    title("Verify your phone")
                    subtitle("One quick step to finish setting up your account. We’ll text you a 6-digit code.")

                    BrandField(placeholder: "+1 555 555 5555", text: $phone, isSecure: false)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)

                    errorText

                    primaryButton(title: "Send code") {
                        Task {
                            if await session.submitVerificationPhone(phone) { step = .code }
                        }
                    }
                    .disabled(phone.isEmpty || session.isWorking)
                    .opacity(phone.isEmpty ? 0.5 : 1)

                case .code:
                    title("Enter your code")
                    subtitle("Sent to \(phone)")

                    BrandField(placeholder: "123456", text: $code, isSecure: false)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)

                    errorText

                    primaryButton(title: "Verify") {
                        Task { await session.verifyPhoneCode(code) }
                    }
                    .disabled(code.count < 6 || session.isWorking)
                    .opacity(code.count < 6 ? 0.5 : 1)

                    HStack(spacing: 18) {
                        Button("Resend code") {
                            Task { await session.resendVerificationCode() }
                        }
                        Button("Change number") {
                            code = ""
                            step = .phone
                        }
                    }
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.accent)
                    .padding(.top, 2)
                }

                Spacer()

                Button("Sign out") {
                    Task { await session.cancelVerification() }
                }
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
            }
            .padding(28)
        }
        .onDisappear { session.errorMessage = nil }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.display(26, .semibold))
            .foregroundStyle(BrandColor.textPrimary)
            .multilineTextAlignment(.center)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textMuted)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder private var errorText: some View {
        if let message = session.errorMessage {
            Text(message)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.ember)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if session.isWorking {
                    ProgressView().tint(BrandColor.onAccent)
                } else {
                    Text(title).font(BrandFont.body(17, .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BrandColor.accent)
            .foregroundStyle(BrandColor.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
