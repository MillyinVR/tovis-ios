// The single-look detail — the native counterpart of web's /looks/[id].
//
// Reached from a tapped share link (LooksLink → Universal Link) or a push href,
// both of which resolve to `PushDeepLink.Target.look(id:)`. Before this screen
// existed, every one of those landed on the Looks feed with the id discarded —
// including the links the app's own share sheet generates.
//
// Renders web's order: media (video / before-after reveal / image) → actions →
// creator + pro → service + caption + tags → the 5 stats → the review → the
// post's other assets. The wire models are immutable outside TovisKit, so viewer
// state (liked/saved/counts) is layered in optimistic @State and reconciled with
// the server, the same way the feed does it.
import SwiftUI
import TovisKit

struct LookDetailView: View {
    @Environment(SessionModel.self) private var session

    let lookId: String

    private enum Phase {
        case loading
        case loaded(LookDetail)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    // Optimistic overrides layered over the wire model (nil = use the server's).
    @State private var likedOverride: Bool?
    @State private var likeCountOverride: Int?
    @State private var savedOverride: Bool?
    @State private var saveCountOverride: Int?
    @State private var commentsCountOverride: Int?
    @State private var shareCountOverride: Int?

    // The detail DTO carries neither follow state nor a follower count — web
    // hydrates both client-side too (useProFollow → GET /pros/{id}/follow).
    /// `nil` until hydrated — the button stays hidden rather than flashing the
    /// wrong state. Shared with the other five follow controls (`FollowToggle`).
    @State private var follow: FollowToggle?

    @State private var commentsOpen = false
    @State private var saveOpen = false
    /// A tapped tag chip → the native tag feed (LookTagFeedView).
    @State private var tagFeedFor: LooksTag?
    @State private var bookLaunch: DetailBookLaunch?
    @State private var bookResolving = false
    @State private var proProfileFor: String?

