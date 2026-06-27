import SwiftUI

/// Minimal email/password sign-in screen wired to the real `/api/v1/auth/login`.
/// This is a starting point — restyle to the Tovis brand as you build out.
struct LoginView: View {
    @Environment(SessionModel.self) private var session

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }

                if let message = session.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await session.login(email: email, password: password) }
                    } label: {
                        if session.isWorking {
                            ProgressView()
                        } else {
                            Text("Sign in")
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || session.isWorking)
                }
            }
            .navigationTitle("Tovis")
        }
    }
}