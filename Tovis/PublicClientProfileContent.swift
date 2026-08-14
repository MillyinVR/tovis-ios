// The shared public-creator-profile render — identity + standing · follow ·
// a Looks/Boards switcher. Used by BOTH the standalone `/u/{handle}` viewer
// (`PublicClientViewerView`, with an interactive follow control) and the pro
// client chart's read-only "public profile" toggle (`ProClientPublicProfileView`,
// mode `.hidden`). One view, two surfaces — the native mirror of the web's
// `PublicProfileView` (house rule: no duplicate logic).
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

    private enum Tab: String, CaseIterable {
        case looks = "LOOKS"
        case boards = "BOARDS"
    }
    @State private var tab: Tab

    /// DEBUG: start on a named tab, so the Boards panel can be photographed
    /// before shipping. Same reasoning as `TOVIS_DEBUG_OPEN_TAB` and
    /// `TOVIS_DEBUG_OPEN_DEEP_LINK` — this machine can't drive the simulator
    /// with synthetic taps, so a panel reachable ONLY by tapping would otherwise
    /// never be looked at. Release always starts on Looks.
    ///
    ///     SIMCTL_CHILD_TOVIS_DEBUG_PROFILE_TAB=boards xcrun simctl launch …
    private static var initialTab: Tab {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_PROFILE_TAB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw == "boards" { return .boards }
        #endif
        return .looks
    }

    @State private var follow: FollowToggle
    @State private var errorText: String?

    init(
        profile: ProClientPublicProfile,
        followMode: PublicProfileFollowMode,
        toggleFollow: (() async throws -> FollowState)? = nil
    ) {
        self.profile = profile
        self.followMode = followMode
        self.toggleFollow = toggleFollow
        _tab = State(initialValue: Self.initialTab)
        _follow = State(
            initialValue: FollowToggle(
                following: followMode.initialFollowing,
                followerCount: profile.counts.followers
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            // The design frame pairs Follow with a Message button. Message is
            // omitted deliberately: client↔client threads don't exist, and a
            // control that opens nothing is worse than no control.
            if followMode.showsFollowControl {
                followButton
                if let errorText {
                    Text(errorText)
                        .font(BrandFont.body(11, .semibold))
                        .foregroundStyle(BrandColor.ember)
                        .accessibilityLabel(errorText)
                }
            }
            tabBar
            switch tab {
            case .looks: looksPanel
            case .boards: boardsPanel
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                BrandAvatar(name: profile.handle, avatarUrl: profile.avatarUrl, size: 72)
                if profile.standing.tier == .tastemaker {
                    // Decorative twin of the Tastemaker pill below, which carries
                    // the accessible text — this must not repeat it to VoiceOver.
                    Circle()
                        .fill(BrandColor.bgPrimary)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().fill(BrandColor.gold).frame(width: 19, height: 19)
                                .overlay(Text("✦").font(.system(size: 10)).foregroundStyle(BrandColor.onAccent))
                        )
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(profile.displayName)
                    .font(BrandFont.display(24, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                standingRow
                statsRow
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var standingRow: some View {
        if profile.standing.tier != .none {
            // "top 5% saver · Brooklyn" — each half only appears when it's real.
            let detail = [
                profile.standing.topPercent.map { "top \($0)% saver" },
                profile.standing.city,
            ]
            .compactMap { $0 }
            .joined(separator: " · ")

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("✦")
                    Text(profile.standing.tier == .tastemaker ? "TASTEMAKER" : "RISING")
                }
                .font(BrandFont.mono(9)).fontWeight(.bold)
                .tracking(1)
                .foregroundStyle(BrandColor.gold)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .overlay(Capsule().stroke(BrandColor.gold, lineWidth: 1))

                if !detail.isEmpty {
                    Text(detail)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            stat("\(follow.followerCount)", "FOLLOWERS")
            stat("\(profile.counts.following)", "FOLLOWING")
            stat("\(profile.counts.looks)", "LOOKS")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(BrandFont.body(15, .bold)).foregroundStyle(BrandColor.textPrimary)
            Text(label).font(BrandFont.mono(9)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
        }
    }

    private var followButton: some View {
        Button {
            Task { await performToggle() }
        } label: {
            Text(follow.following ? "Following" : "Follow")
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(follow.following ? BrandColor.textPrimary : BrandColor.onAccent)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    follow.following ? AnyShapeStyle(BrandColor.bgSecondary) : AnyShapeStyle(BrandColor.accent),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(follow.following ? 0.3 : 0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(follow.isWorking)
        .opacity(follow.isWorking ? 0.7 : 1)
        .accessibilityLabel(follow.following ? "Unfollow" : "Follow")
    }

    // MARK: - Tabs

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                ForEach(Tab.allCases, id: \.self) { entry in
                    Button { tab = entry } label: {
                        VStack(spacing: 8) {
                            Text(entry.rawValue)
                                .font(BrandFont.body(12, .bold))
                                .tracking(0.8)
                                .foregroundStyle(tab == entry ? BrandColor.textPrimary : BrandColor.textMuted)
                            Rectangle()
                                .fill(tab == entry ? BrandColor.accent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == entry ? [.isSelected, .isButton] : .isButton)
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(BrandColor.textMuted.opacity(0.2))
        }
    }

    // MARK: - Looks

    @ViewBuilder
    private var looksPanel: some View {
        if profile.looks.isEmpty {
            Text("No public looks yet.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        } else {
            // One column on a phone: each card carries a title, a pro line, a
            // price and a full-width CTA, which a 3-up grid would clip to
            // unreadable — the same reason the web frame drops to one column.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                ForEach(profile.looks) { look in
                    lookCard(look)
                }
            }
        }
    }

    private func lookCard(_ look: ProClientPublicLook) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                LookDetailView(lookId: look.id)
            } label: {
                // 🔴 The photo is an OVERLAY on a sized, clipped spacer, not a
                // sibling in a ZStack. `.scaledToFill()` inflates its own layout
                // size, so as a ZStack child it grew the stack past the card's
                // frame and pushed the title + pro line out of the clip — the
                // caption rendered half-cut. As an overlay the image is sized BY
                // the container instead of sizing it.
                Color.clear
                    .aspectRatio(1.1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(BrandColor.bgSecondary)
                    .overlay {
                        if let url = look.imageUrl, let parsed = URL(string: url) {
                            AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: {
                                ProgressView().tint(BrandColor.accent)
                            }
                        }
                    }
                    .clipped()
                    .overlay {
                        LinearGradient(
                            colors: [
                                BrandColor.bgPrimary.opacity(0.85),
                                .clear,
                                BrandColor.bgPrimary.opacity(0.45),
                            ],
                            startPoint: .bottom, endPoint: .top
                        )
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(look.name)
                                .font(BrandFont.display(18, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            let proLine = [look.proName, look.serviceName]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                            if !proLine.isEmpty {
                                Text(proLine.uppercased())
                                    .font(BrandFont.mono(9)).tracking(0.8)
                                    .foregroundStyle(BrandColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(14)
                    }
                    .overlay(alignment: .top) {
                        HStack(alignment: .top) {
                            if look.spotlighted {
                                HStack(spacing: 4) {
                                    Circle().fill(BrandColor.gold).frame(width: 5, height: 5)
                                    Text("SPOTLIGHT")
                                }
                                .font(BrandFont.mono(9)).fontWeight(.bold).tracking(1)
                                .foregroundStyle(BrandColor.gold)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(BrandColor.bgPrimary.opacity(0.6), in: Capsule())
                                .overlay(Capsule().stroke(BrandColor.gold.opacity(0.6), lineWidth: 1))
                            }
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill").font(.system(size: 9))
                                Text("\(look.saveCount)").font(BrandFont.mono(9)).fontWeight(.bold)
                            }
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(BrandColor.bgPrimary.opacity(0.6), in: Capsule())
                        }
                        .padding(11)
                    }
            }
            .buttonStyle(.plain)

            VStack(spacing: 11) {
                HStack {
                    Text("\(look.recreatedCount) recreated this")
                        .font(BrandFont.mono(10)).foregroundStyle(BrandColor.textMuted)
                    Spacer()
                    // ⚠️ Server-composed "From $250" — a STARTING price. Rendered
                    // verbatim; never reformatted into a bare figure.
                    if let priceLabel = look.priceLabel {
                        Text(priceLabel)
                            .font(BrandFont.body(12.5, .semibold))
                            .foregroundStyle(BrandColor.accent)
                    }
                }
                NavigationLink {
                    LookDetailView(lookId: look.id, autoStartBooking: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .bold))
                        Text("Recreate this look").font(BrandFont.body(13, .semibold))
                    }
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(BrandColor.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(13)
        }
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Boards

    @ViewBuilder
    private var boardsPanel: some View {
        if profile.boards.isEmpty {
            Text("No shared boards yet.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                ForEach(profile.boards) { board in
                    NavigationLink {
                        PublicBoardView(handle: profile.handle, slug: board.slug)
                    } label: {
                        boardCard(board)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func boardCard(_ board: ProClientPublicBoard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Always four cells so a part-filled board keeps the mosaic's shape
            // instead of stretching one image across the whole tile.
            VStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<2, id: \.self) { column in
                            boardTile(board.tileImageUrls, index: row * 2 + column)
                        }
                    }
                    // Each row takes half the square; without this the rows are
                    // sized by their content and the quadrants come out uneven.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(board.name)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                Text("\(board.itemCount) SAVED")
                    .font(BrandFont.mono(9)).tracking(1)
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func boardTile(_ urls: [String], index: Int) -> some View {
        // Same shape as the look card's cover: the photo is an OVERLAY on a
        // flexible cell, never a ZStack sibling. `.scaledToFill()` sizes its own
        // layout, so as a sibling it drove the cell instead of filling it and the
        // quadrants came out ragged.
        BrandColor.bgPrimary
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if index < urls.count, let parsed = URL(string: urls[index]) {
                    AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                }
            }
            .clipped()
    }

    // MARK: - Follow

    private func performToggle() async {
        guard let toggleFollow, follow.begin() != nil else { return }
        errorText = nil
        do {
            follow.finish(try await toggleFollow())
        } catch {
            follow.fail()
            errorText = "Couldn’t update follow."
        }
    }
}
