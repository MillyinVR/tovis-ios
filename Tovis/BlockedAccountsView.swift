// "Blocked accounts" — the native twin of the web
// `/client/settings/blocked` panel, required by App Store guideline 1.2.
//
// A block is durable and it is the user's own decision, so there has to be a
// place to see and lift it. A block with no way back is its own problem, not a
// safety feature.
//
// Lists only blocks the viewer MADE. Blocks RECEIVED also hide content — the
// server's filter is symmetric — but surfacing them would tell the viewer who
// blocked them, which is exactly what a block exists to withhold.
import SwiftUI
import TovisKit

struct BlockedAccountsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase: Equatable {
        case loading
        case loaded([BlockedAccount])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// Re-entrancy guard per row, so a double-tap can't fire two unblocks.
    @State private var unblockInFlight: Set<String> = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)

                case let .failed(message):
                    BrandSurface {
                        Text(message)
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.ember)
                    }

                case let .loaded(blocks):
                    if blocks.isEmpty {
                        BrandSurface {
                            Text("You haven’t blocked anyone. When you block someone, you won’t see their looks or comments and they won’t see yours.")
                                .font(BrandFont.body(14))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(blocks) { block in
                                row(block)
                            }
                        }
                    }
                }

                if let error {
                    Text(error)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                }
            }
            .padding(16)
        }
        .navigationTitle("Blocked accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        Text("Blocking is mutual: you won’t see their looks or comments, and they won’t see yours.")
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textSecondary)
    }

    private func row(_ block: BlockedAccount) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.displayName)
                        .font(BrandFont.body(14).weight(.semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    // Suppressed when it would just repeat displayName.
                    if let handle = block.handleLabel {
                        Text(handle)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(unblockInFlight.contains(block.blockId) ? "Unblocking…" : "Unblock") {
                    Task { await unblock(block) }
                }
                .font(BrandFont.body(13).weight(.semibold))
                .disabled(unblockInFlight.contains(block.blockId))
            }
        }
    }

    private func load() async {
        phase = .loading
        error = nil
        do {
            phase = .loaded(try await session.client.blocks.blockedAccounts())
        } catch {
            phase = .failed("Couldn’t load your blocked accounts. Try again.")
        }
    }

    /// Removes the row only after the server confirms. An optimistic removal
    /// here would tell the viewer someone is unblocked when they may not be —
    /// the same reason the feed's block is not optimistic either.
    private func unblock(_ block: BlockedAccount) async {
        guard !unblockInFlight.contains(block.blockId) else { return }
        unblockInFlight.insert(block.blockId)
        defer { unblockInFlight.remove(block.blockId) }

        error = nil
        do {
            _ = try await session.client.blocks.unblock(blockId: block.blockId)
        } catch {
            self.error = "Couldn’t unblock this account. Try again."
            return
        }

        if case let .loaded(current) = phase {
            phase = .loaded(current.filter { $0.blockId != block.blockId })
        }
    }
}
