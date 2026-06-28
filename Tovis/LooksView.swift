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

    @State private var commentsFor: LooksFeedItem?
    @State private var saveFor: LooksFeedItem?

    var body: some View {
        NavigationStack {
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
                    feed(items)
                }

                header
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
            LookCommentsView(look: item) { delta in
                commentCounts[item.id] = commentCount(item) + delta
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $saveFor) { item in
            SaveToBoardSheet(lookId: item.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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
                        liked: liked(item),
                        likeCount: likeCount(item),
                        commentCount: commentCount(item),
                        following: following(item),
                        shareURL: shareURL(item),
                        onLike: { Task { await toggleLike(item) } },
                        onComment: { commentsFor = item },
                        onSave: { saveFor = item },
                        onFollow: { Task { await toggleFollow(item) } }
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
        .scrollTargetBehavior(.paging)
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
    private func shareURL(_ i: LooksFeedItem) -> URL? {
        URL(string: "https://www.tovis.app/looks/\(i.id)")
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

// MARK: - One full-screen slide

private struct LookSlide: View {
    let item: LooksFeedItem
    let liked: Bool
    let likeCount: Int
    let commentCount: Int
    let following: Bool
    let shareURL: URL?
    let onLike: () -> Void
    let onComment: () -> Void
    let onSave: () -> Void
    let onFollow: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            if let url = URL(string: item.url) {
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

            if let service = item.serviceName ?? item.category {
                Text(service.uppercased())
                    .font(BrandFont.mono(11))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.vertical, 5).padding(.horizontal, 11)
                    .background(.ultraThinMaterial, in: Capsule())
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
            railButton(icon: "bookmark", tint: .white, count: nil, action: onSave)

            if let shareURL {
                ShareLink(item: shareURL) {
                    railIcon("square.and.arrow.up", tint: .white)
                }
                .buttonStyle(.plain)
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

    private func bookButton(pro: LooksProfessional) -> some View {
        NavigationLink(value: pro) {
            VStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(width: 52, height: 52)
                    .background(BrandColor.accent, in: Circle())
                    .shadow(color: BrandColor.accent.opacity(0.55), radius: 10, y: 3)
                Text("BOOK").font(BrandFont.mono(11)).tracking(0.6).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            }
        }
        .buttonStyle(.plain)
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
