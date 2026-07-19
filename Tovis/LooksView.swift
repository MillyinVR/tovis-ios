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

    /// Feed search (web `LooksTopBar`): collapsed behind a magnifier until tapped.
    @State private var searchOpen = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    /// The pending debounced search; a new keystroke cancels it.
    @State private var searchDebounce: Task<Void, Never>?

    // Optimistic overrides (the wire models are immutable outside TovisKit).
    @State private var likeOverrides: [String: Bool] = [:]      // by look id
    @State private var likeCounts: [String: Int] = [:]          // by look id
    @State private var commentCounts: [String: Int] = [:]       // by look id
    @State private var followByPro: [String: FollowToggle] = [:]    // by professional id
    @State private var savedOverrides: [String: Bool] = [:]      // by look id

    @State private var commentsFor: LooksFeedItem?
    @State private var saveFor: LooksFeedItem?
    /// A tapped tag chip → the native tag feed (LookTagFeedView).
    @State private var tagFeedFor: LooksTag?

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

    /// Re-entrancy guard for "Not for me" — a second tap on a slide already
    /// mid-hide is a no-op (web keeps the same guard in a ref).
    @State private var hideInFlight: Set<String> = []
    /// The look a long press is proposing to hide, pending confirmation.
    @State private var hideCandidate: LooksFeedItem?

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
            .navigationDestination(for: LooksClientAuthor.self) { author in
                PublicClientViewerView(handle: author.handle)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(BrandColor.accent)
        .task {
            if categories.isEmpty { categories = (try? await session.client.looks.categories()) ?? [] }
            if case .loading = phase { await load() }
        }
        .onChange(of: tab) { Task { await load() } }
        // Search-as-you-type, debounced. Web re-queries on EVERY keystroke and
        // just aborts the in-flight fetch — acceptable in a tab, wasteful on
        // cellular, and each `q` request costs a real query (a present `q` routes
        // the server off the personalized feed onto the search path). Coalesce
        // instead: a new keystroke cancels the pending task, so only the pause
        // fires. `onChange` doesn't run on appear, so this can't race first load.
        .onChange(of: searchQuery) {
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await load(showSpinner: false)
            }
        }
        .onChange(of: session.refreshTick) { Task { await reloadKeepingPlace() } }
        .sheet(item: $commentsFor) { item in
            // TikTok-style: opens as a partial-height sheet (presentation detents
            // are managed inside the view so it can expand when the input is tapped).
            LookCommentsView(lookId: item.id, commentsCount: commentCount(item)) { delta in
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
        // Wrapped in its own stack + Done button, like the deep-link look sheets
        // in MainTabView — the tag screen pushes look details inside it.
        .sheet(item: $tagFeedFor) { tag in
            NavigationStack {
                LookTagFeedView(slug: tag.slug, display: tag.display)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { tagFeedFor = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        // The long press is invisible, so confirm before acting — and the action
        // is worth confirming on its own terms: neither platform has an un-hide,
        // so this is the one feed control a mis-tap can't take back.
        .confirmationDialog(
            "Stop seeing this look?",
            isPresented: Binding(
                get: { hideCandidate != nil },
                set: { if !$0 { hideCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: hideCandidate
        ) { item in
            Button("Not for me", role: .destructive) {
                Task { await hideLook(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // Honest about both halves of what the server does: the look is gone
            // for good, and its category is down-ranked (decaying, not forever).
            Text("You won’t see this look again, and we’ll show you fewer like it.")
        }
    }

    // MARK: - Header (Looks serif title + tab strip)

    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        tabButton(.all)
                        tabButton(.spotlight)
                        tabButton(.following)
                        ForEach(categories) { tabButton(.category($0)) }
                    }
                    .padding(.horizontal, 16)
                    // Room for the tab underline + its shadow, which the clip
                    // below would otherwise cut off.
                    .padding(.bottom, 4)
                }
                // The strip MUST clip: the tabs scroll horizontally, and without
                // this they render straight through the magnifier (the original
                // .scrollClipDisabled() was safe only while the row was the full
                // width and had nothing beside it).
                .clipped()

                searchToggle
                    .padding(.trailing, 16)
            }
            .padding(.top, 6)

            if searchOpen { searchField.padding(.horizontal, 16) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Magnifier that opens the field (web collapses its search the same way).
    /// Closing also clears the query, which re-runs the unfiltered feed.
    private var searchToggle: some View {
        Button {
            searchOpen.toggle()
            if searchOpen {
                searchFocused = true
            } else if !searchQuery.isEmpty {
                searchQuery = ""
            }
        } label: {
            Image(systemName: searchOpen ? "xmark" : "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchOpen ? "Close search" : "Open search")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            // Web's placeholder says "Search pros or services", but the server
            // matches captions + pro + service names and always returns LOOKS.
            // Name what comes back instead of repeating the copy's promise.
            TextField("", text: $searchQuery, prompt: searchPrompt)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .foregroundStyle(.white)
                .font(BrandFont.body(15))

            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
    }

    private var searchPrompt: Text {
        Text("Search looks, pros, or services")
            .foregroundColor(.white.opacity(0.55))
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
        // Full-bleed pager: each slide is the FULL screen, so it exactly equals the
        // scroll viewport and `.paging` snaps every slide flush — no sliver of the
        // previous slide peeking at the top. The predecessor sized slides to the safe
        // (footer-excluded) height, which was shorter than the viewport the scroll
        // view actually pages by, so the seam drifted. Slides now bleed under the
        // status bar and behind the footer; each one lifts its own chrome above the
        // footer with the footer inset. (The chrome was ALSO missing for a second,
        // horizontal reason — see the `.scaledToFill()` fix in FocalCoverImage that
        // stopped a landscape photo from widening the slide and pushing the overlays +
        // rail off both edges.)
        GeometryReader { geo in
            // `geo` RESPECTS the safe area, so `geo.safeAreaInsets` is real; the
            // ScrollView below ignores it to bleed full-screen. Add the insets back
            // to get the full screen height for each slide, and hand the footer inset
            // to the chrome so it clears the bar even though the slide bleeds behind it.
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
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
                            followerCount: followerCount(item),
                            saved: saved(item),
                            shareURL: shareURL(item),
                            bookResolving: resolvingBookId == item.id,
                            bottomInset: geo.safeAreaInsets.bottom,
                            onLike: { Task { await toggleLike(item) } },
                            onComment: { commentsFor = item },
                            onSave: { saveFor = item },
                            onFollow: { Task { await toggleFollow(item) } },
                            onShared: { Task { await recordShare(item) } },
                            onBook: { Task { await startBooking(item) } },
                            onToggleMute: { muted.toggle() },
                            onOpenTag: { tag in tagFeedFor = tag },
                            onHide: { hideCandidate = item }
                        )
                        .frame(width: geo.size.width, height: fullHeight)
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
            // Bleed full-screen so the full-height slides fill the paging viewport
            // exactly — `.paging` then steps by the whole screen and every slide
            // snaps flush, with no sliver of the previous slide left at the top.
            .ignoresSafeArea()
            // Record a sampled view impression for whichever slide snaps active (B2).
            .onChange(of: activeId) { _, id in Task { await recordView(id) } }
            // Start the first slide playing before any scroll happens.
            .onAppear { if activeId == nil { activeId = items.first?.id } }
            .onChange(of: items.first?.id) { _, first in if activeId == nil { activeId = first } }
        }
    }

    private var emptyState: some View {
        // A search that matched nothing is a different dead end from an empty
        // tab — "Check back soon" would be wrong advice for a typo.
        let searching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : (tab == .following ? "person.2" : "sparkles"))
                .font(.system(size: 30)).foregroundStyle(BrandColor.accent)
            Text(searching
                 ? "No looks match “\(searchQuery)”"
                 : (tab == .following ? "No looks from pros you follow yet" : "No looks here yet"))
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(searching
                 ? "Try a different service, pro, or keyword."
                 : (tab == .following ? "Follow pros to see their latest work." : "Check back soon."))
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
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

    /// `showSpinner: false` keeps whatever is on screen until the new page lands
    /// — used for search-as-you-type, where blanking the feed to a spinner on
    /// every debounced keystroke would strobe. The result still swaps to `.empty`
    /// when a query matches nothing.
    private func load(showSpinner: Bool = true) async {
        if showSpinner { phase = .loading }
        likeOverrides = [:]; likeCounts = [:]; commentCounts = [:]; followByPro = [:]
        savedOverrides = [:]
        let p = params()
        do {
            let page = try await session.client.looks.feed(
                filter: p.filter, category: p.category, following: p.following,
                query: searchQuery
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
                filter: p.filter, category: p.category, following: p.following,
                query: searchQuery
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
                filter: p.filter, category: p.category, following: p.following,
                query: searchQuery, cursor: cursor
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
        guard let pro = i.professional else { return false }
        return followByPro[pro.id]?.following ?? i.viewerFollows
    }

    /// The count beside the FOLLOW pill. Reads through the live toggle once the
    /// viewer has tapped, so it moves with the pill instead of staying frozen at
    /// whatever the feed payload happened to carry.
    private func followerCount(_ i: LooksFeedItem) -> Int {
        guard let pro = i.professional else { return 0 }
        return followByPro[pro.id]?.followerCount ?? pro.followerCount
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

        guard let offering = await LookBooking.offering(
            client: session.client,
            professionalId: pro.id,
            serviceId: item.serviceId
        ) else {
            fallbackToProfile()
            return
        }
        bookLaunch = BookLaunch(pro: pro, offering: offering)
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

    /// "Not for me" — optimistically drop the slide, then tell the server. Mirrors
    /// web `LooksFeed.hideLook`: re-entrancy-guarded, and on failure the look is
    /// restored at the index it came from.
    ///
    /// Unlike web (a scrolling list) this feed is a pager bound to
    /// `scrollPosition(id: $activeId)`, so removing the ACTIVE slide would leave
    /// that binding pointing at an id no longer in the list — the pager would have
    /// nothing to rest on. Hand it the slide that takes the removed one's place
    /// (or the new last slide) BEFORE mutating the list.
    private func hideLook(_ item: LooksFeedItem) async {
        guard case let .loaded(current) = phase,
              !hideInFlight.contains(item.id),
              let removedIndex = current.firstIndex(where: { $0.id == item.id })
        else { return }

        hideInFlight.insert(item.id)
        defer { hideInFlight.remove(item.id) }

        var next = current
        next.remove(at: removedIndex)

        if activeId == item.id {
            // The slide at removedIndex is now the one that slid up into view;
            // past the end, fall back to the new last slide (nil when empty).
            activeId = next.indices.contains(removedIndex)
                ? next[removedIndex].id
                : next.last?.id
        }

        phase = next.isEmpty ? .empty : .loaded(next)

        do {
            _ = try await session.client.looks.hide(lookId: item.id)
        } catch {
            restoreHidden(item, at: removedIndex)
        }
    }

    /// Put a look back where it was after a failed hide. No-op if it already
    /// reappeared (a reload can beat the failure back). Web parity: the index is
    /// clamped, because the list may have grown or shrunk while the write was in
    /// flight.
    private func restoreHidden(_ item: LooksFeedItem, at index: Int) {
        var list: [LooksFeedItem]
        switch phase {
        case let .loaded(current): list = current
        case .empty: list = []
        // .loading/.failed — a reload took over; it will re-fetch the truth
        // (the server did NOT hide it), so there is nothing to restore into.
        case .loading, .failed: return
        }

        guard !list.contains(where: { $0.id == item.id }) else { return }
        list.insert(item, at: min(max(index, 0), list.count))
        phase = .loaded(list)
        if activeId == nil { activeId = item.id }
    }

    private func toggleFollow(_ item: LooksFeedItem) async {
        guard let pro = item.professional else { return }

        // Snapshot the *entry*, not just its value — it may legitimately be
        // absent, meaning "no local opinion yet, defer to the payload".
        let previousEntry = followByPro[pro.id]
        var toggle = previousEntry
            ?? FollowToggle(following: item.viewerFollows, followerCount: pro.followerCount)
        // Load-bearing guard: the route is a blind toggle, so a second call in
        // flight would undo the first.
        guard toggle.begin() != nil else { return }
        followByPro[pro.id] = toggle

        do {
            let res = try await session.client.looks.toggleFollow(professionalId: pro.id)
            toggle.finish(res)
            followByPro[pro.id] = toggle
        } catch {
            // Restore the dictionary exactly as it was — including *absent*.
            // `toggle.fail()` would restore the right value but still leave an
            // entry behind, and `reloadKeepingPlace()` swaps in fresh feed items
            // without clearing this dict, so a pinned entry from a follow that
            // never happened would shadow the server's own `viewerFollows`.
            followByPro[pro.id] = previousEntry
            Haptics.failure()
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
    /// Tracked alongside `following` so the count beside the pill moves with it —
    /// it used to read straight off the (immutable) feed payload and sit frozen
    /// while the pill flipped inches away.
    let followerCount: Int
    let saved: Bool
    let shareURL: URL?
    /// True while the pro profile is being fetched to preselect the look's
    /// service — the BOOK button shows a spinner instead of the calendar icon.
    let bookResolving: Bool
    /// The footer's safe-area inset. The slide is full-bleed (it extends behind the
    /// footer), so the bottom chrome adds this on top of its own padding to sit
    /// above the bar instead of behind it.
    let bottomInset: CGFloat
    let onLike: () -> Void
    let onComment: () -> Void
    let onSave: () -> Void
    let onFollow: () -> Void
    let onShared: () -> Void
    let onBook: () -> Void
    let onToggleMute: () -> Void
    /// A tag chip tap → open its web tag page (social-first D1).
    let onOpenTag: (LooksTag) -> Void
    /// "Not for me" — drops the slide and tells the server to stop showing it.
    let onHide: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            media
                // "Not for me" lives on a long press of the look itself (the
                // TikTok/IG gesture) rather than a rail icon — web puts an EyeOff
                // in its rail, but a 7th control isn't worth the room here.
                // Scoped to the media so it can't fire from the rail's buttons,
                // and a long press doesn't race the pager (that's a drag).
                .onLongPressGesture { onHide() }

            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                overlays
                Spacer(minLength: 8)
                rail
            }
            .padding(.horizontal, 16)
            // 30 above the footer: the slide bleeds behind the bar, so add its inset.
            .padding(.bottom, 30 + bottomInset)
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
            // Smart 9:16 crop (camera C6c): center the full-screen cover window on
            // the subject focal instead of the blind geometric center. Null focal →
            // plain centered fill (byte-identical to pre-C6c).
            FocalCoverImage(
                url: url,
                focal: item.focalPoint,
                placeholder: { ProgressView().tint(BrandColor.accent) },
                failure: { fallback }
            )
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
                if followerCount > 0 {
                    Text(followerLabel(followerCount))
                        .font(BrandFont.mono(11)).foregroundStyle(.white.opacity(0.7))
                }
            } else if let author = item.clientAuthor {
                NavigationLink(value: author) {
                    Text(author.handleLabel).font(BrandFont.body(15, .semibold)).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
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
                NavigationLink(value: author) { avatarPlus(name: author.handleLabel, url: author.avatarUrl) }
                    .buttonStyle(.plain)
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

    // Shared with the single-look detail so the same look can't read "1.2K" here
    // and "1200" there — see TovisKit's CompactCount.
    private func countLabel(_ n: Int) -> String { CompactCount.label(n) }

    private func followerLabel(_ n: Int) -> String { CompactCount.followers(n) }
}
