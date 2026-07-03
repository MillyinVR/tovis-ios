// Save a look to one of your boards — the native take on the web SaveToBoardModal.
// Loads the viewer's boards + current save state, then toggles membership per
// board (POST/DELETE /looks/{id}/save). Boards themselves are created on the web
// for now; if you have none, this points you there.
import SwiftUI
import TovisKit

struct SaveToBoardSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let lookId: String
    /// Reports every authoritative save-state change back to the presenting
    /// surface (the feed rail keeps its bookmark tint in sync).
    var onStateChange: ((LooksSaveState) -> Void)? = nil

    @State private var state: LooksSaveState?
    @State private var loading = true
    @State private var loadError: String?
    @State private var working: Set<String> = []   // board ids mid-flight

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().tint(BrandColor.accent).frame(maxHeight: .infinity)
                } else if let loadError {
                    message(loadError, retry: true)
                } else if let state, state.boards.isEmpty {
                    message("You don’t have any boards yet. Create one on tovis.app, then save looks to it here.", retry: false)
                } else if let state {
                    boardList(state)
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
    }

    private func boardList(_ state: LooksSaveState) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(state.boards) { board in
                    let saved = state.boardIds.contains(board.id)
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
        loading = true; loadError = nil
        defer { loading = false }
        do {
            state = try await session.client.looks.saveState(lookId: lookId)
            if let state { onStateChange?(state) }
        } catch let error as APIError {
            loadError = error.userMessage
        } catch {
            loadError = "Couldn’t load your boards."
        }
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