    var body: some View {
        content
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Look")
            .navigationBarTitleDisplayMode(.inline)
            .tint(BrandColor.accent)
            .task { await load() }
            .sheet(isPresented: $commentsOpen) {
                if case let .loaded(look) = phase {
                    LookCommentsView(
                        lookId: look.id,
                        commentsCount: commentsCount(look)
                    ) { delta in
                        commentsCountOverride = commentsCount(look) + delta
                    }
                }
            }
            .sheet(isPresented: $saveOpen) {
                if case let .loaded(look) = phase {
                    SaveToBoardSheet(lookId: look.id) { state in
                        savedOverride = state.isSaved
                        saveCountOverride = state.saveCount
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            // Its own stack + Done button (like MainTabView's deep-link look
            // sheets) — the tag feed pushes sibling look details inside it.
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
            .sheet(item: $bookLaunch) { launch in
                BookingFlowView(
                    professionalId: launch.professionalId,
                    proName: launch.proName,
                    offering: launch.offering
                )
            }
            .navigationDestination(item: $proProfileFor) { id in
                ProProfileView(professionalId: id)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().tint(BrandColor.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 30)).foregroundStyle(BrandColor.textMuted)
                Text(message)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.accent)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(look):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    media(look)
                    actionRow(look)
                    creatorSection(look)
                    serviceAndCaption(look)
                    tagChips(look)
                    statsRow(look)
                    reviewBlock(look)
                    secondaryAssets(look)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Media

    @ViewBuilder
    private func media(_ look: LookDetail) -> some View {
        Group {
            if look.isVideo, let url = URL(string: look.primaryMedia.url) {
                LookVideoView(url: url, isActive: true, isMuted: false)
                    .frame(height: 420)
            } else if let pair = look.beforeAfterPair {
                // The money shot. `passVerticalScroll` so the wipe claims only
                // horizontal drags — this screen scrolls under it, unlike the
                // grid tiles the slider defaults to.
                BeforeAfterCompareView(
                    beforeURL: pair.before,
                    afterURL: pair.after,
                    height: 420,
                    passVerticalScroll: true
                )
            } else if let url = URL(string: look.primaryMedia.url) {
                FocalCoverImage(url: url, focal: look.focalPoint) {
                    Rectangle().fill(BrandColor.bgSecondary)
                } failure: {
                    Rectangle().fill(BrandColor.bgSecondary)
                }
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func actionRow(_ look: LookDetail) -> some View {
        // Counts compact here (1.2K), matching web's rail AND the native feed's —
        // this row shows the same counters for the same look, so a viewer tapping
        // through from a shared link must not watch "1.2K" become "1200". The
        // stats row below is the verbose readout and stays exact.
        HStack(spacing: 22) {
            actionButton(
                systemName: liked(look) ? "heart.fill" : "heart",
                label: CompactCount.label(likeCount(look)),
                tint: liked(look) ? BrandColor.ember : BrandColor.textPrimary
            ) { Task { await toggleLike(look) } }

            actionButton(systemName: "bubble.right", label: CompactCount.label(commentsCount(look))) {
                commentsOpen = true
            }

            actionButton(
                systemName: saved(look) ? "bookmark.fill" : "bookmark",
                label: CompactCount.label(saveCount(look)),
                tint: saved(look) ? BrandColor.iris : BrandColor.textPrimary
            ) { saveOpen = true }

            if let url = shareURL(look) {
                ShareLink(item: url) {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 19))
                        Text(CompactCount.label(shareCount(look))).font(BrandFont.mono(11))
                    }
                    .foregroundStyle(BrandColor.textPrimary)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    Task { await recordShare(look) }
                })
            }

            Spacer()

            bookButton(look)
        }
        .padding(.top, 2)
    }

    private func actionButton(
        systemName: String,
        label: String,
        tint: Color = BrandColor.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName).font(.system(size: 19))
                Text(label).font(BrandFont.mono(11))
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private func bookButton(_ look: LookDetail) -> some View {
        Button { Task { await startBooking(look) } } label: {
            HStack(spacing: 6) {
                if bookResolving {
                    ProgressView().controlSize(.mini).tint(BrandColor.bgPrimary)
                } else {
                    Image(systemName: "calendar").font(.system(size: 13, weight: .bold))
                }
                Text("BOOK")
                    .font(BrandFont.mono(12)).tracking(1.2)
            }
            .foregroundStyle(BrandColor.bgPrimary)
            .padding(.vertical, 9).padding(.horizontal, 16)
            .background(BrandColor.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(bookResolving)
    }

    // MARK: - Creator + pro

    @ViewBuilder
    private func creatorSection(_ look: LookDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // A client-authored look credits the client above the pro, as web does.
            if let author = look.clientAuthor {
                HStack(spacing: 8) {
                    BrandAvatar(name: author.handleLabel, avatarUrl: author.avatarUrl, size: 32)
                    Text(author.handleLabel)
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
            }

            HStack(spacing: 10) {
                Button { proProfileFor = look.professional.id } label: {
                    HStack(spacing: 8) {
                        BrandAvatar(
                            name: look.professional.displayName,
                            avatarUrl: look.professional.avatarUrl,
                            size: 40
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(look.clientAuthor == nil
                                 ? look.professional.displayName
                                 : "with \(look.professional.displayName)")
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            if let sub = proSubtitle(look) {
                                Text(sub)
                                    .font(BrandFont.body(12))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                followButton(look)
            }
        }
    }

    /// "Cosmetologist · Los Angeles, CA" — web renders professionType (falling
    /// back to "Beauty pro") then the location.
    private func proSubtitle(_ look: LookDetail) -> String? {
        let type = look.professional.professionType?.capitalized ?? "Beauty pro"
        guard let location = look.professional.location, !location.isEmpty else { return type }
        return "\(type) · \(location)"
    }

    @ViewBuilder
    private func followButton(_ look: LookDetail) -> some View {
        // Hidden until hydrated so it can't flash the wrong state — the detail
        // payload has no follow flag, so `follow` is nil on first paint.
        if let follow {
            let following = follow.following
            Button { Task { await toggleFollow(look) } } label: {
                Text(following ? "Following" : "Follow")
                    .font(BrandFont.mono(11)).tracking(1.1)
                    .foregroundStyle(following ? BrandColor.textPrimary : BrandColor.bgPrimary)
                    .padding(.vertical, 7).padding(.horizontal, 14)
                    .background {
                        Capsule().fill(following ? Color.clear : BrandColor.accent)
                    }
                    .overlay {
                        Capsule().stroke(
                            following ? BrandColor.textMuted.opacity(0.5) : .clear,
                            lineWidth: 1
                        )
                    }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Service, caption, tags

    @ViewBuilder
    private func serviceAndCaption(_ look: LookDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let service = look.service {
                HStack(spacing: 6) {
                    chip(service.name.uppercased())
                    if let category = service.category { chip(category.name.uppercased()) }
                }
            }

            if let caption = look.caption, !caption.isEmpty {
                Text("“\(caption)”")
                    .font(BrandFont.display(19).italic())
                    .foregroundStyle(BrandColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func tagChips(_ look: LookDetail) -> some View {
        // Gated at the call site: an empty custom view still takes the VStack's
        // spacing and would leave a gap mid-screen.
        if !look.tags.isEmpty {
            // The detail is the place the FULL tag set belongs — the feed caps at
            // 3 because the overlay sits on the image.
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(look.tags) { tag in
                    Button { openTag(tag) } label: {
                        Text("#\(tag.display)")
                            .font(BrandFont.mono(11)).tracking(0.6)
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.vertical, 5).padding(.horizontal, 11)
                            .background(BrandColor.bgSecondary, in: Capsule())
                            .overlay(Capsule().stroke(BrandColor.accent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(11)).tracking(1.2)
            .foregroundStyle(BrandColor.textSecondary)
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(BrandColor.bgSecondary, in: Capsule())
    }

    // MARK: - Stats

    private func statsRow(_ look: LookDetail) -> some View {
        // The verbose readout: EXACT counts (web renders these uncompacted too),
        // unlike the action row's 1.2K. Wrapped in FlowLayout because five
        // label+value pairs don't fit one line on a small phone.
        FlowLayout(spacing: 12, lineSpacing: 6) {
            stat("Views", look.count.views)
            stat("Likes", likeCount(look))
            stat("Comments", commentsCount(look))
            stat("Saves", saveCount(look))
            stat("Shares", shareCount(look))
        }
        .padding(.top, 2)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(label):")
                .font(BrandFont.body(12, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            // `.formatted()` groups by locale ("2,304"). Explicit on purpose:
            // `Text("\(value)")` would ALSO render "2,304" — but only as a side
            // effect of LocalizedStringKey interpolation, which is invisible at
            // the call site and silently differs from `Text(someString)`. Web
            // prints "2304"; the separator is a deliberate native nicety.
            Text(verbatim: value.formatted())
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - Review

    @ViewBuilder
    private func reviewBlock(_ look: LookDetail) -> some View {
        if let review = look.review {
            VStack(alignment: .leading, spacing: 6) {
                Divider().overlay(BrandColor.textMuted.opacity(0.15))
                Text(review.stars)
                    .font(BrandFont.body(13, .bold))
                    .foregroundStyle(BrandColor.accent)
                    .padding(.top, 6)
                if let headline = review.headline, !headline.isEmpty {
                    Text(headline)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let helpful = review.helpfulLabel {
                    Text(helpful)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
        }
    }

    // MARK: - More from this post

    @ViewBuilder
    private func secondaryAssets(_ look: LookDetail) -> some View {
        let others = look.secondaryAssets
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(BrandColor.textMuted.opacity(0.15))
                Text("MORE FROM THIS POST")
                    .font(BrandFont.mono(11)).tracking(1.2)
                    .foregroundStyle(BrandColor.textSecondary)
                    .padding(.top, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(others) { asset in
                        if let url = asset.media.thumbOrFullURL {
                            FocalCoverImage(url: url, focal: asset.media.focalPoint) {
                                Rectangle().fill(BrandColor.bgSecondary)
                            } failure: {
                                Rectangle().fill(BrandColor.bgSecondary)
                            }
                            .frame(height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if asset.media.isVideo {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white)
                                        .padding(5)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Derived viewer state

    private func liked(_ l: LookDetail) -> Bool { likedOverride ?? l.viewerContext.viewerLiked }
    private func likeCount(_ l: LookDetail) -> Int { likeCountOverride ?? l.count.likes }
    private func saved(_ l: LookDetail) -> Bool { savedOverride ?? l.viewerContext.viewerSaved }
    private func saveCount(_ l: LookDetail) -> Int { saveCountOverride ?? l.count.saves }
    private func commentsCount(_ l: LookDetail) -> Int { commentsCountOverride ?? l.count.comments }
    private func shareCount(_ l: LookDetail) -> Int { shareCountOverride ?? l.count.shares }

    /// Mirrors `LooksView.shareURL` — the canonical web page for this look, which
    /// this very screen now opens when tapped.
    private func shareURL(_ l: LookDetail) -> URL? {
        URL(string: "https://www.tovis.app/looks/\(l.id)")
    }

    private func openTag(_ tag: LooksTag) {
        tagFeedFor = tag
    }

    // MARK: - Actions

    private func load() async {
        phase = .loading
        do {
            let look = try await session.client.looks.detail(id: lookId)
            phase = .loaded(look)
            // Fire-and-forget, tagged DETAIL so it doesn't land in the §5.6
            // aggregate as a feed impression.
            Task { try? await session.client.looks.recordViews(lookIds: [look.id], source: .detail) }
            await hydrateFollow(professionalId: look.professional.id)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this look.")
        }
    }

    /// The detail DTO ships no follow state, so hydrate it like web does. Best
    /// effort: a signed-out viewer just never sees the button.
    private func hydrateFollow(professionalId: String) async {
        // Never over a call in flight — rebuilding the toggle would clear its busy
        // flag, and a second tap on a BLIND toggle undoes the first.
        guard !(follow?.isWorking ?? false),
              let state = try? await session.client.looks.followState(professionalId: professionalId)
        else { return }
        follow = FollowToggle(following: state.following, followerCount: state.followerCount)
    }

    private func toggleLike(_ look: LookDetail) async {
        let next = !liked(look)
        let previousLiked = likedOverride
        let previousCount = likeCountOverride
        likedOverride = next
        likeCountOverride = likeCount(look) + (next ? 1 : -1)
        do {
            let state = try await session.client.looks.setLiked(lookId: look.id, liked: next)
            likedOverride = state.liked
            likeCountOverride = state.likeCount
        } catch {
            likedOverride = previousLiked
            likeCountOverride = previousCount
        }
    }

    private func toggleFollow(_ look: LookDetail) async {
        // Not hydrated, or a call is already in flight. The guard is load-bearing:
        // the route is a blind toggle, so a second call would undo the first.
        guard var toggle = follow, toggle.begin() != nil else { return }
        follow = toggle

        do {
            let state = try await session.client.looks.toggleFollow(
                professionalId: look.professional.id
            )
            toggle.finish(state)
        } catch {
            toggle.fail()
            Haptics.failure()
        }
        follow = toggle
    }

    private func recordShare(_ look: LookDetail) async {
        guard let state = try? await session.client.looks.recordShare(lookId: look.id) else { return }
        shareCountOverride = state.shareCount
    }

    private func startBooking(_ look: LookDetail) async {
        guard !bookResolving else { return }
        bookResolving = true
        defer { bookResolving = false }

        guard let offering = await LookBooking.offering(
            client: session.client,
            professionalId: look.professional.id,
            serviceId: look.service?.id
        ) else {
            // No service, no offering, or the fetch failed → the profile, where
            // the client can still pick something. Never a dead end.
            proProfileFor = look.professional.id
            return
        }
        bookLaunch = DetailBookLaunch(
            professionalId: look.professional.id,
            proName: look.professional.displayName,
            offering: offering
        )
    }
}

/// Identifiable box so a bare look id can drive a `.sheet(item:)`. Both shells
/// present the detail this way (the same idiom as the booking/thread deep links),
/// so the box is shared rather than restated in each.
struct LookPresentation: Identifiable, Equatable {
    let id: String
}

private struct DetailBookLaunch: Identifiable {
    let professionalId: String
    let proName: String
    let offering: ProOffering
    var id: String { professionalId + offering.id }
}
