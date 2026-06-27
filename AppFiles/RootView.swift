import SwiftUI

/// Switches between the loading splash, sign-in, and the signed-in app.
struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        switch session.state {
        case .loading:
            ProgressView()
                .task { await session.bootstrap() }
        case .signedOut:
            LoginView()
        case .signedIn:
            SignedInView()
        }
    }
}

/// Placeholder home for an authenticated user. Replace with the real client/pro
/// experience (pull data from the typed services you'll add to TovisKit).
struct SignedInView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("You're signed in 🎉").font(.title2)
                if let user = session.currentUser {
                    Text(user.email).foregroundStyle(.secondary)
                    Text("Role: \(user.role.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Sign out", role: .destructive) {
                    Task { await session.logout() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Home")
        }
    }
}