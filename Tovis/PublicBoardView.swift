// Native public board viewer — the counterpart to the web
// `/u/[handle]/boards/[slug]` page (app/u/[handle]/boards/[slug]/page.tsx), which
// is RSC-only, so this reads the paired JSON route GET /api/v1/u/{handle}/boards/
// {slug} via PublicBoardService. Reached two ways:
//
//   • a tapped `https://…/u/{handle}/boards/{slug}` Universal Link (the share link
//     BoardDetailView generates) — presented over the shell from RootView, and
//   • the owner's own "Preview public board" control on BoardShareSection.
//
// Renders a read-only board: owner @handle + avatar (linking back to the public
// creator profile when it's public), the board name + look count, and a grid of
// the board's published looks (tap → fullscreen). A 404 (board isn't shared / was
// hidden / doesn't resolve) is a plain "not found" empty state, not an error.
import SwiftUI
import TovisKit

struct PublicBoardView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let handle: String
    let slug: String

    private enum Phase {
        case loading
        case loaded(PublicBoard)
        /// The board doesn't resolve, isn't shared, or was hidden.
        case notFound
        case failed(String)
    }
    @State private var phase: Phase = .loading
    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                            .padding(.top, 70)
                    case let .loaded(board):
                        ownerHeader(board)
                        boardHeader(board)
                        looksSection(board)
                    case .notFound:
                        notFoundState
                    case let .failed(message):
                        failedState(message)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .background(BrandColor.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .mediaFullscreenCover($viewingMedia)
        .task { if case .loading = phase { await load() } }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(BrandColor.bgSurface, in: Circle())
                    .overlay(Circle().stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text(titleText)
                .font(BrandFont.display(18, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var titleText: String {
        if case let .loaded(board) = phase { return board.boardName }
        return "Board"
    }

    // MARK: - Owner + board headers

    @ViewBuilder
    private func ownerHeader(_ board: PublicBoard) -> some View {
        // The web page links the owner header back to /u/{handle} only when that
        // profile is public; otherwise it's a static row.
        if board.ownerProfilePublic {
            NavigationLink {
                PublicClientViewerView(handle: board.handle)
            } label: {
                ownerRow(board)
            }
            .buttonStyle(.plain)
        } else {
            ownerRow(board)
        }
    }

    private func ownerRow(_ board: PublicBoard) -> some View {
        HStack(spacing: 10) {
            avatar(board.ownerAvatarUrl)
            Text("@\(board.handle)")
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            if board.ownerProfilePublic {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrandColor.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    private func avatar(_ urlString: String?) -> some View {
        ZStack {
            Circle().fill(BrandColor.bgSecondary)
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() }
                    placeholder: { ProgressView().tint(BrandColor.accent) }
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay(Circle().stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1))
    }

    private func boardHeader(_ board: PublicBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BOARD")
                .font(BrandFont.mono(9)).tracking(1.6)
                .foregroundStyle(BrandColor.textMuted)
            Text(board.boardName)
                .font(BrandFont.display(26, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(countLabel(board.looks.count))
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countLabel(_ count: Int) -> String {
        "\(count) look\(count == 1 ? "" : "s")"
    }

    // MARK: - Looks grid

    @ViewBuilder
    private func looksSection(_ board: PublicBoard) -> some View {
        if board.looks.isEmpty {
            BrandSurface {
                VStack(spacing: 8) {
                    Text("This board is empty.")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("There aren’t any public looks on this board yet.")
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
                ForEach(board.looks) { look in
                    Button {
                        guard let url = look.imageUrl else { return }
                        viewingMedia = FullscreenMedia.remote(id: look.id, urlString: url, isVideo: false)
                    } label: {
                        lookTile(look)
                    }
                    .buttonStyle(.plain)
                    .disabled(look.imageUrl == nil)
                }
            }
        }
    }

    private func lookTile(_ look: PublicBoardLook) -> some View {
        ZStack(alignment: .bottomLeading) {
            BrandColor.bgSecondary
            if let url = look.imageUrl, let parsed = URL(string: url) {
                // Focal-aware cover crop (camera C6c); null focal → centered fill.
                FocalCoverImage(url: parsed, focal: look.focalPoint) {
                    ProgressView().tint(BrandColor.accent)
                }
            }
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .bottom, endPoint: .center
            )
            Text(look.name)
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(8)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Empty / failed states

    private var notFoundState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("Board not found").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("This board isn’t shared, or the link is no longer available.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
        }
        .padding(.top, 20)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: - Load

    private func load() async {
        phase = .loading
        do {
            if let board = try await session.client.publicBoard.board(handle: handle, slug: slug) {
                phase = .loaded(board)
            } else {
                phase = .notFound
            }
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this board.")
        }
    }
}
