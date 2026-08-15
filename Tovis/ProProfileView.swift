// Public professional profile — loads GET /api/v1/professionals/{id} and renders
// the same surface as the web profile page (app/professionals/[id]). Pushed from
// any pro name/avatar across the app.
//
// Screen 6 redesign — "a profile you scroll, not a listing you scan":
//   - The header is a brand BAND, not a photograph. The old full-bleed hero
//     stretched `avatarUrl` behind the identity block — the exact thing web's
//     own code comment forbids — because iOS never decoded `coverUrl`. The band
//     retires that hero, so on THIS surface the coverUrl gap stops mattering;
//     the field still feeds share cards and search.
//   - The 4-up stats strip is GONE. "Nothing — and that is the answer." Trust
//     moves to the licence chip, the verified tick, the grid and the reviews.
//   - Booking lives in exactly two quiet places: an outline action on the
//     Signature post, and a slim bar between the end of the scroll and the
//     footer. Nothing floats and nothing follows the scroll.
//   - Urgency chips render on a BRAND-NEW pro only (Tori, 2026-08-15).
import SwiftUI
import TovisKit

/// Identifies a pro profile opened from a tapped `/professionals/{id}` link.
struct PublicProPresentation: Identifiable, Equatable {
    let professionalId: String
    var id: String { professionalId }
}

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

    /// The header band. Short by design — the first PHOTOGRAPH on the page
    /// should be the pro's work, not their face stretched behind their name.
    private let bandHeight: CGFloat = 132

    /// How far the shell's tab bar reaches past the bottom safe area it reports.
    /// See the `safeAreaInset` below for the measurement this comes from.
    private let shellFooterShortfall: CGFloat = 32

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

    /// The offering to book plus the pro's display name, carried together. The
    /// name used to live in a parallel `@State` written in the same action that
    /// presents the sheet; the sheet did not see it, so the booking flow rendered
    /// "with" and no pro. Every other launch site already passes a composite item
    /// (`DetailBookLaunch`, `RescheduleContext`) — this one was the outlier.
    private struct BookLaunch: Identifiable {
        let proName: String
        let offering: ProOffering
        var id: String { offering.id }
    }

    // Booking / messaging / lightbox presentation.
    @State private var bookLaunch: BookLaunch?
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
        // ⚠️ PINNED, which departs from the design frame's "nothing floats and
        // nothing follows the scroll". Tori's call (2026-08-15): at 200 looks
        // the grid is long enough that a bar only at the very end is a bar
        // nobody finds. `safeAreaInset` rather than an overlay so the scroll's
        // own content can still end above it instead of underneath.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case let .loaded(profile) = phase {
                VStack(spacing: 0) {
                    bookBar(profile)
                    // 🔴 The shell's tab bar paints ~114pt up from the screen
                    // bottom, but hands a PUSHED screen only 83pt of bottom safe
                    // area — so this bar laid out UNDER it and the CTA was
                    // clipped. MEASURED on an iPhone 17 Pro rather than guessed:
                    // screen 874, this container 62…791, safe-area bottom 83.
                    // 791 − (874 − 114) = 31pt short, so 32 clears it.
                    //
                    // Padding the VIEWPORT (this inset), not the scrolled
                    // content: padding inside the scroll would sit above the bar
                    // and change nothing. And NOT `hidesShellFooter()` — the
                    // other fix shape this repo has — because a client browsing
                    // a profile still needs the nav to leave it (Tori,
                    // 2026-08-15).
                    Color.clear.frame(height: shellFooterShortfall)
                }
            }
        }
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
        .sheet(item: $bookLaunch) { launch in
            BookingFlowView(
                professionalId: professionalId,
                proName: launch.proName,
                offering: launch.offering
            )
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
            headerBand(profile.header)

            identityRail(profile)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            tabsBar()
                .padding(.horizontal, 20)
                .padding(.top, 22)
            hairline

            tabContent(profile)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Header band

    /// No photograph sits behind the avatar on any profile now — the header is
    /// always a section band carrying the brand mark and the handle in small
    /// mono. That removes the no-cover state as a problem rather than solving
    /// it, and keeps the first photograph on the page the Signature post.
    private func headerBand(_ header: ProProfileHeader) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    BrandColor.accent.opacity(0.16),
                    BrandColor.bgSecondary,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                // The brand's primary lockup — the Eye plus the wordmark, the
                // same thing web's `BrandWordmark` renders here. Plain text set
                // in the display face is not the mark.
                BrandWordmarkLockup(size: 22)
                if let handle = header.displayHandle, !handle.isEmpty {
                    Text(handle)
                        .font(BrandFont.mono(10))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
            .padding(.top, 22)
        }
        .frame(height: bandHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            ghostCircleButton(system: "chevron.left") { dismiss() }
                .padding(.leading, 16)
                .padding(.top, 54)
        }
    }

    // MARK: - Identity rail

    private func identityRail(_ profile: ProProfile) -> some View {
        let header = profile.header

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                avatarCircle(header.avatarUrl, name: header.displayName)
                Spacer(minLength: 12)
                followPill
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(header.displayName)
                    .font(BrandFont.display(28, .semibold))
                    .italic()
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if header.isPremium {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(BrandColor.accent)
                        .accessibilityLabel("Verified professional")
                }
            }
            .padding(.top, 14)

            Text(handleAndFollowers(header))
                .font(BrandFont.mono(11))
                .tracking(1)
                .foregroundStyle(BrandColor.textMuted)
                .padding(.top, 6)

            Text(header.professionLabel)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .padding(.top, 6)

            // Tori's standing rule: every location on either client opens the
            // device's maps app. A public profile carries a display CITY, not a
            // street address and no coordinates, so this searches by text.
            if let location = header.location, !location.isEmpty {
                locationLine(location)
                    .padding(.top, 8)
            }

            chipRow(profile)

            if let bio = header.bio, !bio.isEmpty {
                Text(bio)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            socialActionRow
                .padding(.top, 16)

            socialChips(header)
                .padding(.top, 10)

            // Accepted payments moved UP, under the location: it answers a
            // practical question at the moment someone is working out whether
            // they can get to this pro. Handles stay hidden until checkout.
            if !profile.acceptedPayments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    hairline
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("ACCEPTS")
                            .font(BrandFont.mono(9))
                            .tracking(1.6)
                            .foregroundStyle(BrandColor.textMuted)
                        Text(profile.acceptedPayments.joined(separator: " · "))
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func locationLine(_ location: String) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 11))
                .foregroundStyle(BrandColor.accent)
            Text(location)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }

        // MapsLink returns nil when there is nothing to locate; the line stays
        // plain text then, rather than a link that goes nowhere.
        if let url = MapsLink.url(address: location) {
            Link(destination: url) { label.underline() }
                .accessibilityLabel("\(location) — open in maps")
        } else {
            label
        }
    }

    /// "@dana · 4,208 followers" — but the count only joins the line once there
    /// IS one. "@dana · 0 followers" states an absence nobody asked about.
    private func handleAndFollowers(_ header: ProProfileHeader) -> String {
        let count = follow.followerCount
        let handle = header.displayHandle.flatMap { $0.isEmpty ? nil : $0 }
        let followers = count > 0
            ? (count == 1 ? "1 follower" : "\(count) followers")
            : nil
        return [handle, followers].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func avatarCircle(_ avatarUrl: String?, name: String) -> some View {
        Group {
            if let raw = avatarUrl, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        avatarFallback(name)
                    }
                }
            } else {
                avatarFallback(name)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(Circle())
        .overlay(Circle().stroke(BrandColor.bgPrimary, lineWidth: 3))
        .offset(y: -34)
        .padding(.bottom, -34)
    }

    private func avatarFallback(_ name: String) -> some View {
        ZStack {
            BrandColor.bgSecondary
            Text(String(name.prefix(1)).uppercased())
                .font(BrandFont.display(30, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
        }
    }

    /// The licence / pending chips, plus the availability + "New to {brand}"
    /// chips — the latter two ONLY on a brand-new pro. On an established pro
    /// `signals.chips` is empty, which is the design and not a failed read.
    @ViewBuilder
    private func chipRow(_ profile: ProProfile) -> some View {
        let chips = profile.signals.chips
        if profile.header.isLicenseVerified || !chips.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if profile.header.isLicenseVerified {
                    licenseBadge
                }
                ForEach(chips) { chip in
                    signalChip(chip.label)
                }
            }
            .padding(.top, 12)
        }
    }

    private func signalChip(_ label: String) -> some View {
        Text(label)
            .font(BrandFont.mono(10))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(BrandColor.accent)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(BrandColor.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(BrandColor.accent.opacity(0.4), lineWidth: 1))
    }

    /// Message / Save / Share — the loud actions on this page are the SOCIAL
    /// ones. Booking is deliberately absent here.
    private var socialActionRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await openMessageThread() }
            } label: {
                socialActionLabel(system: "bubble.left", text: "Message", busy: messageWorking)
            }
            .buttonStyle(.plain)
            .disabled(messageWorking)

            Button {
                Task { await toggleFavorite() }
            } label: {
                socialActionLabel(
                    system: isFavorited ? "heart.fill" : "heart",
                    text: isFavorited ? "Saved" : "Save",
                    tint: isFavorited ? BrandColor.ember : nil
                )
            }
            .buttonStyle(.plain)
            .disabled(favoriteWorking)

            if let url = shareURL {
                ShareLink(item: url) {
                    socialActionLabel(system: "square.and.arrow.up", text: "Share")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func socialActionLabel(
        system: String,
        text: String,
        busy: Bool = false,
        tint: Color? = nil
    ) -> some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().tint(BrandColor.textPrimary).scaleEffect(0.7)
            } else {
                Image(systemName: system)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint ?? BrandColor.textPrimary)
            }
            Text(text)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(
            BrandColor.bgSurface.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1)
        )
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
            // Accent, not iris: the licence chip now sits in a ROW with the
            // availability / "New to {brand}" chips, and two different hues for
            // the same kind of small factual badge reads as two categories.
            .foregroundStyle(BrandColor.accent)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(BrandColor.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(BrandColor.accent.opacity(0.4), lineWidth: 1))
    }

    /// Follow pill — the same /pros/{id}/follow endpoint as the feed's FOLLOW
    /// pill. The follower COUNT moved onto the handle line beside the name, so
    /// the pill itself is just the action.
    private var followPill: some View {
        let isFollowing = follow.following
        return Button {
            Task { await toggleFollow() }
        } label: {
            Text(isFollowing ? "Following" : "Follow")
                .font(BrandFont.display(13, .bold))
                .foregroundStyle(isFollowing ? BrandColor.textPrimary : BrandColor.onAccent)
                .padding(.vertical, 9).padding(.horizontal, 18)
                .background(
                    isFollowing ? AnyShapeStyle(Color.clear) : AnyShapeStyle(BrandColor.textPrimary),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(follow.isWorking)
        .accessibilityLabel(isFollowing ? "Unfollow" : "Follow")
    }

    // MARK: - Book bar

    /// The slim bar between the end of the scroll and the footer. It does NOT
    /// float and does NOT follow the scroll — reached after the work rather than
    /// hovering over it, which is the whole point of putting booking here.
    ///
    /// 🔴 The CTA composes as "Book · From $85". `priceFromLabel` is a bare
    /// "$85" on purpose: the word "From" is added at the render sites, never in
    /// the money formatter, which also feeds this label and would then read
    /// "From From $85".
    private func bookBar(_ profile: ProProfile) -> some View {
        let price = profile.stats.priceFromLabel
        // 🔴 The CHEAPEST offering, not the first one. `stats.priceFromLabel` is
        // the lowest price across every offering, so pairing it with whichever
        // offering happens to come first names the wrong service at that price
        // ("Balayage from $180" when Balayage is $250). Web picks by
        // `priceFromNumber`; this must agree with it.
        let cheapest = profile.offerings
            .compactMap { offering -> (ProOffering, Double)? in
                guard let value = offering.priceFromNumber else { return nil }
                return (offering, value)
            }
            .min { $0.1 < $1.1 }?
            .0
        let servicesWord = profile.offerings.count == 1 ? "service" : "services"
        let subline: String = {
            guard let name = cheapest?.name, let price else {
                return "See services and availability"
            }
            guard !profile.offerings.isEmpty else { return "\(name) from \(price)" }
            return "\(name) from \(price) · \(profile.offerings.count) \(servicesWord)"
        }()

        return VStack(spacing: 0) {
            hairline
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.signals.availabilityLine ?? "Book with this pro")
                        .font(BrandFont.mono(9))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(BrandColor.textMuted)
                    Text(subline)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .services }
                } label: {
                    Text(price.map { "Book · From \($0)" } ?? "Book")
                        .font(BrandFont.display(14, .bold))
                        .foregroundStyle(BrandColor.onAccent)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 20)
                        .background(BrandColor.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(BrandColor.bgSecondary)
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
            portfolioTab(profile)
        case .services:
            servicesTab(profile)
        case .reviews:
            reviewsTab(profile)
        }
    }

    // MARK: - Portfolio

    @ViewBuilder
    private func portfolioTab(_ profile: ProProfile) -> some View {
        let tiles = profile.portfolioTiles

        VStack(spacing: 14) {
            // The pro's own chosen highlight leads. The server has already taken
            // it OUT of `portfolioTiles`, so it never renders twice.
            if let signature = profile.signature {
                signatureCard(signature, proName: profile.header.displayName)
            }

            if tiles.isEmpty {
                if profile.signature == nil {
                    emptyCard("No portfolio posts yet.")
                }
            } else {
                LazyVGrid(
                    columns: MediaGridLayout.columns(count: 3, spacing: 2),
                    spacing: 2
                ) {
                    ForEach(tiles) { tile in
                        portfolioTile(tile)
                    }
                }
            }
        }
    }

    // MARK: - Signature

    /// 🔴 The label is "Signature", never "Spotlight" (that is
    /// `LookPost.featuredAt`, a SUPER_ADMIN editorial pick) and never "Featured"
    /// (four other meanings). The design mock says "Spotlight service" here;
    /// this is the one place the build deliberately departs from it.
    @ViewBuilder
    private func signatureCard(_ signature: ProProfileSignature, proName: String) -> some View {
        let tile = signature.tile

        // Hand-rolled rather than `BrandSurface`, which hardcodes 14pt of
        // padding — the media has to reach the card's edges.
        VStack(alignment: .leading, spacing: 0) {
                signatureMedia(tile)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").font(.system(size: 9))
                            Text("SIGNATURE")
                                .font(BrandFont.mono(9))
                                .tracking(1.8)
                        }
                        .foregroundStyle(BrandColor.gold)

                        Spacer(minLength: 8)

                        if let priceLine = signature.priceLine {
                            Text(priceLine)
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }

                    if let caption = tile.caption, !caption.isEmpty {
                        Text(caption)
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !tile.serviceNames.isEmpty {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(tile.serviceNames, id: \.self) { name in
                                Text(name)
                                    .font(BrandFont.mono(10))
                                    .foregroundStyle(BrandColor.accent)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 10)
                                    .overlay(
                                        Capsule().stroke(BrandColor.accent.opacity(0.35), lineWidth: 1)
                                    )
                            }
                        }
                    }

                    HStack(spacing: 14) {
                        signatureCount(system: "heart.fill", value: tile.engagement.likeCount, tint: BrandColor.ember)
                        signatureCount(system: "bubble.left.fill", value: tile.engagement.commentCount, tint: BrandColor.textMuted)

                        Spacer(minLength: 8)

                        if let lookId = signature.bookLookId {
                            NavigationLink {
                                LookDetailView(lookId: lookId, autoStartBooking: true)
                            } label: {
                                Text("Book this look")
                                    .font(BrandFont.display(13, .semibold))
                                    .foregroundStyle(BrandColor.accent)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 15)
                                    .overlay(Capsule().stroke(BrandColor.accent, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Zero renders NOTHING — never "0 recreated this".
                    if tile.engagement.recreatedCount > 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            hairline
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11, weight: .bold))
                                Text("\(tile.engagement.recreatedCount) RECREATED THIS")
                                    .font(BrandFont.mono(10))
                                    .tracking(1.4)
                            }
                            .foregroundStyle(BrandColor.gold)
                        }
                    }
                }
                .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(proName) signature work")
    }

    /// Landscape, unlike the portrait grid tiles — the promoted post is the one
    /// picture on the page that gets room to breathe.
    private var signatureAspect: CGFloat { 4.0 / 3.0 }

    /// Sized through `MediaGridCell` rather than a bare `.frame(height:)`:
    /// `MediaGridImage` fill-crops with `scaledToFill`, whose LAYOUT width
    /// inflates to the source's, and the cell is what keeps that overflow from
    /// reaching the card's own geometry.
    @ViewBuilder
    private func signatureMedia(_ tile: ProPortfolioTile) -> some View {
        if let before = tile.before,
           let beforeStr = before.displayUrl,
           let beforeURL = URL(string: beforeStr),
           let afterURL = URL(string: tile.displayUrl) {
            MediaGridCompareCell(
                beforeURL: beforeURL,
                afterURL: afterURL,
                aspectRatio: signatureAspect,
                cornerRadius: 0,
                // 🔴 STATIC. The block is the tallest thing on this scroll, and
                // an interactive wipe owns every drag that starts on it — so an
                // ordinary upward swipe on the biggest element on the page did
                // nothing at all. The split still reads (BEFORE | AFTER); the
                // draggable comparison lives on the look detail, which "Book
                // this look" and a tap both reach.
                interactive: false
            )
        } else {
            MediaGridCell(aspectRatio: signatureAspect, cornerRadius: 0) {
                MediaGridImage(url: URL(string: tile.displayUrl), showsSpinner: false)
            }
        }
    }

    private func signatureCount(system: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system).font(.system(size: 11)).foregroundStyle(tint)
            Text("\(value)")
                .font(BrandFont.mono(11))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    /// 🔴 Every grid tile is STATIC, paired or not — a paired one wears the
    /// "B / A" flag and opens the look, where the comparison slider lives.
    ///
    /// It used to render the interactive slider inline, which cost three things
    /// at once: the BEFORE and AFTER labels collided in a 130pt cell
    /// ("BEFORAFTER"), the slider swallowed vertical drags so a whole grid row
    /// could not be scrolled past, and — because the slider owns the gesture —
    /// a paired tile was the one tile in the grid you could not TAP to open.
    /// Web's grid made the same change; the frame's grid is flat tiles.
    private func portfolioTile(_ tile: ProPortfolioTile) -> some View {
        standardPortfolioTile(tile)
    }

    // §19f — a portfolio tile IS a look, so tapping it opens the look post
    // (caption, service, tags, engagement), exactly as web's `PortfolioGrid`
    // links to `/looks/[lookId]`. The bare fullscreen viewer stays as the
    // fallback for a legacy tile with no backing look, mirroring web's own
    // fallback to `/media/[id]`.
    @ViewBuilder
    private func standardPortfolioTile(_ tile: ProPortfolioTile) -> some View {
        if let lookId = tile.lookId {
            NavigationLink {
                LookDetailView(lookId: lookId)
            } label: {
                portfolioTileFace(tile)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                fullscreenMedia = FullscreenMedia.clientExportable(
                    id: tile.id,
                    urlString: tile.src,
                    isVideo: tile.isVideo,
                    professionalId: professionalId,
                    overlay: MediaCaptionOverlay.make(
                        caption: tile.caption,
                        serviceNames: tile.serviceNames
                    )
                )
            } label: {
                portfolioTileFace(tile)
            }
            .buttonStyle(.plain)
        }
    }

    private func portfolioTileFace(_ tile: ProPortfolioTile) -> some View {
        // `showsSpinner: false` keeps this grid — the one that was already
        // rendering correctly — pixel-identical to before the tile was shared.
        PortfolioTileFace(tile: tile, cornerRadius: 0, chrome: .chips, showsSpinner: false)
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
                            bookLaunch = BookLaunch(
                                proName: profile.header.displayName,
                                offering: offering
                            )
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
                            fullscreenMedia = FullscreenMedia.clientExportable(
                                id: media.id, urlString: media.url, isVideo: media.isVideo,
                                professionalId: professionalId
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
