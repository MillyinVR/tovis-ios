// The shared public-creator-profile render — avatar · @handle · follow stats ·
// bio · published-looks grid. Used by BOTH the standalone `/u/{handle}` viewer
// (`PublicClientViewerView`, with an interactive follow control) and the pro
// client chart's read-only "public profile" toggle (`ProClientPublicProfileView`,
// mode `.hidden`). One view, two surfaces — the native mirror of the web's shared
// `PublicProfileView` + `ProfileStats` (house rule: no duplicate logic).
//
// Padding- and scroll-free by design: the host supplies the ScrollView + insets
// (the pro chart already wraps it in one; the viewer adds its own).
import SwiftUI
import TovisKit

/// Who is looking and what they can do — mirrors the web `FollowMode`. Native is
/// always authenticated, so there's no `guest` case; a signed-out-equivalent
/// (non-client viewer) maps to `.hidden`.
enum PublicProfileFollowMode: Equatable {
    /// The viewer is the profile owner — no follow control.
    case own
    /// A signed-in client (not the owner) — the interactive Follow toggle.
    case client(initialFollowing: Bool)
    /// Signed in but not as a client (pro/admin), or follow otherwise
    /// unavailable — no control. Also the pro chart's read-only mode.
    case hidden

    var showsFollowControl: Bool {
        if case .client = self { return true }
        return false
    }

    var initialFollowing: Bool {
        if case let .client(following) = self { return following }
        return false
    }
}

struct PublicClientProfileContent: View {
    let profile: ProClientPublicProfile
    let followMode: PublicProfileFollowMode
    /// Toggles the signed-in client's follow server-side and returns the
    /// authoritative state. Only invoked in `.client` mode; `nil` for read-only
    /// hosts (the pro chart).
    var toggleFollow: (() async throws -> FollowState)? = nil

    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            looksSection(profile.looks)
        }
        .mediaFullscreenCover($viewingMedia)
    }

    // MARK: - Header

    private var header: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    BrandAvatar(name: profile.handle, avatarUrl: profile.avatarUrl, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName)
                            .font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text("Public creator profile")
                            .font(BrandFont.mono(9)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                }
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                }
                PublicProfileStats(counts: profile.counts, mode: followMode, toggle: toggleFollow)
            }
        }
    }

    // MARK: - Looks grid

    private func looksSection(_ looks: [ProClientPublicLook]) -> some View {
        BrandSection(title: "Public looks", trailing: looks.isEmpty ? nil : "\(looks.count)") {
            if looks.isEmpty {
                Text("No public looks yet.").font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    ForEach(looks) { look in
                        Button {
                            guard let url = look.imageUrl else { return }
                            viewingMedia = FullscreenMedia.remote(id: look.id, urlString: url, isVideo: false)
                        } label: {
                            lookTile(look)
                        }
                        .buttonStyle(.plain)
                        .disabled(look.imageUrl == nil)
                    }
                }
            }
        }
    }

    private func lookTile(_ look: ProClientPublicLook) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                BrandColor.bgSecondary
                if let url = look.imageUrl, let parsed = URL(string: url) {
                    AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { ProgressView().tint(BrandColor.accent) }
                }
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.system(size: 8)).foregroundStyle(.white)
                    Text("\(look.saveCount)").font(BrandFont.mono(8)).foregroundStyle(.white)
                }
                .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.5)).clipShape(Capsule())
                .padding(6)
            }
            .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(look.name).font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.textSecondary).lineLimit(1)
        }
    }
}

/// The follower / following / looks stat row + the follow control — the native
/// mirror of the web `ProfileStats`. Owns the follower count + following flag so a
/// follow toggle can update optimistically, then reconcile with server truth.
private struct PublicProfileStats: View {
    let counts: ProClientPublicCounts
    let mode: PublicProfileFollowMode
    let toggle: (() async throws -> FollowState)?

    @State private var follow: FollowToggle
    @State private var errorText: String?

    init(counts: ProClientPublicCounts, mode: PublicProfileFollowMode, toggle: (() async throws -> FollowState)?) {
        self.counts = counts
        self.mode = mode
        self.toggle = toggle
        _follow = State(
            initialValue: FollowToggle(
                following: mode.initialFollowing,
                followerCount: counts.followers
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statTile("\(follow.followerCount)", "Followers")
                statTile("\(counts.following)", "Following")
                statTile("\(counts.looks)", "Looks")
            }
            if mode.showsFollowControl {
                followButton
                if let errorText {
                    Text(errorText).font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.ember)
                        .accessibilityLabel(errorText)
                }
            }
        }
    }

    private var followButton: some View {
        Button {
            Task { await performToggle() }
        } label: {
            Text(follow.following ? "Following" : "Follow")
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(follow.following ? BrandColor.textPrimary : BrandColor.onAccent)
                .frame(minWidth: 120)
                .padding(.vertical, 9).padding(.horizontal, 18)
                .background(
                    follow.following ? AnyShapeStyle(BrandColor.bgPrimary) : AnyShapeStyle(BrandColor.accent),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(follow.following ? 0.3 : 0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(follow.isWorking)
        .opacity(follow.isWorking ? 0.7 : 1)
        .accessibilityLabel(follow.following ? "Unfollow" : "Follow")
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
            Text(label.uppercased()).font(BrandFont.mono(8)).tracking(0.6).foregroundStyle(BrandColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(BrandColor.bgPrimary).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func performToggle() async {
        guard let toggle, follow.begin() != nil else { return }
        errorText = nil
        do {
            follow.finish(try await toggle())
        } catch {
            follow.fail()
            errorText = "Couldn’t update follow."
        }
    }
}
