// Looks — the client's social home base (center feather tab). A full-bleed,
// vertically-paged feed (TikTok/IG-style) matching the web LooksFeed: media +
// bottom-left overlays (creator, service, price, caption) + a right action rail
// (like, comment, book, creator avatar). For You / Following tabs up top.
//
// Reads work signed-in (this tab only renders inside the signed-in shell);
// like/comment write through and reconcile with the server. Mirrors the web's
// optimistic-then-reconcile pattern. Live-sync refetches on refreshTick.
import SwiftUI
import TovisKit

struct LooksView: View {
    @Environment(SessionModel.self) private var session

    private enum Tab: String, CaseIterable, Identifiable {
        case forYou = "For You"
        case following = "Following"
        var id: String { rawValue }
        var isFollowing: Bool { self == .following }
    }

    private enum Phase {
        case loading
        case loaded([LooksFeedItem])
        case empty
        case failed(String)
    }

    @State private var tab: Tab = .forYou
    @State private var phase: Phase = .loading
    @State private var nextCursor: String?
    @State private var loadingMore = false

    // Optimistic viewer overrides, keyed by look id (the wire model is immutable
    // outside TovisKit, so we layer state instead of rebuilding items).
    @State private var likeOverrides: [String: Bool] = [:]
    @State private var likeCounts: [String: Int] = [:]
    @State private var commentCounts: [String: Int] = [:]

    @State private var commentsFor: LooksFeedItem?

    var body: some View {
        NavigationStack {
            ZStack {
                BrandColor.bgPrimary.ignoresSafeArea()

                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent)
                case let .failed(message):
                    failure(message)
                case .empty:
                    emptyState
                case let .loaded(items):
                    feed(items)
                }

                topTabs
            }
            .navigationDestination(for: LooksProfessional.self) { pro in
                ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(BrandColor.accent)
        .task { if case .loading = phase { await load() } }
        .onChange(of: tab) { Task { await load() } }
        .onChange(of: session.refreshTick) { Task { await reloadKeepingPlace() } }
        .sheet(item: $commentsFor) { item in
            LookCommentsView(look: item) { delta in
                commentCounts[item.id] = commentCount(item) + delta
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
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
                        onLike: { Task { await toggleLike(item) } },
                        onComment: { commentsFor = item }
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
        .ignoresSafeArea()
    }

    private var topTabs: some View {
        VStack {
            HStack(spacing: 22) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(BrandFont.body(16, tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? BrandColor.textPrimary : BrandColor.textPrimary.opacity(0.6))
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.isFollowing ? "person.2" : "sparkles")
                .font(.system(size: 30)).foregroundStyle(BrandColor.accent)
            Text(tab.isFollowing ? "No looks from pros you follow yet" : "No looks yet")
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text(tab.isFollowing ? "Follow pros to see their latest work here." : "Check back soon.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        }
        .padding(40)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.accent)
        }
        .padding(40)
    }

    // MARK: - Data

    private func load() async {
        phase = .loading
        likeOverrides = [:]; likeCounts = [:]; commentCounts = [:]
        do {
            let page = try await session.client.looks.feed(following: tab.isFollowing)
            nextCursor = page.nextCursor
            phase = page.items.isEmpty ? .empty : .loaded(page.items)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load looks.")
        }
    }

    /// A live-sync nudge: refetch the first page but don't yank the user back to
    /// a spinner if they're already browsing.
    private func reloadKeepingPlace() async {
        guard case .loaded = phase else { await load(); return }
        do {
            let page = try await session.client.looks.feed(following: tab.isFollowing)
            nextCursor = page.nextCursor
            if !page.items.isEmpty { phase = .loaded(page.items) }
        } catch { /* keep what's on screen */ }
    }

    private func loadMoreIfNeeded(at index: Int, total: Int) async {
        guard !loadingMore, let cursor = nextCursor, index >= total - 3 else { return }
        guard case let .loaded(current) = phase else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await session.client.looks.feed(following: tab.isFollowing, cursor: cursor)
            nextCursor = page.nextCursor
            phase = .loaded(current + page.items)
        } catch { /* leave the cursor; a later slide retries */ }
    }

    // MARK: - Likes (optimistic)

    private func liked(_ item: LooksFeedItem) -> Bool { likeOverrides[item.id] ?? item.viewerLiked }
    private func likeCount(_ item: LooksFeedItem) -> Int { likeCounts[item.id] ?? item.count.likes }
    private func commentCount(_ item: LooksFeedItem) -> Int { commentCounts[item.id] ?? item.count.comments }

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
            likeOverrides[item.id] = !next          // revert
            likeCounts[item.id] = base
        }
    }
}

// MARK: - One full-screen slide

private struct LookSlide: View {
    let item: LooksFeedItem
    let liked: Bool
    let likeCount: Int
    let commentCount: Int
    let onLike: () -> Void
    let onComment: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            if let url = URL(string: item.url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        fallback
                    default:
                        ProgressView().tint(BrandColor.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                fallback
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )
            .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                overlays
                Spacer(minLength: 8)
                rail
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
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

    // Creator + service + price + caption (bottom-left).
    private var overlays: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pro = item.professional {
                NavigationLink(value: pro) {
                    creatorRow(name: pro.displayName, avatarUrl: pro.avatarUrl, chevron: true)
                }
                .buttonStyle(.plain)
            } else if let author = item.clientAuthor {
                creatorRow(name: author.handleLabel, avatarUrl: author.avatarUrl, chevron: false)
            }

            HStack(spacing: 8) {
                if let service = item.serviceName ?? item.category {
                    overlayPill(text: service, icon: "scissors")
                }
                if let price = item.priceLabel {
                    overlayPill(text: "from \(price)", icon: "tag")
                }
            }

            if let caption = item.caption, !caption.isEmpty {
                Text(caption)
                    .font(BrandFont.body(14))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func creatorRow(name: String, avatarUrl: String?, chevron: Bool) -> some View {
        HStack(spacing: 8) {
            BrandAvatar(name: name, avatarUrl: avatarUrl, size: 34)
            Text(name)
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func overlayPill(text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(BrandFont.body(12, .medium))
        }
        .foregroundStyle(.white)
        .padding(.vertical, 6).padding(.horizontal, 11)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // Like / comment / book (right rail).
    private var rail: some View {
        VStack(spacing: 20) {
            railButton(
                icon: liked ? "heart.fill" : "heart",
                tint: liked ? BrandColor.ember : .white,
                count: likeCount,
                action: onLike
            )
            railButton(icon: "bubble.right", tint: .white, count: commentCount, action: onComment)
            if let pro = item.professional {
                NavigationLink(value: pro) {
                    VStack(spacing: 6) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.white)
                        Text("Book").font(BrandFont.body(11, .semibold)).foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func railButton(icon: String, tint: Color, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 27, weight: .regular)).foregroundStyle(tint)
                Text(countLabel(count)).font(BrandFont.body(11, .semibold)).foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func countLabel(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)
        }
        return "\(n)"
    }
}
