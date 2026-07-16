import SwiftUI

/// Passwordless phone login: enter number → receive an SMS code → verify.
/// Presented as a sheet from the login screen.
struct PhoneLoginView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Step { case phone, code }
    @State private var step: Step = .phone
    @State private var phone = ""
    @State private var code = ""

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            VStack(spacing: 24) {
                TovisEye(size: 56)

                switch step {
                case .phone:
                    Text("Sign in with your phone")
                        .font(BrandFont.display(24, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("We'll text you a 6-digit code.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textMuted)

                    BrandField(placeholder: "+1 555 555 5555", text: $phone, isSecure: false)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)

                    errorText

                    primaryButton(title: "Send code") {
                        Task {
                            if await session.phoneSend(phone) { step = .code }
                        }
                    }
                    .disabled(phone.isEmpty || session.isWorking)
                    .opacity(phone.isEmpty ? 0.5 : 1)

                case .code:
                    Text("Enter your code")
                        .font(BrandFont.display(24, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Sent to \(phone)")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textMuted)

                    BrandField(placeholder: "123456", text: $code, isSecure: false)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)

                    errorText

                    primaryButton(title: "Verify") {
                        Task {
                            await session.phoneVerify(phone: phone, code: code)
                            if session.state == .signedIn { dismiss() }
                        }
                    }
                    .disabled(code.count < 6 || session.isWorking)
                    .opacity(code.count < 6 ? 0.5 : 1)

                    HStack(spacing: 18) {
                        // Web's phone-login card has a resend; native never did,
                        // so a user whose code never arrived had to back out and
                        // retype the number to get another.
                        OTPResendButton(
                            cooldown: session.phoneLoginCooldown,
                            isWorking: session.isWorking
                        ) {
                            Task { await session.resendPhoneLoginCode(phone) }
                        }

                        Button("Use a different number") {
                            code = ""
                            // A different number is throttled under its own key,
                            // so this number's wait must not follow the user back.
                            session.resetPhoneLoginCooldown()
                            step = .phone
                        }
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.accent)
                    }
                }

                Spacer()
            }
            .padding(28)
        }
        .presentationDetents([.medium])
        .onDisappear { session.errorMessage = nil }
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