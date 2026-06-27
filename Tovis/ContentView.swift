// Tovis app — entry point, auth state, and branded screens.
// Styled with the Peacock Plume tokens (Theme/BrandColor + BrandFont).
import SwiftUI
import TovisKit
import AuthenticationServices

// MARK: - App entry point

@main
struct TovisApp: App {
    @State private var session = SessionModel(config: .local)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .preferredColorScheme(.dark) // brand default mode is dark
        }
    }
}

// MARK: - Auth state (owns the TovisClient)

@MainActor
@Observable
final class SessionModel {
    enum State: Equatable { case loading, signedOut, signedIn }

    private(set) var state: State = .loading
    private(set) var currentUser: AuthUser?
    var isWorking = false
    var errorMessage: String?

    let client: TovisClient

    init(config: TovisConfig) {
        self.client = TovisClient(config: config)
    }

    func bootstrap() async {
        state = await client.auth.hasSession() ? .signedIn : .signedOut
    }

    func login(email: String, password: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.login(
                email: email,
                password: password,
                deviceId: client.deviceId
            )
            currentUser = result.user
            state = .signedIn
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    func appleLogin(identityToken: String, firstName: String?, lastName: String?) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.appleLogin(
                identityToken: identityToken,
                firstName: firstName,
                lastName: lastName,
                deviceId: client.deviceId
            )
            currentUser = result.user
            state = .signedIn
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    /// Phone-OTP step 1. Returns true if the request was accepted (move to the
    /// code step). The response is generic, so this never reveals account existence.
    func phoneSend(_ phone: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await client.auth.phoneLoginSend(phone: phone)
            return true
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Something went wrong. Please try again."
            return false
        }
    }

    /// Phone-OTP step 2. On success, signs in.
    func phoneVerify(phone: String, code: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.phoneLoginVerify(
                phone: phone,
                code: code,
                deviceId: client.deviceId
            )
            currentUser = result.user
            state = .signedIn
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    func logout() async {
        await client.auth.logout()
        currentUser = nil
        state = .signedOut
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            switch session.state {
            case .loading:
                ProgressView()
                    .tint(BrandColor.accent)
                    .task { await session.bootstrap() }
            case .signedOut:
                LoginView()
            case .signedIn:
                SignedInView()
            }
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @Environment(SessionModel.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var showPhone = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 14) {
                TovisEye(size: 76)
                Text("tovis")
                    .font(BrandFont.display(44, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("The New Age of Self Care")
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textMuted)
            }

            VStack(spacing: 12) {
                BrandField(placeholder: "Email", text: $email, isSecure: false)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                BrandField(placeholder: "Password", text: $password, isSecure: true)
                    .textContentType(.password)

                if let message = session.errorMessage {
                    Text(message)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                Task { await session.login(email: email, password: password) }
            } label: {
                Group {
                    if session.isWorking {
                        ProgressView().tint(BrandColor.onAccent)
                    } else {
                        Text("Sign in").font(BrandFont.body(17, .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(BrandColor.accent)
                .foregroundStyle(BrandColor.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(email.isEmpty || password.isEmpty || session.isWorking)
            .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

            HStack(spacing: 12) {
                Rectangle().fill(BrandColor.textMuted.opacity(0.2)).frame(height: 1)
                Text("or").font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                Rectangle().fill(BrandColor.textMuted.opacity(0.2)).frame(height: 1)
            }

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                showPhone = true
            } label: {
                Text("Continue with phone")
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1)
                    )
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .sheet(isPresented: $showPhone) {
            PhoneLoginView()
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8)
            else {
                return
            }
            // fullName is only populated on the user's FIRST authorization.
            let first = credential.fullName?.givenName
            let last = credential.fullName?.familyName
            Task {
                await session.appleLogin(identityToken: token, firstName: first, lastName: last)
            }
        case .failure:
            // User canceled or the request failed — leave the screen as-is.
            break
        }
    }
}

/// A brand-styled text/secure field (replaces the default iOS look with the
/// dark surface + subtle border the web uses).
struct BrandField: View {
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
            }
        }
        .font(BrandFont.body(16))
        .foregroundStyle(BrandColor.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(BrandColor.textMuted)
    }
}

// MARK: - Signed in (placeholder)

struct SignedInView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            TovisEye(size: 56)
            Text("You're signed in 🎉")
                .font(BrandFont.body(18, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            if let user = session.currentUser {
                Text(user.email)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
                Text(user.role.rawValue)
                    .font(BrandFont.mono(12))
                    .foregroundStyle(BrandColor.textMuted)
            }

            Button {
                Task { await session.logout() }
            } label: {
                Text("Sign out")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.ember)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
                    )
            }
            .padding(.top, 8)
        }
        .padding()
    }
}
