// The "Invite a friend" card — the share half of the web /client/referrals
// InviteLinkCard, condensed: the TOV-XXXX-XXXX code + a system share sheet for the
// absolutized /c/{code} URL. Shown on both the client Home (the web
// InviteFriendCard) and the Me tab. Backed by ReferralsService.inviteLink() →
// ClientInviteLink — no new endpoint. Extracted from MeView so Home and Me share
// one card (house rule: no duplicate logic).
import SwiftUI
import TovisKit

struct ClientInviteCard: View {
    let invite: ClientInviteLink

    var body: some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 12) {
                Label("INVITE A FRIEND", systemImage: "gift")
                    .font(BrandFont.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(BrandColor.textSecondary)
                    .labelStyle(.titleAndIcon)

                Text("Share your personal link. When a friend signs up and books, the referral is credited to you — same as a tap on your physical card.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)

                HStack(spacing: 10) {
                    Text(invite.shortCodeDisplay)
                        .font(BrandFont.mono(13))
                        .tracking(0.8)
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(BrandColor.bgPrimary.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))

                    Spacer()

                    if let url = shareURL {
                        ShareLink(
                            item: url,
                            subject: Text("Invite a friend"),
                            message: Text("Book with my link:")
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.onAccent)
                                .padding(.vertical, 9)
                                .padding(.horizontal, 14)
                                .background(BrandColor.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Absolutized share URL for the root-relative invite path. Mirrors the app's
    /// other ShareLink origins (hardcoded canonical web host).
    private var shareURL: URL? {
        URL(string: "https://www.tovis.app\(invite.path)")
    }
}
