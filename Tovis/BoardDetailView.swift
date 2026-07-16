// Native board detail — the counterpart to the web `/client/boards/[boardId]`
// page (app/client/(gated)/boards/[boardId]/page.tsx). Reached by tapping a board
// in the "Me" tab's BOARDS grid (previously a dead-end). Reads
// GET /api/v1/boards/{id} via BoardsService and, like the web page, is view +
// share only: a saved-looks grid (tap → fullscreen) plus the share controls
// (Private ⇄ Shared toggle + a shareable /u/{handle}/boards/{slug} link).
import SwiftUI
import TovisKit

struct BoardDetailView: View {
    @Environment(SessionModel.self) private var session

    /// The preview row from the Me dashboard — gives the header an instant title
    /// and count while the full detail (looks + slug + visibility) loads.
    let board: ClientMeBoard
    /// The signed-in client's public handle (from `me.profile.handle`) — needed to
    /// build the share link. Nil when they haven't claimed one yet.
    let ownerHandle: String?

    private enum Phase {
        case loading
        case loaded(Board)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch phase {
                case .loading:
                    header(name: board.name, detail: nil)
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                case let .failed(message):
                    errorState(message)
                case let .loaded(detail):
                    header(name: detail.name, detail: detail)
                    BoardShareSection(
                        boardId: detail.id,
                        slug: detail.slug,
                        initialVisibility: detail.visibility,
                        handle: ownerHandle
                    )
                    // Gated here, not just inside the card: an undated board type
                    // must contribute NO subview, or this VStack's 20pt spacing
                    // would leave a gap above the grid where the card would be.
                    if BoardCatalog.wantsEventDate(for: detail.type) {
                        BoardEventCountdownSection(
                            boardId: detail.id,
                            type: detail.type,
                            initialEventDate: detail.eventDate
                        )
                    }
                    looksSection(detail)
                    BoardRecommendationsSection(boardId: detail.id, boardName: detail.name) { media in
                        viewingMedia = media
                    }
                }
            }
            .padding(20)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Board")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .mediaFullscreenCover($viewingMedia)
        .task { if case .loading = phase { await load() } }
    }

    // MARK: - Header

    private func header(name: String, detail: Board?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BOARD")
                .font(BrandFont.mono(9)).tracking(1.6)
                .foregroundStyle(BrandColor.textMuted)
            Text(name)
                .font(BrandFont.display(26, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            if let detail {
                Text(metaLine(detail))
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaLine(_ board: Board) -> String {
        var parts: [String] = [countLabel(board.itemCount)]
        parts.append(board.isShared ? "Shared" : "Private")
        if let typeLabel = BoardCatalog.label(for: board.type), board.type.uppercased() != "GENERAL" {
            parts.append(typeLabel)
        }
        return parts.joined(separator: " · ")
    }

    private func countLabel(_ count: Int) -> String {
        "\(count) saved look\(count == 1 ? "" : "s")"
    }

    // MARK: - Looks grid

    @ViewBuilder
    private func looksSection(_ board: Board) -> some View {
        if board.items.isEmpty {
            BrandSurface {
                VStack(spacing: 8) {
                    Text("This board is empty.")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Save looks from the feed to start building it.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                ForEach(board.items) { item in
                    Button {
                        guard let url = item.imageUrl else { return }
                        viewingMedia = FullscreenMedia.remote(id: item.id, urlString: url, isVideo: false)
                    } label: {
                        BoardLookTile(imageUrl: item.imageUrl, caption: item.caption ?? board.name)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.imageUrl == nil)
                }
            }
        }
    }

    // MARK: - Error

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
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Load

    private func load() async {
        phase = .loading
        do {
            let detail = try await session.client.boards.detail(id: board.id)
            phase = .loaded(detail)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this board.")
        }
    }
}

/// The owner-only share controls on a board detail — mirrors the web
/// `BoardShareControls`. Flip Private ⇄ Shared (optimistic PATCH), and once Shared
/// offer the native share sheet for the public `/u/{handle}/boards/{slug}` link.
/// Without a claimed handle, prompt the client to set one up.
private struct BoardShareSection: View {
    @Environment(SessionModel.self) private var session

    let boardId: String
    let slug: String
    let initialVisibility: String
    let handle: String?

    @State private var isShared: Bool
    @State private var busy = false
    @State private var errorText: String?

    init(boardId: String, slug: String, initialVisibility: String, handle: String?) {
        self.boardId = boardId
        self.slug = slug
        self.initialVisibility = initialVisibility
        self.handle = handle
        _isShared = State(initialValue: initialVisibility.uppercased() == "SHARED")
    }

    private var shareURL: URL? {
        guard let handle, !handle.isEmpty else { return nil }
        return URL(string: "https://www.tovis.app/u/\(handle)/boards/\(slug)")
    }

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isShared ? "Shared board" : "Private board")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(isShared
                            ? "Anyone with the link can see this board."
                            : "Only you can see this board.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    visibilityToggle
                }

                if isShared {
                    Divider().overlay(BrandColor.textMuted.opacity(0.15))
                    if let handle, !handle.isEmpty, let shareURL {
                        HStack(spacing: 10) {
                            ShareLink(item: shareURL) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Share link")
                                        .font(BrandFont.body(13, .semibold))
                                }
                                .foregroundStyle(BrandColor.accent)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(BrandColor.accent.opacity(0.10), in: Capsule())
                                .overlay(Capsule().stroke(BrandColor.accent.opacity(0.3), lineWidth: 1))
                            }
                            // See exactly what a recipient sees — the native
                            // `/u/{handle}/boards/{slug}` viewer (viewer.isOwn).
                            NavigationLink {
                                PublicBoardView(handle: handle, slug: slug)
                            } label: {
                                Text("Preview")
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundStyle(BrandColor.textSecondary)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        claimHandlePrompt
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.ember)
                }
            }
        }
    }

    private var visibilityToggle: some View {
        HStack(spacing: 0) {
            toggleButton(title: "Private", selected: !isShared) { setShared(false) }
            toggleButton(title: "Shared", selected: isShared) { setShared(true) }
        }
        .padding(2)
        .background(BrandColor.bgPrimary, in: Capsule())
        .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
        .opacity(busy ? 0.6 : 1)
    }

    private func toggleButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(selected ? BrandColor.onAccent : BrandColor.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(BrandColor.accent) : AnyShapeStyle(Color.clear), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var claimHandlePrompt: some View {
        NavigationLink {
            ClientPublicProfileEditView()
        } label: {
            Text("Claim a public handle to get a shareable link →")
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// Optimistic flip + PATCH; reverts on failure (mirrors the web control).
    private func setShared(_ next: Bool) {
        guard !busy, next != isShared else { return }
        busy = true
        errorText = nil
        isShared = next
        Task {
            defer { busy = false }
            do {
                let updated = try await session.client.boards.updateVisibility(id: boardId, isShared: next)
                isShared = updated.isShared
            } catch let error as APIError {
                isShared = !next
                errorText = error.userMessage
            } catch {
                isShared = !next
                errorText = "Couldn’t update the board."
            }
        }
    }
}

/// One image tile in a board grid — shared by the saved-looks grid and the
/// recommendations row, which differ only in the model they read a URL/caption
/// from (`BoardItem` vs `LooksFeedItem`).
private struct BoardLookTile: View {
    let imageUrl: String?
    let caption: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BrandColor.bgSecondary
            if let imageUrl, let parsed = URL(string: imageUrl) {
                AsyncImage(url: parsed) { $0.resizable().scaledToFill() }
                    placeholder: { ProgressView().tint(BrandColor.accent) }
            }
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .bottom, endPoint: .center
            )
            Text(caption)
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(8)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The owner-only event-date payoff + editor — mirrors the web
/// `BoardEventCountdown`. Shows the "42 days until your wedding" countdown the
/// captured date powers, and keeps the date trivially editable ("the wedding date
/// moves" is the spec's canonical edit case). Renders nothing for a board type
/// that takes no date. Writes via PATCH /api/v1/boards/{id}.
private struct BoardEventCountdownSection: View {
    @Environment(SessionModel.self) private var session

    let boardId: String
    let type: String

    @State private var eventDate: String?
    @State private var draft: Date
    @State private var editing = false
    @State private var busy = false
    @State private var errorText: String?

    init(boardId: String, type: String, initialEventDate: String?) {
        self.boardId = boardId
        self.type = type
        _eventDate = State(initialValue: initialEventDate)
        _draft = State(initialValue: Self.pickerDate(for: initialEventDate))
    }

    /// A stored date opens the picker on itself; no date opens it on today.
    private static func pickerDate(for ymd: String?) -> Date {
        ymd.flatMap { BoardEventDate.date(fromYmd: $0) } ?? Date()
    }

    private var noun: String {
        BoardCatalog.eventNoun(for: type) ?? BoardCatalog.fallbackEventNoun
    }

    var body: some View {
        // nil = this board type has no event date. The call site already gates on
        // that (for VStack spacing), so this is the model staying authoritative
        // over the rule rather than trusting the caller to have checked.
        if let state = BoardEventCountdownState.resolve(type: type, eventDate: eventDate) {
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    if editing {
                        editor
                    } else {
                        summary(state)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.ember)
                    }
                }
            }
        }
    }

    private func summary(_ state: BoardEventCountdownState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(state.text)
                .font(BrandFont.body(13, state.isEmphasized ? .semibold : .regular))
                .foregroundStyle(
                    state.isEmphasized ? BrandColor.textPrimary : BrandColor.textSecondary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { editing = true } label: {
                pillLabel(eventDate == nil ? "Add date" : "Edit date")
            }
            .buttonStyle(.plain)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("", selection: $draft, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(BrandColor.accent)
                .accessibilityLabel(Text("Date of \(noun)"))
                .disabled(busy)

            HStack(spacing: 10) {
                Button { save(BoardEventDate.ymd(from: draft)) } label: {
                    pillLabel(busy ? "Saving…" : "Save")
                }
                .buttonStyle(.plain)
                .disabled(busy)

                if eventDate != nil {
                    Button { save(nil) } label: { pillLabel("Clear") }
                        .buttonStyle(.plain)
                        .disabled(busy)
                }

                Button {
                    editing = false
                    draft = Self.pickerDate(for: eventDate)
                    errorText = nil
                } label: {
                    Text("Cancel")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            .opacity(busy ? 0.6 : 1)
        }
    }

    private func pillLabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(BrandColor.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(BrandColor.bgPrimary, in: Capsule())
            .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
    }

    /// PATCH the date (nil clears), then read back the server's authoritative
    /// value rather than assuming the write landed as sent.
    private func save(_ next: String?) {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                let updated = try await session.client.boards.updateEventDate(
                    id: boardId, eventDate: next
                )
                eventDate = updated.eventDate
                draft = Self.pickerDate(for: updated.eventDate)
                editing = false
            } catch let error as APIError {
                errorText = error.userMessage
            } catch {
                errorText = "Couldn’t update the date."
            }
        }
    }
}

/// "Recommended for this board" — the board-scoped feed (spec §4.4), mirroring the
/// web `BoardRecommendations`. Looks the owner hasn't saved yet, ranked to the
/// board's purpose / answers / saved-look taste. Like web, it stays invisible
/// until it has at least one recommendation, so an empty, brand-new, or failed
/// board shows no empty shell — and a failure is silent by design (a
/// recommendations strip is never worth an error state on someone's own board).
private struct BoardRecommendationsSection: View {
    @Environment(SessionModel.self) private var session

    let boardId: String
    let boardName: String
    /// Tapping a recommendation opens the same fullscreen viewer as the saved-look
    /// grid above it. (Web links these to `/looks` — a placeholder until a look
    /// detail route exists; native already has a viewer, so it uses it.)
    let onOpen: (FullscreenMedia) -> Void

    @State private var items: [LooksFeedItem] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recommended for this board")
                            .font(BrandFont.display(20))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Looks we think fit \(boardName) — you haven’t saved these yet.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        ForEach(items) { item in
                            Button {
                                guard let media = FullscreenMedia.remote(
                                    id: item.id, urlString: item.url, isVideo: item.isVideo
                                ) else { return }
                                onOpen(media)
                            } label: {
                                BoardLookTile(
                                    imageUrl: item.thumbUrl ?? item.url,
                                    caption: caption(for: item)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .task { await load() }
    }

    /// Web parity: a blank caption falls back to the board name (`BoardItem`
    /// already trims its own; the feed model carries the raw string).
    private func caption(for item: LooksFeedItem) -> String {
        guard let trimmed = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return boardName }
        return trimmed
    }

    private func load() async {
        guard items.isEmpty else { return }
        items = (try? await session.client.boards.recommendations(id: boardId)) ?? []
    }
}
