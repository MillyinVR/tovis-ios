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
                    looksSection(detail)
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
                        lookTile(item, boardName: board.name)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.imageUrl == nil)
                }
            }
        }
    }

    private func lookTile(_ item: BoardItem, boardName: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            BrandColor.bgSecondary
            if let url = item.imageUrl, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { $0.resizable().scaledToFill() }
                    placeholder: { ProgressView().tint(BrandColor.accent) }
            }
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .bottom, endPoint: .center
            )
            Text(item.caption ?? boardName)
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(8)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
