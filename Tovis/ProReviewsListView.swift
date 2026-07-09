// Pro Reviews — the native counterpart of the web `/pro/reviews`, backed by
// GET /api/v1/pro/reviews (tovis-app PR #438). The 100 most recent reviews with
// star rating, headline/body, client + date, and a media grid; a review with a
// booking taps through to its detail. Lives on the Overview home's Reviews tab.
//
// Clients author reviews; the pro may post one public response per review
// (PUT/DELETE /pro/reviews/{id}/reply, tovis-app PR #475). The web "feature in
// portfolio" toggle on review media is web-only (omitted here).
import SwiftUI
import TovisKit

struct ProReviewsListView: View {
    @Environment(SessionModel.self) private var session
    /// A review id from a tapped `review-received` push (`/pro/reviews#review-{id}`);
    /// the list scrolls to that review once loaded. nil = open at the top.
    var focusReviewId: String? = nil

    private enum Phase {
        case loading
        case loaded([ProReviewItem])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var viewingMedia: FullscreenMedia?
    @State private var composingReplyFor: ProReviewItem?
    @State private var removingReplyFor: ProReviewItem?
    /// One-shot guard so the deep-link scroll fires only on the first load.
    @State private var didFocus = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                            .padding(.top, 50)
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(items):
                        if items.isEmpty {
                            Text("No reviews yet.")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 30)
                        } else {
                            ForEach(items) { review in
                                reviewCard(review)
                                    .id(review.id)   // scroll anchor for the review deep link
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 120)   // clear the raised footer
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .refreshable { await load() }
            .task { if case .loading = phase { await load(scroll: proxy) } }
            .onChange(of: session.refreshTick) { Task { await load() } }
        }
        .mediaFullscreenCover($viewingMedia)
        .sheet(item: $composingReplyFor) { review in
            ProReviewReplySheet(review: review) { Task { await load() } }
        }
        .alert(
            "Remove your response?",
            isPresented: Binding(
                get: { removingReplyFor != nil },
                set: { if !$0 { removingReplyFor = nil } }
            ),
            presenting: removingReplyFor
        ) { review in
            Button("Remove", role: .destructive) { Task { await removeReply(review) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your public response will no longer appear under this review.")
        }
    }

    private func reviewCard(_ review: ProReviewItem) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(review.clientName)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                    Text("• \(review.date)")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                    Spacer()
                }

                stars(review.rating)

                if let headline = review.headline, !headline.isEmpty {
                    Text(headline)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
                if let body = review.body, !body.isEmpty {
                    Text(body)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textPrimary.opacity(0.85))
                }

                if let reply = review.proReply {
                    proReplyBlock(reply)
                }

                replyActions(review)

                if !review.mediaTiles.isEmpty {
                    mediaGrid(review.mediaTiles)
                }

