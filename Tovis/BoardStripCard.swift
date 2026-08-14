// The wide board strip, shared by the PUBLIC creator profile and the client's
// OWN boards tab — the native twin of `app/_components/boards/BoardStripCard.tsx`.
//
// A board used to be a square 2×2 mosaic on the owner's side and a strip on the
// public side: the same board reading as two different objects depending on who
// was looking. The only differences the two surfaces get now are the ones that
// are actually different — the owner sees whether a board is shared, and can
// change it.
//
// The treatment is from `Tovis Boards Prep Aftercare.dc.html`, not the profile
// frame's own quadrant sketch: one wide strip of the board's looks with the name
// sitting ON the artwork, scrimmed left-to-right so the label has a dark field
// while the right-hand looks stay bright.
import SwiftUI
import TovisKit

struct BoardStripCard: View {
    let name: String
    let itemCount: Int
    /// Up to four cover tiles; fewer is fine and narrows the strip honestly.
    let tileImageUrls: [String]
    /// Owner surfaces only. On the public profile every listed board is shared by
    /// definition, so a badge there would be true of every row and tell the
    /// visitor nothing.
    var sharedBadge: Bool = false

    // ⚠️ No slot for the owner's switch. This whole card is the label of a
    // NavigationLink, and a control inside a link's label is not its own tap
    // target — tapping it would open the board instead of flipping it. Owner
    // surfaces overlay `BoardVisibilitySwitch` as a SIBLING of the link (see
    // MeView's boards tab), which is the same split web makes.

    var body: some View {
        Color.clear
            .aspectRatio(2.05, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(BrandColor.bgSecondary)
            .overlay {
                // One column per look the board ACTUALLY has, capped at four. A
                // fixed four-cell strip leaves dead cells on a two-look board,
                // which reads as a broken image rather than as a small board.
                HStack(spacing: 0) {
                    ForEach(Array(tileImageUrls.prefix(4).enumerated()), id: \.offset) { _, url in
                        tile(url)
                    }
                }
            }
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: BrandColor.bgPrimary.opacity(0.9), location: 0.28),
                        .init(color: BrandColor.bgPrimary.opacity(0.3), location: 0.7),
                        .init(color: BrandColor.bgPrimary.opacity(0.1), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(BrandFont.display(17, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(itemCount) \(itemCount == 1 ? "LOOK" : "LOOKS")")
                            .font(BrandFont.mono(10)).tracking(1)
                            .foregroundStyle(BrandColor.textSecondary)
                        if sharedBadge {
                            Text("·")
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.textSecondary.opacity(0.5))
                            Text("SHARED")
                                .font(BrandFont.mono(10)).tracking(1)
                                .foregroundStyle(BrandColor.gold)
                        }
                    }
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
            )
    }

    private func tile(_ url: String) -> some View {
        // Same shape as the look card's cover: the photo is an OVERLAY on a
        // flexible cell, never a ZStack sibling. `.scaledToFill()` sizes its own
        // layout, so as a sibling it drove the cell instead of filling it and the
        // strip came out ragged.
        BrandColor.bgPrimary
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if let parsed = URL(string: url) {
                    AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                }
            }
            .clipped()
    }
}

/// The compact private/shared switch that sits on a board strip in the owner's
/// list — so a board can be shared or un-shared without opening it.
///
/// The board detail keeps its fuller panel (which also offers the link to share);
/// both drive the same `PATCH /api/v1/boards/{id}`.
struct BoardVisibilitySwitch: View {
    @Environment(SessionModel.self) private var session

    let boardId: String
    /// Owned by the parent so the strip's SHARED badge follows the switch
    /// immediately; this control owns the request and reverts the binding itself
    /// if the server refuses.
    @Binding var isShared: Bool

    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { toggle() } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isShared ? BrandColor.gold : BrandColor.textSecondary)
                        .frame(width: 5, height: 5)
                    Text(isShared ? "SHARED" : "PRIVATE")
                        .font(BrandFont.mono(9)).tracking(0.7)
                }
                .foregroundStyle(isShared ? BrandColor.gold : BrandColor.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(BrandColor.bgPrimary.opacity(0.75), in: Capsule())
                .overlay(
                    Capsule().stroke(
                        (isShared ? BrandColor.gold : BrandColor.textMuted).opacity(0.35),
                        lineWidth: 1
                    )
                )
                .opacity(busy ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel(isShared ? "Shared board. Make private." : "Private board. Share.")

            if let errorText {
                Text(errorText)
                    .font(BrandFont.body(10, .semibold))
                    .foregroundStyle(BrandColor.ember)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 180, alignment: .trailing)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(BrandColor.bgPrimary.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Optimistic flip + PATCH; reverts on failure (mirrors the web control).
    private func toggle() {
        guard !busy else { return }
        let next = !isShared
        busy = true
        errorText = nil
        isShared = next
        Task {
            defer { busy = false }
            do {
                let updated = try await session.client.boards.updateVisibility(
                    id: boardId, isShared: next
                )
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
