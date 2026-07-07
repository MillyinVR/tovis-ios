// Looks — the client's social home base (center feather tab), built to match the
// web LooksFeed 1:1: a full-bleed, vertically-paged feed with the "Looks" serif
// header + Spotlight/Following/category tabs, bottom-left overlays (creator +
// FOLLOW pill, italic caption, service pill), and the right action rail
// (creator avatar, teal BOOK, like, comment, save, share).
//
// Reads use existing endpoints; like/follow/save write through and reconcile
// with the server (optimistic, like the web). Live-sync refetches on refreshTick.
import SwiftUI
import TovisKit

struct LooksView: View {
    @Environment(SessionModel.self) private var session

    // The tab strip mirrors the web: Looks (all) · Spotlight · Following · [categories].
    private enum LooksTab: Hashable {
        case all, spotlight, following
        case category(LooksCategory)

        var title: String {
            switch self {
            case .all: return "Looks"
            case .spotlight: return "Spotlight"
            case .following: return "Following"
            case let .category(c): return c.name
            }
        }
        var isAll: Bool { if case .all = self { return true }; return false }
    }

    private enum Phase {
        case loading
        case loaded([LooksFeedItem])
        case empty
        case failed(String)
    }

    @State private var tab: LooksTab = .all
    @State private var categories: [LooksCategory] = []
    @State private var phase: Phase = .loading
    @State private var nextCursor: String?
    @State private var loadingMore = false

    // Optimistic overrides (the wire models are immutable outside TovisKit).
    @State private var likeOverrides: [String: Bool] = [:]      // by look id
    @State private var likeCounts: [String: Int] = [:]          // by look id
    @State private var commentCounts: [String: Int] = [:]       // by look id
    @State private var followOverrides: [String: Bool] = [:]    // by professional id
    @State private var savedOverrides: [String: Bool] = [:]      // by look id

    @State private var commentsFor: LooksFeedItem?
    @State private var saveFor: LooksFeedItem?
    /// A tapped tag chip → opens its web tag page (/looks/tags/{slug}) in Safari.
    @State private var tagWebFor: TagWebLink?

    /// Programmatic navigation to a pro profile (avatar tap + the BOOK fallback
    /// when a look has no bookable service to preselect).
    @State private var navPath: [LooksProfessional] = []
    /// Drives the booking sheet with a preselected offering (web BOOK parity).
    @State private var bookLaunch: BookLaunch?
    /// The look id whose BOOK button is mid-resolve (shows a spinner).
    @State private var resolvingBookId: String?

    /// The currently-snapped slide (drives which video plays). Bound to the
    /// pager's scroll position. Mute is shared so an unmute sticks while scrolling.
    @State private var activeId: String?
    @State private var muted = true

    /// Session dedupe for view impressions (B2) — each look pings at most once
    /// so a scroll-up/scroll-down doesn't double-count. Web parity: web batches
    /// the flush; iOS pings per newly-seen slide (each look still once/session).
    @State private var viewedLookIds: Set<String> = []

