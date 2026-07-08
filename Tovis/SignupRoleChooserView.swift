// The native signup entry point: choose Client or Pro. Mirrors the web signup
// role split (/signup). Client → the native ClientSignupView (wired to
// POST /api/v1/auth/register). Pro signup isn't native yet — that's a later PR —
// so the pro card explains it and points to the web for now.
//
// Presented as a full-screen cover from LoginView. On a successful client signup
// the session flips to `.needsVerification`, so RootView swaps to the phone
// verification screen and this cover is dismissed.
import SwiftUI

struct SignupRoleChooserView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Route: Hashable { case client, pro }
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                BrandColor.bgPrimary.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer().frame(height: 8)

                    VStack(spacing: 12) {
                        TovisEye(size: 64)
                        Text("Create your account")
                            .font(BrandFont.display(28, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("How will you use Tovis?")
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textMuted)
                    }

                    VStack(spacing: 14) {
                        roleCard(
                            title: "I'm a client",
                            blurb: "Find pros, book fast, and keep your beauty life organized.",
                            symbol: "sparkles"
                        ) { path.append(.client) }

                        roleCard(
                            title: "I'm a professional",
                            blurb: "Grow your business, manage bookings, and showcase your work.",
                            symbol: "scissors"
                        ) { path.append(.pro) }
                    }

                    Spacer()
                }
                .padding(.horizontal, 28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(BrandFont.body(15))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .client: ClientSignupView()
                case .pro: ProSignupUnavailableView()
                }
            }
        }
        .onDisappear { session.errorMessage = nil }
    }

    private func roleCard(
        title: String,
        blurb: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            BrandSurface {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BrandColor.accent)
                        .frame(width: 44, height: 44)
                        .background(BrandColor.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(BrandFont.body(17, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(blurb)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textMuted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Pro signup isn't native yet — point pros to the web signup for now. Removed
/// once the native pro signup flow lands (A1, later PR).
private struct ProSignupUnavailableView: View {
    private let proSignupURL = URL(string: "https://www.tovis.app/signup")

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                Image(systemName: "hammer.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(BrandColor.accent)

                Text("Pro signup is coming to the app")
                    .font(BrandFont.display(24, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text("We're building the professional signup natively. In the meantime you can create your pro account on the web — then sign in here.")
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if let proSignupURL {
                    Link(destination: proSignupURL) {
                        Text("Sign up on the web")
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(BrandColor.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.top, 6)
                }

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .navigationTitle("Professional")
        .navigationBarTitleDisplayMode(.inline)
    }
}
