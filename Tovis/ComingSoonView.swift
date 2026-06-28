// Branded placeholders for the footer tabs whose full screens aren't built on
// iOS yet (Discover → /search, Looks → /looks, Inbox → /messages, Me →
// /client/me on web). They keep the footer fully functional and on-brand while
// each surface is built out (see HANDOFF "iterate outward" + push/messages).
import SwiftUI

struct ComingSoonView: View {
    let title: String
    let systemImage: String
    let blurb: String

    var body: some View {
        NavigationStack {
            ZStack {
                BrandColor.bgPrimary.ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(BrandColor.accent)
                    Text(title)
                        .font(BrandFont.display(24, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(blurb)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textMuted)
                        .multilineTextAlignment(.center)
                    BrandPill(text: "Coming soon", tint: BrandColor.gold)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 40)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(BrandColor.accent)
    }
}

// Convenience builders so the tabs read clearly in MainTabView.
extension ComingSoonView {
    static var discover: ComingSoonView {
        ComingSoonView(
            title: "Discover",
            systemImage: "safari",
            blurb: "Find pros and services near you. Search and the map are on the way."
        )
    }

    static var looks: ComingSoonView {
        ComingSoonView(
            title: "Looks",
            systemImage: "sparkles",
            blurb: "The viral looks feed lands here — browse, save, and rebook the styles you love."
        )
    }

    static var inbox: ComingSoonView {
        ComingSoonView(
            title: "Inbox",
            systemImage: "envelope",
            blurb: "Messages with your pros will live here once chat ships to the app."
        )
    }
}