    private var commentsOpen: Bool { commentsFor != nil }
    // Roughly the visible fraction above the 0.7-height comments sheet — scales
    // the look to fit in that top gap. Tune alongside the sheet's .fraction(0.7).
    private static let mediaShrinkScale: CGFloat = 0.37

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack(alignment: .top) {
                BrandColor.bgPrimary.ignoresSafeArea()

                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent).frame(maxHeight: .infinity)
                case let .failed(message):
                    failure(message)
                case .empty:
                    emptyState
                case let .loaded(items):
                    // When the comments sheet is open, shrink the media up into
                    // the space above it (TikTok-style) so the whole look stays
                    // visible above the sheet.
                    feed(items)
                        .scaleEffect(commentsOpen ? Self.mediaShrinkScale : 1, anchor: .top)
                        .animation(.easeInOut(duration: 0.25), value: commentsOpen)
                }

                header
                    .opacity(commentsOpen ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: commentsOpen)
            }
            .navigationDestination(for: LooksProfessional.self) { pro in
                ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(BrandColor.accent)
        .task {
            if categories.isEmpty { categories = (try? await session.client.looks.categories()) ?? [] }
            if case .loading = phase { await load() }
        }
        .onChange(of: tab) { Task { await load() } }
        .onChange(of: session.refreshTick) { Task { await reloadKeepingPlace() } }
        .sheet(item: $commentsFor) { item in
            // TikTok-style: opens as a partial-height sheet (presentation detents
            // are managed inside the view so it can expand when the input is tapped).
            LookCommentsView(look: item) { delta in
                commentCounts[item.id] = commentCount(item) + delta
            }
        }
        .sheet(item: $saveFor) { item in
            SaveToBoardSheet(lookId: item.id) { state in
                savedOverrides[item.id] = state.isSaved
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $bookLaunch) { launch in
            BookingFlowView(
                professionalId: launch.pro.id,
                proName: launch.pro.displayName,
                offering: launch.offering
            )
        }
        .sheet(item: $tagWebFor) { link in
            SafariView(url: link.url)
        }
    }

    /// The web tag page for a chip tap. Mirrors `shareURL`'s origin convention.
    private func tagURL(_ tag: LooksTag) -> URL? {
        guard let slug = tag.slug.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return nil }
        return URL(string: "https://www.tovis.app/looks/tags/\(slug)")
    }

    // MARK: - Header (Looks serif title + tab strip)

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                tabButton(.all)
                tabButton(.spotlight)
                tabButton(.following)
                ForEach(categories) { tabButton(.category($0)) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tabButton(_ t: LooksTab) -> some View {
        let active = t == tab
        Button { tab = t } label: {
            VStack(spacing: 4) {
                if t.isAll {
                    Text(t.title)
                        .font(BrandFont.display(21, .semibold))
                        .italic()
                } else {
                    Text(t.title.uppercased())
                        .font(BrandFont.mono(11))
                        .tracking(1.6)
                }
                Capsule()
                    .fill(active ? Color.white : .clear)
                    .frame(height: 2)
            }
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.6))
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feed

    private func feed(_ items: [LooksFeedItem]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    LookSlide(
                        item: item,
                        isActive: activeId == item.id,
                        muted: muted,
                        liked: liked(item),
                        likeCount: likeCount(item),
                        commentCount: commentCount(item),
                        following: following(item),
                        saved: saved(item),
                        shareURL: shareURL(item),
                        bookResolving: resolvingBookId == item.id,
                        onLike: { Task { await toggleLike(item) } },
                        onComment: { commentsFor = item },
                        onSave: { saveFor = item },
                        onFollow: { Task { await toggleFollow(item) } },
                        onShared: { Task { await recordShare(item) } },
                        onBook: { Task { await startBooking(item) } },
                        onToggleMute: { muted.toggle() },
                        onOpenTag: { tag in
                            if let url = tagURL(tag) { tagWebFor = TagWebLink(url: url) }
                        }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .onAppear { Task { await loadMoreIfNeeded(at: index, total: items.count) } }
                }

                if loadingMore {
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $activeId, anchor: .center)
        .scrollTargetBehavior(.paging)
        // Record a sampled view impression for whichever slide snaps active (B2).
        .onChange(of: activeId) { _, id in Task { await recordView(id) } }
        // Start the first slide playing before any scroll happens.
        .onAppear { if activeId == nil { activeId = items.first?.id } }
        .onChange(of: items.first?.id) { _, first in if activeId == nil { activeId = first } }
        // Full-bleed up top, but RESPECT the bottom inset so the slide sits
        // above the footer bar (was hidden behind it). The footer — including
        // the center circle that pokes above it — is an overlay on top, so the
        // circle still floats in front of the feed.
        .ignoresSafeArea(edges: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: tab == .following ? "person.2" : "sparkles")
                .font(.system(size: 30)).foregroundStyle(BrandColor.accent)
            Text(tab == .following ? "No looks from pros you follow yet" : "No looks here yet")
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text(tab == .following ? "Follow pros to see their latest work." : "Check back soon.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        }
        .padding(40).frame(maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.accent)
        }
        .padding(40).frame(maxHeight: .infinity)
    }

    // MARK: - Data

    private func params() -> (filter: String?, category: String?, following: Bool) {
        switch tab {
        case .all: return (nil, nil, false)
        case .spotlight: return ("spotlight", nil, false)
        case .following: return (nil, nil, true)
        case let .category(c): return (nil, c.slug, false)
        }
    }

    private func load() async {
        phase = .loading
        likeOverrides = [:]; likeCounts = [:]; commentCounts = [:]; followOverrides = [:]
        savedOverrides = [:]
        let p = params()
        do {
            let page = try await session.client.looks.feed(
                filter: p.filter, category: p.category, following: p.following
            )
            nextCursor = page.nextCursor
            phase = page.items.isEmpty ? .empty : .loaded(page.items)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load looks.")
        }
    }

    private func reloadKeepingPlace() async {
        guard case .loaded = phase else { await load(); return }
        let p = params()
        do {
            let page = try await session.client.looks.feed(
                filter: p.filter, category: p.category, following: p.following
            )
            nextCursor = page.nextCursor
            if !page.items.isEmpty { phase = .loaded(page.items) }
        } catch { /* keep what's on screen */ }
    }

    private func loadMoreIfNeeded(at index: Int, total: Int) async {
        guard !loadingMore, let cursor = nextCursor, index >= total - 3 else { return }
        guard case let .loaded(current) = phase else { return }
        loadingMore = true
        defer { loadingMore = false }
        let p = params()
        do {
            let page = try await session.client.looks.feed(
                filter: p.filter, category: p.category, following: p.following, cursor: cursor
            )
            nextCursor = page.nextCursor
            phase = .loaded(current + page.items)
        } catch { /* leave the cursor; a later slide retries */ }
    }

    // MARK: - Optimistic state

    private func liked(_ i: LooksFeedItem) -> Bool { likeOverrides[i.id] ?? i.viewerLiked }
    private func likeCount(_ i: LooksFeedItem) -> Int { likeCounts[i.id] ?? i.count.likes }
    private func commentCount(_ i: LooksFeedItem) -> Int { commentCounts[i.id] ?? i.count.comments }
    private func following(_ i: LooksFeedItem) -> Bool {
        guard let proId = i.professional?.id else { return false }
        return followOverrides[proId] ?? i.viewerFollows
    }
    private func saved(_ i: LooksFeedItem) -> Bool { savedOverrides[i.id] ?? i.viewerSaved }

    /// Fire-and-forget share ping (S1.4): count the share server-side; never
    /// surface an error over it.
    private func recordShare(_ item: LooksFeedItem) async {
        _ = try? await session.client.looks.recordShare(lookId: item.id)
    }

    /// Fire-and-forget view impression (B2): count each look at most once per
    /// session; never surface an error over it.
    private func recordView(_ id: String?) async {
        guard let id, !id.isEmpty, !viewedLookIds.contains(id) else { return }
        viewedLookIds.insert(id)
        try? await session.client.looks.recordViews(lookIds: [id])
    }
    private func shareURL(_ i: LooksFeedItem) -> URL? {
        URL(string: "https://www.tovis.app/looks/\(i.id)")
    }

    /// 1-tap Book — web parity on THE conversion. On web the feed BOOK button
    /// opens the availability drawer preloaded with the look's service
    /// (buildAvailabilityDrawerContext). Here we fetch the pro's profile, find the
    /// offering whose serviceId matches this look, and present BookingFlowView with
    /// it preselected. If the look carries no service, the fetch fails, or the
    /// service is no longer offered, fall back to the pro profile so the client can
    /// still pick a service.
    private func startBooking(_ item: LooksFeedItem) async {
        guard let pro = item.professional else { return }
        guard resolvingBookId == nil else { return } // ignore double-taps
        resolvingBookId = item.id
        defer { resolvingBookId = nil }

        func fallbackToProfile() {
            if navPath.last != pro { navPath.append(pro) }
        }

        guard let serviceId = item.serviceId else { fallbackToProfile(); return }
        do {
            let profile = try await session.client.profiles.professional(id: pro.id)
            guard let offering = profile.offerings.first(where: { $0.serviceId == serviceId }) else {
                fallbackToProfile()
                return
            }
            bookLaunch = BookLaunch(pro: pro, offering: offering)
        } catch {
            fallbackToProfile()
        }
    }

    private func toggleLike(_ item: LooksFeedItem) async {
        let next = !liked(item)
        let base = likeCount(item)
        likeOverrides[item.id] = next
        likeCounts[item.id] = max(0, base + (next ? 1 : -1))
        do {
            let res = try await session.client.looks.setLiked(lookId: item.id, liked: next)
            likeOverrides[item.id] = res.liked
            likeCounts[item.id] = res.likeCount
        } catch {
            likeOverrides[item.id] = !next
            likeCounts[item.id] = base
        }
    }

    private func toggleFollow(_ item: LooksFeedItem) async {
        guard let pro = item.professional else { return }
        let next = !following(item)
        followOverrides[pro.id] = next
        do {
            let res = try await session.client.looks.setFollow(professionalId: pro.id, following: next)
            followOverrides[pro.id] = res.following
        } catch {
            followOverrides[pro.id] = !next
        }
    }
}

