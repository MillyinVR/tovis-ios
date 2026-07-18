import SwiftUI
import TovisKit

/// "Creators to follow" — the native counterpart of web's `FollowSuggestionsRail`
/// (app/client/(gated)/_components/FollowSuggestionsRail.tsx), in the same place:
/// the top of Me › FOLLOWING, above the followed-pros list.
///
/// Suggestions are **clients**, not pros — the server ranks the client authors
/// whose looks you've liked — so the row links to `PublicClientViewerView` and
/// follows by handle, while the list underneath stays pros. That asymmetry is
/// web's too, not something introduced here.
///
/// Renders nothing at all until it has at least one suggestion, matching web's
/// early `return null`: the empty state below is about *follows*, and a "no
/// suggestions" placeholder next to it would read as a second, contradictory one.
struct FollowSuggestionsRail: View {
    @Environment(SessionModel.self) private var session

    @State private var items: [ClientFollowSuggestion] = []

    // The outer container ALWAYS exists, even with nothing to show. A `Group`
    // wrapping only a false `if` resolves to an empty view, and a `.task` hung off
    // that never installs — the rail then silently never fetches. That is exactly
    // how this shipped the first time: build green, tests green, and the endpoint
    // never once called from the device. An empty VStack lays out at zero height,
    // so costing nothing visually while keeping the task attached.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !items.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("CREATORS TO FOLLOW")
                        .font(BrandFont.mono(11)).tracking(1.4)
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    Text("From looks you’ve liked")
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(items) { item in
                            FollowSuggestionCard(suggestion: item)
                        }
                    }
                    .padding(.horizontal, 1)  // keeps card borders off the clip edge
                }

                // Owned here rather than by the parent's stack spacing, so an
                // empty rail contributes no gap above the list below it.
                Spacer().frame(height: 4)
            }
        }
        // Re-runs whenever the Following tab is shown, so a creator followed here
        // (or anywhere else) is gone from the rail next time — the server already
        // excludes the ones you follow, so there is nothing to prune locally.
        .task { await load() }
    }

    private func load() async {
        do {
            items = try await session.client.publicClient.followSuggestions()
        } catch {
            // A suggestions rail is the definition of non-essential: on any
            // failure it stays hidden rather than pushing an error at someone
            // who came here to look at their follows.
            items = []
        }
    }
}

/// One suggested creator. Tapping the avatar/handle opens their public profile;
/// the button follows in place.
private struct FollowSuggestionCard: View {
    let suggestion: ClientFollowSuggestion

    @Environment(SessionModel.self) private var session
    @State private var follow = FollowToggle()

    var body: some View {
        VStack(spacing: 8) {
            NavigationLink {
                PublicClientViewerView(handle: suggestion.handle)
            } label: {
                VStack(spacing: 7) {
                    BrandAvatar(name: suggestion.handle,
                                avatarUrl: suggestion.avatarUrl, size: 56)
                    Text("@\(suggestion.handle)")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View @\(suggestion.handle)")

            followButton
        }
        .frame(width: 128)
        .padding(.vertical, 12).padding(.horizontal, 8)
        .background(BrandColor.bgPrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
        )
    }

    private var followButton: some View {
        Button {
            Task { await toggle() }
        } label: {
            Text(follow.following ? "Following" : "Follow")
                .font(BrandFont.body(11.5, .bold))
                .foregroundStyle(follow.following ? BrandColor.textPrimary : BrandColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    follow.following ? AnyShapeStyle(BrandColor.bgSecondary) : AnyShapeStyle(BrandColor.accent),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        BrandColor.textPrimary.opacity(follow.following ? 0.15 : 0), lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        // Disabled once following — not just cosmetics, and the same rule web
        // applies. The route is a blind TOGGLE, so a second tap here would
        // silently UNFOLLOW, and since the server drops followed creators from
        // the list there'd be no row left to show it happened. Unfollowing lives
        // on the creator's profile, one tap away.
        .disabled(follow.isWorking || follow.following)
        .opacity(follow.isWorking ? 0.7 : 1)
        .accessibilityLabel(
            follow.following ? "Following @\(suggestion.handle)" : "Follow @\(suggestion.handle)"
        )
    }

    private func toggle() async {
        guard follow.begin() != nil else { return }
        do {
            follow.finish(
                try await session.client.publicClient.toggleFollow(handle: suggestion.handle)
            )
        } catch {
            follow.fail()
        }
    }
}
