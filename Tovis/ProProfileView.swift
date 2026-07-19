// Public professional profile — loads GET /api/v1/professionals/{id} and renders
// the same surface as the web profile page (app/professionals/[id]): a full-bleed
// hero (avatar image + gradient, @handle, display name, verified/license badges,
// subtext), a bio quote, a 4-up stats strip, a Book / Message CTA row, an
// accepted-payments card, and Portfolio / Services / Reviews tabs. Pushed from any
// pro name/avatar across the app.
import SwiftUI
import TovisKit

struct ProProfileView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let professionalId: String
    /// Optional name shown while the load is in flight.
    var fallbackName: String? = nil

    private enum Phase {
        case loading
        case loaded(ProProfile)
        case failed(String)
    }

    private enum ProfileTab: CaseIterable, Hashable {
        case portfolio, services, reviews

        var title: String {
            switch self {
            case .portfolio: return "Portfolio"
            case .services: return "Services"
            case .reviews: return "Reviews"
            }
        }
    }

    private let heroHeight: CGFloat = 360

    @State private var phase: Phase = .loading
    @State private var selectedTab: ProfileTab = .portfolio

    // Pro favorite (the hero heart).
    @State private var isFavorited = false
    @State private var favoriteWorking = false

    // Follow (the hero pill) — hydrated via GET /pros/{id}/follow after the
    // profile loads; guests / pro viewers just keep the stats count.
    @State private var follow = FollowToggle()

    // Per-service "Save" state, seeded from the offerings' isFavorited flags.
    @State private var savedServiceIds: Set<String> = []
    @State private var savingServiceIds: Set<String> = []

    // Per-review "Helpful" state, seeded from each review.
    @State private var helpfulByReview: [String: Bool] = [:]
    @State private var helpfulCountByReview: [String: Int] = [:]
    @State private var helpfulBusy: Set<String> = []

    // Booking / messaging / lightbox presentation.
    @State private var bookingOffering: ProOffering?
    @State private var bookingProName = ""
    @State private var messageNav: MessageThreadNav?
    @State private var messageWorking = false
    @State private var fullscreenMedia: FullscreenMedia?

    private var shareURL: URL? {
        URL(string: "https://www.tovis.app/professionals/\(professionalId)")
    }

    private var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                loadingState
            case let .failed(message):
                errorState(message)
            case let .loaded(profile):
                content(profile)
            }
        }
        .background(BrandColor.bgPrimary)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            if !isLoaded {
                ghostCircleButton(system: "chevron.left") { dismiss() }
                    .padding(.leading, 16)
                    .padding(.top, 54)
            }
        }
        .task {
            if case .loading = phase { await load() }
        }
        .sheet(item: $bookingOffering) { offering in
            BookingFlowView(professionalId: professionalId, proName: bookingProName, offering: offering)
        }
        .navigationDestination(item: $messageNav) { nav in
            ThreadView(thread: nav.thread)
        }
        .mediaFullscreenCover($fullscreenMedia)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ profile: ProProfile) -> some View {
        VStack(spacing: 0) {
            heroImageBlock(profile)

            // Bio / stats / CTA — full-bleed blocks with hairline dividers, matching
            // the web hero card's stacked sections.
            if let bio = profile.header.bio, !bio.isEmpty {
                hairline
                bioQuote(bio)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }

            hairline
            statsStrip(profile.stats)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            hairline
            ctaRow(profile)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            if !profile.acceptedPayments.isEmpty {
                acceptedPaymentsCard(profile.acceptedPayments)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
            }

            hairline.padding(.top, 16)
            tabsBar()
                .padding(.horizontal, 20)
                .padding(.top, 12)
            hairline

            tabContent(profile)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 44)
        }
    }

    // MARK: - Hero

    private func heroImageBlock(_ profile: ProProfile) -> some View {
        ZStack(alignment: .bottomLeading) {
            heroBackground(profile.header.avatarUrl)
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: BrandColor.bgPrimary.opacity(0.38), location: 0),
                    .init(color: .clear, location: 0.32),
                    .init(color: BrandColor.bgPrimary.opacity(0.98), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            heroBottomContent(profile.header, stats: profile.stats)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .top) {
            heroActions(profile.header)
                .padding(.horizontal, 16)
                .padding(.top, 54)
        }
    }

    @ViewBuilder
    private func heroBackground(_ avatarUrl: String?) -> some View {
        if let raw = avatarUrl, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    heroFallback
                }
            }
        } else {
            heroFallback
        }
    }

    private var heroFallback: some View {
        LinearGradient(
            colors: [
                BrandColor.accent.opacity(0.35),
                BrandColor.bgSecondary,
                BrandColor.iris.opacity(0.35),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func heroActions(_ header: ProProfileHeader) -> some View {
        HStack(spacing: 8) {
            ghostCircleButton(system: "chevron.left") { dismiss() }
            Spacer()
            if let url = shareURL {
                ShareLink(item: url) {
                    ghostPillLabel(system: "square.and.arrow.up", text: "Share")
                }
                .buttonStyle(.plain)
            }
            favoriteButton
        }
    }

    private func heroBottomContent(_ header: ProProfileHeader, stats: ProProfileStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let handle = header.displayHandle, !handle.isEmpty {
                Text(handle)
                    .font(BrandFont.mono(10))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(BrandColor.textMuted)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(header.displayName)
                    .font(BrandFont.display(32, .semibold))
                    .italic()
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if header.isPremium {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(BrandColor.iris)
                        .accessibilityLabel("Verified professional")
                }
            }

            if header.isLicenseVerified {
                licenseBadge
            }

            subtextRow(header, stats: stats)

            followRow

            socialChips(header)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Outbound social-presence chips — the web SocialLinkChips (PR #478).
    /// Handles arrive without "@"; nothing renders when all three are unset.
    @ViewBuilder
    private func socialChips(_ header: ProProfileHeader) -> some View {
        let chips: [(label: String, url: URL?)] = [
            header.instagramHandle.flatMap { h in
                ("IG @\(h)", URL(string: "https://instagram.com/\(h)"))
            },
            header.tiktokHandle.flatMap { h in
                ("TikTok @\(h)", URL(string: "https://www.tiktok.com/@\(h)"))
            },
            header.websiteUrl.flatMap { w in
                ("Website", URL(string: w))
            },
        ].compactMap { $0 }

        if !chips.isEmpty {
            HStack(spacing: 8) {
                ForEach(chips, id: \.label) { chip in
                    if let url = chip.url {
                        Link(destination: url) {
                            Text(chip.label)
                                .font(BrandFont.body(11, .bold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(BrandColor.bgPrimary.opacity(0.4), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var licenseBadge: some View {
        Text("✓ License verified")
            .font(BrandFont.mono(10))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(BrandColor.iris)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(BrandColor.iris.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(BrandColor.iris.opacity(0.4), lineWidth: 1))
    }

    private func subtextRow(_ header: ProProfileHeader, stats: ProProfileStats) -> some View {
        var parts: [String] = [header.professionLabel]
        if let location = header.location, !location.isEmpty { parts.append(location) }
        if let rating = stats.averageRatingLabel { parts.append("★ \(rating)") }

        return Text(parts.joined(separator: "   ·   "))
            .font(BrandFont.body(12))
            .foregroundStyle(BrandColor.textSecondary)
            .lineLimit(2)
    }

    /// Follow pill + follower count — web ProfileHero parity (A3). Reuses the
    /// same /pros/{id}/follow endpoint as the feed's FOLLOW pill.
    private var followRow: some View {
        HStack(spacing: 8) {
            let isFollowing = follow.following
            Button {
                Task { await toggleFollow() }
            } label: {
                Text(isFollowing ? "FOLLOWING" : "FOLLOW")
                    .font(BrandFont.mono(10))
                    .tracking(1)
                    .foregroundStyle(isFollowing ? .white.opacity(0.7) : .white)
                    .padding(.vertical, 5).padding(.horizontal, 12)
                    .background(
                        isFollowing ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(BrandColor.accent.opacity(0.25)),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(isFollowing ? .white.opacity(0.35) : BrandColor.accent.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(follow.isWorking)
            .accessibilityLabel(isFollowing ? "Unfollow" : "Follow")

            if follow.followerCount > 0 {
                Text(follow.followerCount == 1 ? "1 follower" : "\(follow.followerCount) followers")
                    .font(BrandFont.mono(11))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.top, 2)
    }

    private var favoriteButton: some View {
        Button {
            Task { await toggleFavorite() }
        } label: {
            Image(systemName: isFavorited ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFavorited ? BrandColor.ember : .white)
                .frame(width: 38, height: 38)
                .background(BrandColor.bgPrimary.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(favoriteWorking)
        .accessibilityLabel(isFavorited ? "Saved" : "Save pro")
    }

    // MARK: - Bio / stats / CTA

    private func bioQuote(_ bio: String) -> some View {
        Text("“\(bio)”")
            .font(BrandFont.display(15, .regular))
            .italic()
            .foregroundStyle(BrandColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statsStrip(_ stats: ProProfileStats) -> some View {
        HStack(spacing: 0) {
            statCell("From", stats.priceFromLabel ?? "—")
            statCell("Booked", stats.completedBookingsLabel)
            statCell("Rating", stats.averageRatingLabel ?? "—")
            statCell("Saved", stats.favoritesLabel)
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(BrandFont.display(19, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(BrandFont.mono(10))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(BrandColor.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func ctaRow(_ profile: ProProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .services }
            } label: {
                Text("Book now")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(BrandColor.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                Task { await openMessageThread() }
            } label: {
                HStack(spacing: 6) {
                    if messageWorking {
                        ProgressView().tint(BrandColor.textPrimary).scaleEffect(0.75)
                    }
                    Text("Message")
                }
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(BrandColor.bgSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(messageWorking)
        }
    }

    private func acceptedPaymentsCard(_ methods: [String]) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Accepted payments")
                    .font(BrandFont.body(12, .heavy))
                    .foregroundStyle(BrandColor.textPrimary)

                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(methods, id: \.self) { method in
                        Text(method)
                            .font(BrandFont.body(12, .heavy))
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(BrandColor.bgSecondary, in: Capsule())
                            .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1))
                    }
                }

                Text("Payment details are shared at checkout after you book.")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    // MARK: - Tabs

    private func tabsBar() -> some View {
        HStack(spacing: 24) {
            ForEach(ProfileTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.title)
                            .font(BrandFont.body(13, .heavy))
                            .foregroundStyle(selectedTab == tab ? BrandColor.textPrimary : BrandColor.textMuted)
                        Rectangle()
                            .fill(selectedTab == tab ? BrandColor.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func tabContent(_ profile: ProProfile) -> some View {
        switch selectedTab {
        case .portfolio:
            portfolioTab(profile.portfolioTiles)
        case .services:
            servicesTab(profile)
        case .reviews:
            reviewsTab(profile)
        }
    }

    // MARK: - Portfolio

    @ViewBuilder
    private func portfolioTab(_ tiles: [ProPortfolioTile]) -> some View {
        if tiles.isEmpty {
            emptyCard("No portfolio posts yet.")
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                spacing: 2
            ) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    portfolioTile(tile, isFirst: index == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func portfolioTile(_ tile: ProPortfolioTile, isFirst: Bool) -> some View {
        if let before = tile.before,
           let beforeStr = before.displayUrl,
           let beforeURL = URL(string: beforeStr),
           let afterURL = URL(string: tile.displayUrl) {
            // Paired before/after → the interactive comparison slider fills the
            // cell (parity with the web public portfolio grid). The slider owns
            // the tap/drag, so there's no fullscreen button here.
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        BeforeAfterCompareView(
                            beforeURL: beforeURL,
                            afterURL: afterURL,
                            height: geo.size.height,
                            cornerRadius: 0
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .clipped()
        } else {
            standardPortfolioTile(tile, isFirst: isFirst)
        }
    }

    // §19f — a portfolio tile IS a look, so tapping it opens the look post
    // (caption, service, tags, engagement), exactly as web's `PortfolioGrid`
    // links to `/looks/[lookId]`. The bare fullscreen viewer stays as the
    // fallback for a legacy tile with no backing look, mirroring web's own
    // fallback to `/media/[id]`.
    @ViewBuilder
    private func standardPortfolioTile(_ tile: ProPortfolioTile, isFirst: Bool) -> some View {
        if let lookId = tile.lookId {
            NavigationLink {
                LookDetailView(lookId: lookId)
            } label: {
                portfolioTileFace(tile, isFirst: isFirst)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                fullscreenMedia = FullscreenMedia.remote(
                    id: tile.id,
                    urlString: tile.src,
                    isVideo: tile.isVideo,
                    overlay: MediaCaptionOverlay.make(
                        caption: tile.caption,
                        serviceNames: tile.serviceNames
                    )
                )
            } label: {
                portfolioTileFace(tile, isFirst: isFirst)
            }
            .buttonStyle(.plain)
        }
    }

    private func portfolioTileFace(_ tile: ProPortfolioTile, isFirst: Bool) -> some View {
        Rectangle()
            .fill(BrandColor.bgSecondary)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let url = URL(string: tile.displayUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        BrandColor.bgSecondary
                    }
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if isFirst && tile.isFeaturedInPortfolio {
                    chip("★ FEAT", tint: BrandColor.iris).padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if tile.isVideo {
                    chip("VIDEO", tint: .white).padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !tile.serviceIds.isEmpty {
                    chip("SERVICE", tint: .white).padding(6)
                }
            }
            .contentShape(Rectangle())
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(BrandFont.mono(9))
            .foregroundStyle(tint)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Services

    @ViewBuilder
    private func servicesTab(_ profile: ProProfile) -> some View {
        if profile.offerings.isEmpty {
            emptyCard("No services listed yet.")
        } else {
            VStack(spacing: 12) {
                ForEach(profile.offerings) { offering in
                    ServiceCard(
                        offering: offering,
                        saved: savedServiceIds.contains(offering.serviceId),
                        busy: savingServiceIds.contains(offering.serviceId),
                        onBook: {
                            bookingProName = profile.header.displayName
                            bookingOffering = offering
                        },
                        onToggleSave: {
                            Task { await toggleServiceSave(offering.serviceId) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Reviews

    @ViewBuilder
    private func reviewsTab(_ profile: ProProfile) -> some View {
        VStack(spacing: 12) {
            reviewSummaryCard(profile.stats)

            if profile.reviews.isEmpty {
                emptyCard("No reviews yet.")
            } else {
                ForEach(profile.reviews) { review in
                    ReviewCard(
                        review: review,
                        helpful: helpfulByReview[review.id] ?? review.viewerHelpful,
                        helpfulCount: helpfulCountByReview[review.id] ?? review.helpfulCount,
                        busy: helpfulBusy.contains(review.id),
                        onToggleHelpful: { Task { await toggleHelpful(review) } },
                        onOpenMedia: { media in
                            fullscreenMedia = FullscreenMedia.remote(
                                id: media.id, urlString: media.url, isVideo: media.isVideo
                            )
                        }
                    )
                }
            }
        }
    }

    private func reviewSummaryCard(_ stats: ProProfileStats) -> some View {
        BrandSurface {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stats.averageRatingLabel ?? "—")
                        .font(BrandFont.display(40, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("\(stats.reviewCountLabel) reviews")
                        .font(BrandFont.mono(10))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(BrandColor.textMuted)
                }
                .frame(width: 92, alignment: .leading)

                VStack(spacing: 0) {
                    summaryLine("Reviews", stats.reviewCountLabel)
                    summaryLine("Rating", stats.averageRatingLabel ?? "—")
                    summaryLine("Saved", stats.favoritesLabel)
                }
            }
        }
    }

    private func summaryLine(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                Spacer()
                Text(value)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            .padding(.vertical, 8)
            Rectangle().fill(BrandColor.textMuted.opacity(0.1)).frame(height: 1)
        }
    }

    // MARK: - Shared pieces

    private func emptyCard(_ text: String) -> some View {
        BrandSurface {
            Text(text)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(BrandColor.textMuted.opacity(0.12))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private func ghostCircleButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(BrandColor.bgPrimary.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private func ghostPillLabel(system: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system).font(.system(size: 12, weight: .semibold))
            Text(text).font(BrandFont.body(13, .semibold))
        }
        .foregroundStyle(.white)
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(BrandColor.bgPrimary.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 160)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(fallbackName ?? "Profile")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load() }
            } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 150)
    }

    // MARK: - Actions

    private func load() async {
        phase = .loading
        do {
            let profile = try await session.client.profiles.professional(id: professionalId)
            isFavorited = profile.isFavoritedByMe
            // Seed the count from the profile stats; the follow flag itself is
            // only known after the hydrate below, so a refresh must not clear it.
            // `stats.followerCount` is optional on the wire and an absent count
            // renders as no count either way (the label is gated on `> 0`), so
            // collapsing nil to 0 here is not a visible change: the one case it
            // would differ — an optimistic nudge off an unknown count — needs the
            // hydrate below to have failed while the follow POST succeeds, which
            // can't happen, since both require the same client session.
            //
            // Never over a call in flight: rebuilding the toggle would clear its
            // busy flag, and a second tap on a BLIND toggle undoes the first. The
            // in-flight `finish()` lands the authoritative count moments later.
            if !follow.isWorking {
                follow = FollowToggle(
                    following: follow.following,
                    followerCount: profile.stats.followerCount ?? 0
                )
            }
            savedServiceIds = Set(profile.offerings.filter { $0.isFavorited }.map { $0.serviceId })
            helpfulByReview = Dictionary(
                profile.reviews.map { ($0.id, $0.viewerHelpful) },
                uniquingKeysWith: { first, _ in first }
            )
            helpfulCountByReview = Dictionary(
                profile.reviews.map { ($0.id, $0.helpfulCount) },
                uniquingKeysWith: { first, _ in first }
            )
            phase = .loaded(profile)

            // Best-effort follow-state hydrate: clients get their real state; a
            // guest or pro viewer errors (401/403) and keeps the defaults.
            if !follow.isWorking,
               let state = try? await session.client.looks.followState(professionalId: professionalId) {
                follow = FollowToggle(following: state.following, followerCount: state.followerCount)
            }
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }

    private func toggleFollow() async {
        // `begin()` carries the re-entrancy guard this used to hand-roll — and it
        // is load-bearing, not just tidy: the route is a blind toggle, so a second
        // call in flight would undo the first.
        var toggle = follow
        guard toggle.begin() != nil else { return }
        follow = toggle

        do {
            let state = try await session.client.looks.toggleFollow(
                professionalId: professionalId
            )
            toggle.finish(state)
        } catch {
            toggle.fail()
            Haptics.failure()
        }
        follow = toggle
    }

    private func toggleFavorite() async {
        guard !favoriteWorking else { return }
        favoriteWorking = true
        defer { favoriteWorking = false }

        let target = !isFavorited
        isFavorited = target // optimistic
        do {
            let result = try await session.client.profiles.setFavorite(
                professionalId: professionalId, favorited: target
            )
            isFavorited = result.favorited
        } catch {
            isFavorited = !target // revert on failure
        }
    }

    private func toggleServiceSave(_ serviceId: String) async {
        guard !savingServiceIds.contains(serviceId) else { return }
        savingServiceIds.insert(serviceId)
        defer { savingServiceIds.remove(serviceId) }

        let wasSaved = savedServiceIds.contains(serviceId)
        let target = !wasSaved
        if target { savedServiceIds.insert(serviceId) } else { savedServiceIds.remove(serviceId) }

        do {
            let result = try await session.client.profiles.setServiceFavorite(
                serviceId: serviceId, favorited: target
            )
            if result.favorited { savedServiceIds.insert(serviceId) } else { savedServiceIds.remove(serviceId) }
        } catch {
            if wasSaved { savedServiceIds.insert(serviceId) } else { savedServiceIds.remove(serviceId) }
        }
    }

    private func toggleHelpful(_ review: ProReview) async {
        let id = review.id
        guard !helpfulBusy.contains(id) else { return }
        helpfulBusy.insert(id)
        defer { helpfulBusy.remove(id) }

        let wasHelpful = helpfulByReview[id] ?? review.viewerHelpful
        let baseCount = helpfulCountByReview[id] ?? review.helpfulCount
        let target = !wasHelpful

        helpfulByReview[id] = target
        helpfulCountByReview[id] = max(0, baseCount + (target ? 1 : -1))

        do {
            let result = try await session.client.profiles.setReviewHelpful(reviewId: id, helpful: target)
            helpfulByReview[id] = result.helpful
            helpfulCountByReview[id] = result.helpfulCount
        } catch {
            helpfulByReview[id] = wasHelpful
            helpfulCountByReview[id] = baseCount
        }
    }

    private func openMessageThread() async {
        guard !messageWorking else { return }
        messageWorking = true
        defer { messageWorking = false }

        do {
            if let thread = try await session.client.messages.openProfileThread(professionalId: professionalId) {
                messageNav = MessageThreadNav(thread: thread)
            }
        } catch {
            // Best-effort: leave the user on the profile if the thread can't resolve.
        }
    }
}

// MARK: - Service card

private struct ServiceCard: View {
    let offering: ProOffering
    let saved: Bool
    let busy: Bool
    let onBook: () -> Void
    let onToggleSave: () -> Void

    var body: some View {
        BrandSurface {
            HStack(alignment: .top, spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(offering.name)
                        .font(BrandFont.body(14, .heavy))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)

                    if let description = offering.description, !description.isEmpty {
                        Text(description)
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                            .lineLimit(2)
                    }

                    if offering.pricingLines.isEmpty {
                        Text("Pricing not set")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                            .opacity(0.8)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(offering.pricingLines, id: \.self) { line in
                                Text(line)
                                    .font(BrandFont.body(12, .semibold))
                                    .foregroundStyle(BrandColor.textSecondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    Button(action: onBook) {
                        HStack(spacing: 4) {
                            Text("Book")
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(BrandColor.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onToggleSave) {
                        Text(busy ? "…" : (saved ? "Saved" : "Save"))
                            .font(BrandFont.body(12, .heavy))
                            .foregroundStyle(saved ? BrandColor.textPrimary : BrandColor.textSecondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(
                                (saved ? BrandColor.textPrimary : BrandColor.bgPrimary)
                                    .opacity(saved ? 0.14 : 0.45),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel(saved ? "Unsave service" : "Save service")
                }
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            if let raw = offering.imageUrl, let url = URL(string: raw) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
        )
    }

    private var fallback: some View {
        LinearGradient(
            colors: [BrandColor.accent.opacity(0.3), BrandColor.iris.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Review card

private struct ReviewCard: View {
    let review: ProReview
    let helpful: Bool
    let helpfulCount: Int
    let busy: Bool
    let onToggleHelpful: () -> Void
    let onOpenMedia: (ProReviewMedia) -> Void

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(review.clientName)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if !review.createdAt.isEmpty {
                            Text(Wire.dateOnly(review.createdAt))
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    Spacer()
                    Text(stars)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.gold)
                }

                if let headline = review.headline, !headline.isEmpty {
                    Text(headline)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }

                if let body = review.body, !body.isEmpty {
                    Text(body)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                if !review.mediaAssets.isEmpty {
                    reviewMedia
                }

                helpfulControl
            }
        }
    }

    // A paired "after" (carries `before`) renders as the full-width comparison
    // slider above the remaining thumbnails; the paired before + after drop out
    // of the flow so nothing shows twice (parity with the web ReviewsPanel).
    @ViewBuilder
    private var reviewMedia: some View {
        let paired = review.mediaAssets.first(where: { $0.before?.displayUrl != nil })
        let beforeId = paired?.before?.id
        let rest = review.mediaAssets.filter { $0.id != paired?.id && $0.id != beforeId }

        VStack(alignment: .leading, spacing: 6) {
            if let paired,
               let beforeStr = paired.before?.displayUrl,
               let beforeURL = URL(string: beforeStr),
               let afterURL = URL(string: paired.displayUrl) {
                BeforeAfterCompareView(beforeURL: beforeURL, afterURL: afterURL, height: 220, cornerRadius: 12)
            }
            if !rest.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(rest) { media in
                        Button {
                            onOpenMedia(media)
                        } label: {
                            reviewThumb(media)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func reviewThumb(_ media: ProReviewMedia) -> some View {
        ZStack {
            BrandColor.bgSecondary
            if let url = URL(string: media.displayUrl) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    BrandColor.bgSecondary
                }
            }
            if media.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var helpfulControl: some View {
        HStack(spacing: 8) {
            Button(action: onToggleHelpful) {
                Text(helpful ? "Helpful ✓" : "Helpful")
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(helpful ? BrandColor.accent : BrandColor.textSecondary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
                    .background((helpful ? BrandColor.accent : BrandColor.textMuted).opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)

            if helpfulCount > 0 {
                Text("\(helpfulCount) helpful")
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private var stars: String {
        let clamped = max(0, min(5, review.rating))
        return String(repeating: "★", count: clamped) + String(repeating: "☆", count: 5 - clamped)
    }
}
