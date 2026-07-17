// Save a look to one of your boards — the native take on the web SaveToBoardModal.
// Loads the viewer's FULL board list (GET /boards) for the picker rows AND this
// look's save state (GET /looks/{id}/save) for the checkmarks — web loads both,
// because the save-state's own `boards` field is only the boards ALREADY holding
// this look, never the full list. Toggling membership is POST/DELETE
// /looks/{id}/save. "Create a board" opens the native CreateBoardView and drops
// this look straight into the new one (web parity).
import SwiftUI
import TovisKit

struct SaveToBoardSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let lookId: String
    /// Reports every authoritative save-state change back to the presenting
    /// surface (the feed rail keeps its bookmark tint in sync).
    var onStateChange: ((LooksSaveState) -> Void)? = nil

    /// This look's save state — `isSaved`/`saveCount` + which boards already
    /// contain it (`boardIds`). NOT the full board list; that's `boards` below.
    @State private var state: LooksSaveState?
    /// The viewer's full board list — the picker rows (GET /boards).
    @State private var boards: [LooksBoard] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var working: Set<String> = []   // board ids mid-flight
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().tint(BrandColor.accent).frame(maxHeight: .infinity)
                } else if let loadError {
                    message(loadError, retry: true)
                } else if boards.isEmpty {
                    emptyState
                } else {
                    boardList
                }
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Save to board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(BrandColor.accent)
                }
            }
        }
        .tint(BrandColor.accent)
        .task { await load() }
        .sheet(isPresented: $showCreate) {
            CreateBoardView { board in
                Task { await boardCreated(board) }
            }
        }
    }

    private var boardList: some View {
        ScrollView {
            VStack(spacing: 10) {
                createBoardButton
                ForEach(boards) { board in
                    let saved = state?.boardIds.contains(board.id) ?? false
                    Button { Task { await toggle(board, saved: saved) } } label: {
                        BrandSurface {
                            HStack(spacing: 12) {
                                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                                    .foregroundStyle(saved ? BrandColor.accent : BrandColor.textMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(board.name)
                                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                    Text(board.visibility.capitalized)
                                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                                }
                                Spacer()
                                if working.contains(board.id) {
                                    ProgressView().controlSize(.small).tint(BrandColor.accent)
                                } else if saved {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(BrandColor.emerald)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(working.contains(board.id))
                }
            }
            .padding(18)
        }
    }

    // Opens the native board-creation flow. Presented from both the empty state
    // and the top of the populated list (mirrors web's prominent "Create new
    // board" affordance).
    private var createBoardButton: some View {
        Button { showCreate = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                Text("Create a board").font(BrandFont.body(14, .semibold))
            }
            .foregroundStyle(BrandColor.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.accent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("You don’t have any boards yet. Create one here, then save looks to it.")
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            createBoardButton.frame(maxWidth: 260)
        }
        .padding(40).frame(maxHeight: .infinity)
    }

    private func message(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("Try again") { Task { await load() } }
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
        }
        .padding(40).frame(maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await refresh()
    }

    // Fetches the picker rows (the full board list) and this look's save state,
    // publishing both only on full success — a partial failure keeps the prior
    // view and surfaces a retry. Web loads the same two sources.
    private func refresh() async {
        do {
            let fetchedBoards = try await session.client.boards.list()
            let fetchedState = try await session.client.looks.saveState(lookId: lookId)
            boards = fetchedBoards
            state = fetchedState
            loadError = nil
            onStateChange?(fetchedState)
        } catch let error as APIError {
            loadError = error.userMessage
        } catch {
            loadError = "Couldn’t load your boards."
        }
    }

    // Mirror web's "Create and save": drop this look into the freshly created
    // board, then refresh the picker so the new board shows as a saved row. If the
    // save itself fails the board was still created — the refresh surfaces it
    // (unsaved) so the user can tap it.
    private func boardCreated(_ board: Board) async {
        do {
            _ = try await session.client.looks.setSaved(lookId: lookId, boardId: board.id, saved: true)
        } catch {
            // Board created; the refresh below still surfaces it.
        }
        await refresh()
    }

    private func toggle(_ board: LooksBoard, saved: Bool) async {
        guard !working.contains(board.id) else { return }
        working.insert(board.id)
        defer { working.remove(board.id) }
        do {
            state = try await session.client.looks.setSaved(lookId: lookId, boardId: board.id, saved: !saved)
            if let state { onStateChange?(state) }
        } catch {
            // leave state as-is; the row reflects the last known truth
        }
    }
}
