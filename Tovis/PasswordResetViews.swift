// Native password reset — mirrors the web flow (ForgotPasswordClient +
// ResetPasswordClient), wired to /api/v1/auth/password-reset/{request,confirm}
// via SessionModel.
//
// ForgotPasswordView (request): presented as a sheet from LoginView. Enter your
// email → we email a reset link. Enumeration-safe: the confirmation is identical
// whether or not an account exists.
//
// ResetPasswordView (confirm): presented full-screen from RootView when a
// password-reset Universal Link (https://…/reset-password/<token>) is tapped.
// Set a new password using the token that link carries. Reaching this screen
// natively depends on the app's associated-domains entitlement + the web AASA
// (app/.well-known/apple-app-site-association); without them the link opens the
// web reset page instead.
import SwiftUI
import TovisKit

// MARK: - Request a reset link

struct ForgotPasswordView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var sent = false

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            VStack(spacing: 24) {
                TovisEye(size: 56)

                if sent {
                    Text("Check your inbox")
                        .font(BrandFont.display(24, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("If an account exists for \(email.isEmpty ? "that email" : email), you’ll get a reset link shortly.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    SignupPrimaryButton(title: "Done", isLoading: false) { dismiss() }
                } else {
                    Text("Reset your password")
                        .font(BrandFont.display(24, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("We’ll email you a secure reset link.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textMuted)

                    BrandField(placeholder: "you@email.com", text: $email, isSecure: false)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    errorText

                    SignupPrimaryButton(
                        title: "Send reset link",
                        isLoading: session.isWorking,
                        isDisabled: email.isEmpty || session.isWorking
                    ) {
                        Task {
                            let trimmed = email.trimmingCharacters(in: .whitespaces)
                            if await session.requestPasswordReset(email: trimmed) {
                                sent = true
                            }
                        }
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
}

// MARK: - Set a new password (from a tapped reset link)

struct ResetPasswordView: View {
    @Environment(SessionModel.self) private var session

    let token: String

    private static let passwordMinLength = 10

    @State private var password = ""
    @State private var done = false
    @State private var formError: String?

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            VStack(spacing: 22) {
                TovisEye(size: 56)

                if done {
                    Text("Password updated")
                        .font(BrandFont.display(24, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("You can now sign in with your new password.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textMuted)
                        .multilineTextAlignment(.center)

                    SignupPrimaryButton(title: "Back to sign in", isLoading: false) {
                        session.clearPasswordResetToken()
                    }
                } else {
                    VStack(spacing: 6) {
                        Text("Choose a new password")
                            .font(BrandFont.display(24, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Make it something you won’t reuse everywhere.")
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textMuted)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SignupFieldLabel("New password")
                        PasswordRevealField(
                            placeholder: "New password",
                            text: $password,
                            textContentType: .newPassword
                        )
                        Text("At least \(Self.passwordMinLength) characters.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }

                    if let message = formError ?? session.errorMessage {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SignupPrimaryButton(
                        title: "Update password",
                        isLoading: session.isWorking,
                        isDisabled: session.isWorking
                    ) {
                        Task { await handleSubmit() }
                    }
                }

                Button("Cancel") { session.clearPasswordResetToken() }
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.accent)

                Spacer()
            }
            .padding(28)
        }
        .onDisappear { session.errorMessage = nil }
    }

    private func handleSubmit() async {
        formError = nil
        session.errorMessage = nil

        guard password.count >= Self.passwordMinLength else {
            formError = "Password must be at least \(Self.passwordMinLength) characters."
            return
        }

        if await session.confirmPasswordReset(token: token, password: password) {
            done = true
        }
    }
}
