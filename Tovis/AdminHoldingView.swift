import SwiftUI
import TovisKit

// The screen an ADMIN-role session lands on. The app has no native admin
// surfaces — admin tools live on the web (/admin) — and before this screen an
// admin sign-in fell through to the CLIENT shell, whose CLIENT-only endpoints
// all 403 an ADMIN token. That rendered as a wall of "Forbidden" with no way
// out: every escape hatch (settings hub → Sign out) sat behind screens that
// themselves failed to load. This holding screen says what happened and offers
// the one action that helps: sign out.
struct AdminHoldingView: View {
    @Environment(SessionModel.self) private var session
    /// Local, not `session.isWorking` — `logout()` never sets that flag, and a
    /// double-tap would fire two logout requests.
    @State private var isSigningOut = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 14) {
                TovisEye(size: 76)
                Text("Signed in as an admin")
                    .font(BrandFont.display(28, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .multilineTextAlignment(.center)
                if let email = session.currentUser?.email, !email.isEmpty {
                    Text(email)
                        .font(BrandFont.body(15))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Text("Admin tools live on the web — this app doesn’t have admin screens. Sign out to use a client or pro account here.")
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button(role: .destructive) {
                guard !isSigningOut else { return }
                isSigningOut = true
                Task { await session.logout() }
            } label: {
                Group {
                    if isSigningOut {
                        ProgressView().tint(BrandColor.ember)
                    } else {
                        Text("Sign out")
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.ember)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut)
        }
        .padding(28)
        .cappedWidth(AdaptiveWidth.reading)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
    }
}
