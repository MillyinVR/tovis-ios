// The native tag feed — web /looks/tags/[slug] (social-first D1) as a screen
// instead of a Safari eject. Replaces the three former SafariView eject points
// (LooksView's overlay chips, Discover's trending rail, LookDetailView's tag
// row); each presenter wraps this in a NavigationStack sheet, mirroring the
// deep-link look sheets in MainTabView/ProMainTabView.
//
// Backed by GET /looks?tag={slug} (web PR #673) through the shared LooksGrid;
// tapping a tile pushes the look detail (web parity: tag tiles link to
// /looks/{id}). Until the web param deploys the server ignores `tag` and
// returns the unfiltered feed — the screen degrades to "all looks", never an
// error.

import SwiftUI
import TovisKit

struct LookTagFeedView: View {
    /// The canonical tag slug from the look/trending payload — sent verbatim;
    /// the server owns normalization.
    let slug: String
    /// The first-seen human form, for the `#display` title (web parity).
    let display: String

    @Environment(SessionModel.self) private var session

    @State private var looks: [LooksFeedItem] = []
    @State private var cursor: String?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var openedLookId: String?

    private let pageSize = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("#\(display)")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BrandColor.accent)
        .navigationDestination(item: $openedLookId) { id in
            LookDetailView(lookId: id)
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Looks")
                .font(BrandFont.mono(11)).tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(BrandColor.textMuted)
            Text("#\(display)")
                .font(BrandFont.display(26, .semibold)).italic()
                .foregroundStyle(BrandColor.textPrimary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && looks.isEmpty {
            ProgressView().tint(BrandColor.accent)
                .frame(maxWidth: .infinity).padding(.top, 60)
        } else if let errorMessage, looks.isEmpty {
            VStack(spacing: 14) {
                Text(errorMessage)
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await load() }
                } label: {
                    Text("Retry")
                        .font(BrandFont.mono(11)).tracking(0.8)
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(.vertical, 10).padding(.horizontal, 24)
                        .background(BrandColor.bgPrimary.opacity(0.25), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 20)
        } else if looks.isEmpty {
            // Web's empty-state copy, verbatim.
            Text("No looks with this tag yet.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            LooksGrid(
                looks: looks,
                cta: { _ in .open },
                action: { openedLookId = $0.id },
                nextCursor: cursor,
                loadingMore: loadingMore,
                onLoadMore: { Task { await loadMore() } }
            )
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let page = try await session.client.looks.feed(tag: slug, limit: pageSize)
            looks = page.items
            cursor = page.nextCursor
        } catch {
            errorMessage = "Couldn’t load this tag. Check your connection and try again."
        }
        loading = false
    }

    private func loadMore() async {
        guard let cursor, !loadingMore else { return }
        loadingMore = true
        do {
            let page = try await session.client.looks.feed(tag: slug, cursor: cursor, limit: pageSize)
            // Paged feeds can overlap at the seam — keep first occurrence.
            let seen = Set(looks.map(\.id))
            looks.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            self.cursor = page.nextCursor
        } catch {
            // Keep what's rendered; the button stays for another try.
        }
        loadingMore = false
    }
}