                if let bookingId = review.bookingId {
                    NavigationLink {
                        ProBookingDetailView(bookingId: bookingId)
                    } label: {
                        Text("View booking")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 14)
                            .overlay(
                                Capsule().stroke(BrandColor.textMuted.opacity(0.30), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }

    /// The pro's public response, rendered as a left-bordered quote block.
    private func proReplyBlock(_ reply: ProReviewItem.ProReviewReply) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your public response · \(Wire.dateOnly(reply.repliedAtISO))")
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(BrandColor.textMuted)
            Text(reply.body)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textPrimary.opacity(0.85))
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(BrandColor.accent.opacity(0.5))
                .frame(width: 2)
        }
        .padding(.top, 2)
    }

    private func replyActions(_ review: ProReviewItem) -> some View {
        HStack(spacing: 10) {
            Button {
                composingReplyFor = review
            } label: {
                Text(review.proReply == nil ? "Reply publicly" : "Edit response")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .overlay(
                        Capsule().stroke(BrandColor.textMuted.opacity(0.30), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            if review.proReply != nil {
                Button {
                    removingReplyFor = review
                } label: {
                    Text("Remove")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.ember)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .overlay(
                            Capsule().stroke(BrandColor.ember.opacity(0.30), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.top, 2)
    }

    private func stars(_ rating: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < rating ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(i < rating ? BrandColor.gold : BrandColor.textMuted.opacity(0.4))
            }
        }
        .accessibilityLabel("Rating \(rating) out of 5")
    }

    private func mediaGrid(_ tiles: [ProReviewItem.MediaTile]) -> some View {
        // A paired before is subsumed by its after's slider, so drop it from the grid.
        let beforeIds = Set(tiles.compactMap { $0.before?.id })
        let visible = tiles.filter { !beforeIds.contains($0.id) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(visible) { tile in
                if let before = tile.before, let beforeStr = before.displayUrl,
                   let beforeURL = URL(string: beforeStr), let afterURL = URL(string: tile.src) {
                    // Paired before/after → the comparison slider fills the square cell.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                BeforeAfterCompareView(beforeURL: beforeURL, afterURL: afterURL, height: geo.size.height, cornerRadius: 10)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }
                        .clipped()
                } else {
                    Button {
                        // `src` is a signed thumbnail/source URL (poster for video),
                        // so open it as an image — reliable full-size view of the shot.
                        viewingMedia = FullscreenMedia.remote(id: tile.id, urlString: tile.src, isVideo: false)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BrandColor.bgPrimary)
                            if let url = URL(string: tile.src) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    ProgressView().tint(BrandColor.accent)
                                }
                            }
                            if tile.isVideo {
                                Text("VIDEO")
                                    .font(BrandFont.mono(8))
                                    .foregroundStyle(BrandColor.textPrimary)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(BrandColor.bgPrimary.opacity(0.72))
                                    .clipShape(Capsule())
                                    .padding(6)
                            }
                        }
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
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
        .padding(.top, 50)
    }

    private func load(scroll proxy: ScrollViewProxy? = nil) async {
        do {
            let items = try await session.client.proProfile.reviews()
            phase = .loaded(items)
            await focus(items, proxy)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your reviews.")
        }
    }

    /// Scroll to the deep-linked review once, after the list has rendered. The brief
    /// delay lets the sheet-present animation settle and the cards lay out so the
    /// anchor id resolves.
    private func focus(_ items: [ProReviewItem], _ proxy: ScrollViewProxy?) async {
        guard !didFocus, let proxy, let focusReviewId,
              items.contains(where: { $0.id == focusReviewId }) else { return }
        didFocus = true
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation { proxy.scrollTo(focusReviewId, anchor: .top) }
    }

    private func removeReply(_ review: ProReviewItem) async {
        do {
            try await session.client.proProfile.deleteReviewReply(reviewId: review.id)
            await load()
        } catch {
            // Non-fatal; a reload will reflect the true state.
        }
    }
}

// MARK: - Reply compose

/// Compose the pro's public response to a review — PUT /pro/reviews/{id}/reply
/// upserts (1–1000 chars), so the same sheet writes and edits. Pre-fills the
/// existing reply when editing; `onSaved` refreshes the list.
struct ProReviewReplySheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let review: ProReviewItem
    var onSaved: () -> Void

    @State private var text: String
    @State private var posting = false
    @State private var error: String?

    private let maxLength = 1000

    init(review: ProReviewItem, onSaved: @escaping () -> Void) {
        self.review = review
        self.onSaved = onSaved
        _text = State(initialValue: review.proReply?.body ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your response is public — everyone who sees this review sees it.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(BrandColor.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .font(BrandFont.body(15))
                        .foregroundStyle(BrandColor.textPrimary)
                        .onChange(of: text) {
                            if text.count > maxLength { text = String(text.prefix(maxLength)) }
                        }

                    Text("\(text.count)/\(maxLength)")
                        .font(BrandFont.mono(11))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(review.proReply == nil ? "Reply publicly" : "Edit response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(posting ? "Posting…" : "Post") { Task { await post() } }
                        .disabled(posting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func post() async {
        guard !posting else { return }
        posting = true
        error = nil
        defer { posting = false }
        do {
            try await session.client.proProfile.upsertReviewReply(
                reviewId: review.id,
                body: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t post your response. Try again."
        }
    }
}
