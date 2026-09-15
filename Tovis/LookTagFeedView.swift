// The native tag feed — web /looks/tags/[slug] (social-first D1) as a screen
// instead of a Safari eject. Replaces the three former SafariView eject points
// (LooksView's overlay chips, Discover's trending rail, LookDetailView's tag
// row); each presenter wraps this in a NavigationStack sheet, mirroring the
// deep-link look sheets in MainTabView/ProMainTabView.
//
// A tapped /looks/tags/{slug} Universal Link lands here too (LookTagLink →
// PushDeepLink.Target.lookTag → the shells' own sheet). That link used to be the
// one route into a tag that left the app: the AASA file excluded the path
// because "native has no tag screen", which stopped being true the day this
// file replaced those three ejects. The link arrives with no human label, hence
// the optional `display` below.
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
    /// The first-seen human form, for the `#display` title (web parity). A tap
    /// on a chip has it; a tapped `/looks/tags/{slug}` Universal Link does NOT
    /// — the URL carries only the slug — so it arrives nil there and the title
    /// falls back to the slug until `resolvedDisplay` upgrades it below.
    let display: String?

    @Environment(SessionModel.self) private var session

    @State private var looks: [LooksFeedItem] = []
    @State private var cursor: String?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var openedLookId: String?
    /// The human label recovered from the first loaded look that carries this
    /// tag, for the deep-link case where the caller had only the slug. Web reads
    /// `LookTag.display` from the row; the feed payload carries the same value on
    /// every look's tags, so the title ends up identical without a second fetch.
    @State private var resolvedDisplay: String?

    private let pageSize = 24

    /// What renders after the `#`. The slug is the last resort, not a wrong
    /// answer: it differs from web's label only in case/punctuation, and only
    /// until the first page lands.
    private var title: String { display ?? resolvedDisplay ?? slug }

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
        .navigationTitle("#\(title)")
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
            Text("#\(title)")
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
            if display == nil {
                resolvedDisplay = page.items
                    .lazy
                    .compactMap { $0.tags.first(where: { $0.slug == slug })?.display }
                    .first
            }
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

/// Identifiable wrapper so a shell can present the tag feed with `.sheet(item:)`
/// from a tapped `/looks/tags/{slug}` Universal Link. The slug IS the id, so two
/// taps on the same tag re-present the same sheet instead of stacking.
struct LookTagPresentation: Identifiable, Equatable {
    let id: String
    var slug: String { id }
}