// MARK: - Booking launch (BOOK button → availability sheet)

/// Carries the resolved offering for the booking sheet. Identified by the look's
/// professional so `.sheet(item:)` re-presents cleanly per tap.
private struct BookLaunch: Identifiable {
    let pro: LooksProfessional
    let offering: ProOffering
    var id: String { pro.id }
}

/// A tapped tag chip's web destination, wrapped so `.sheet(item:)` can present it.
private struct TagWebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - One full-screen slide

private struct LookSlide: View {
    let item: LooksFeedItem
    /// True only for the slide currently snapped in the pager — gates playback.
    let isActive: Bool
    let muted: Bool
    let liked: Bool
    let likeCount: Int
    let commentCount: Int
    let following: Bool
    let saved: Bool
    let shareURL: URL?
    /// True while the pro profile is being fetched to preselect the look's
    /// service — the BOOK button shows a spinner instead of the calendar icon.
    let bookResolving: Bool
    let onLike: () -> Void
    let onComment: () -> Void
    let onSave: () -> Void
    let onFollow: () -> Void
    let onShared: () -> Void
    let onBook: () -> Void
    let onToggleMute: () -> Void
    /// A tag chip tap → open its web tag page (social-first D1).
    let onOpenTag: (LooksTag) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            media

            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                overlays
                Spacer(minLength: 8)
                rail
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }

    /// Video slides get a chromeless looping player (poster underneath until the
    /// first frame, tap toggles mute); image slides keep the AsyncImage.
    @ViewBuilder
    private var media: some View {
        if let pair = item.beforeAfterPair {
            // Before/after pairing → the reveal slider is the money-shot. It only
            // claims horizontal drags (passVerticalScroll) so the feed's vertical
            // pager keeps scrolling under a swipe.
            BeforeAfterCompareView(
                beforeURL: pair.before,
                afterURL: pair.after,
                cornerRadius: 0,
                fillContainer: true,
                passVerticalScroll: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else if item.isVideo, let url = URL(string: item.url) {
            ZStack {
                posterImage // shows instantly; the video layer covers it when ready
                LookVideoView(url: url, isActive: isActive, isMuted: muted)
                    .allowsHitTesting(false)
                muteBadge
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onToggleMute() }
        } else if let url = URL(string: item.url) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFill()
                case .failure: fallback
                default: ProgressView().tint(BrandColor.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            fallback
        }
    }

    private var posterImage: some View {
        Group {
            if let thumb = item.thumbUrl, let url = URL(string: thumb) {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.black
                    }
                }
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var muteBadge: some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(.top, 64)
                    .padding(.trailing, 16)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var fallback: some View {
        ZStack {
            BrandColor.bgSecondary
            Image(systemName: "photo").font(.system(size: 34)).foregroundStyle(BrandColor.textMuted)
        }
    }

    // MARK: Overlays (bottom-left): name + FOLLOW, italic caption, service pill

    private var overlays: some View {
        VStack(alignment: .leading, spacing: 8) {
            creatorRow

            if let caption = item.caption, !caption.isEmpty {
                Text("“\(caption)”")
                    .font(BrandFont.display(17).italic())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 5, y: 1)
            }

            HStack(spacing: 6) {
                if let service = item.serviceName ?? item.category {
                    Text(service.uppercased())
                        .font(BrandFont.mono(11))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.vertical, 5).padding(.horizontal, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                // "FROM $X" — the attainable half of the daydream (web parity).
                if let price = item.priceLabel {
                    Text("FROM \(price)")
                        .font(BrandFont.mono(11))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.vertical, 5).padding(.horizontal, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(BrandColor.accent.opacity(0.5), lineWidth: 1))
                }
            }

            // Tappable hashtag/style tags (social-first D1) → the web tag page.
            // Capped so the overlay stays legible; the full set lives on the web.
            if !item.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.tags.prefix(3)) { tag in
                        Button { onOpenTag(tag) } label: {
                            Text("#\(tag.display)")
                                .font(BrandFont.mono(11))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.vertical, 5).padding(.horizontal, 11)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(BrandColor.accent.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
    }

    @ViewBuilder
    private var creatorRow: some View {
        HStack(spacing: 8) {
            if let pro = item.professional {
                NavigationLink(value: pro) {
                    Text(pro.displayName).font(BrandFont.body(15, .semibold)).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                followPill
                if pro.followerCount > 0 {
                    Text(followerLabel(pro.followerCount))
                        .font(BrandFont.mono(11)).foregroundStyle(.white.opacity(0.7))
                }
            } else if let author = item.clientAuthor {
                Text(author.handleLabel).font(BrandFont.body(15, .semibold)).foregroundStyle(.white)
            }
        }
    }

    private var followPill: some View {
        Button(action: onFollow) {
            Text(following ? "FOLLOWING" : "FOLLOW")
                .font(BrandFont.mono(10))
                .tracking(1)
                .foregroundStyle(following ? .white.opacity(0.7) : .white)
                .padding(.vertical, 3).padding(.horizontal, 9)
                .background(following ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Right action rail

    private var rail: some View {
        VStack(spacing: 18) {
            if let pro = item.professional {
                NavigationLink(value: pro) { avatarPlus(name: pro.displayName, url: pro.avatarUrl) }
                    .buttonStyle(.plain)
                bookButton(pro: pro)
            } else if let author = item.clientAuthor {
                avatarPlus(name: author.handleLabel, url: author.avatarUrl)
            }

            railButton(icon: liked ? "heart.fill" : "heart", tint: liked ? BrandColor.ember : .white,
                       count: likeCount, action: onLike)
            railButton(icon: "bubble.right", tint: .white, count: commentCount, action: onComment)
            railButton(icon: saved ? "bookmark.fill" : "bookmark",
                       tint: saved ? BrandColor.iris : .white, count: nil, action: onSave)

            if let shareURL {
                // Counts share-sheet opens (ShareLink has no completion hook) —
                // same "idempotent-enough" bar as the web ping.
                ShareLink(item: shareURL) {
                    railIcon("square.and.arrow.up", tint: .white)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { onShared() })
            }
        }
    }

    private func avatarPlus(name: String, url: String?) -> some View {
        BrandAvatar(name: name, avatarUrl: url, size: 48)
            .overlay(alignment: .bottom) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(width: 20, height: 20)
                    .background(BrandColor.accent, in: Circle())
                    .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
                    .offset(y: 8)
            }
            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
    }

    // 1-tap Book — web parity: opens the availability sheet directly with this
    // look's service preselected (mirrors buildAvailabilityDrawerContext on web),
    // rather than just navigating to the profile. The async fetch to resolve the
    // offering lives in the parent; here we just fire onBook and show a spinner.
    private func bookButton(pro: LooksProfessional) -> some View {
        Button(action: onBook) {
            VStack(spacing: 5) {
                Group {
                    if bookResolving {
                        ProgressView().tint(BrandColor.onAccent)
                    } else {
                        Image(systemName: "calendar")
                            .font(.system(size: 24, weight: .regular))
                    }
                }
                .foregroundStyle(BrandColor.onAccent)
                .frame(width: 52, height: 52)
                .background(BrandColor.accent, in: Circle())
                .shadow(color: BrandColor.accent.opacity(0.55), radius: 10, y: 3)
                Text("BOOK").font(BrandFont.mono(11)).tracking(0.6).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(bookResolving)
    }

    private func railButton(icon: String, tint: Color, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                railIcon(icon, tint: tint)
                if let count, count > 0 {
                    Text(countLabel(count)).font(BrandFont.body(11, .semibold)).foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func railIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 27, weight: .regular))
            .foregroundStyle(tint)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }

    private func countLabel(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)
        }
        return "\(n)"
    }

    private func followerLabel(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000
            return (k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)) + " followers"
        }
        return n == 1 ? "1 follower" : "\(n) followers"
    }
}
