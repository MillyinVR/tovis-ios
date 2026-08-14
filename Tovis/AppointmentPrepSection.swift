// "Before you go" — the appointment-prep screen, native twin of the web
// `app/client/(gated)/bookings/[id]/AppointmentPrepSection.tsx`.
//
// Its own view tree rather than more branches inside BookingDetailView, which is
// already three thousand lines: prep is a whole screen's worth of state (ticks,
// a board disclosure, two write paths) that only exists for a booking the client
// can still get ready for.
//
// Order follows the design and CHANGES SHAPE with how far out the appointment
// is: past a fortnight the countdown shrinks to one quiet line and the board
// card is promoted above the checklist, because the useful thing to do six weeks
// early is send the pro your looks, not tick "arrive with clean hair".
import SwiftUI
import TovisKit

struct AppointmentPrepSection: View {
    @Environment(SessionModel.self) private var session

    let bookingId: String
    let proDisplayName: String
    let prep: ClientBookingPrep
    /// Board ids already handed to the pro for this booking.
    let initialSharedBoardIds: [String]
    /// "Tue, Jul 7 · 10:00 AM" — already formatted in the APPOINTMENT's zone by
    /// the caller, never the device's.
    let whenLabel: String

    // Ticks. Seeded from the wire, then replaced by whatever the SERVER returns
    // from each write — never by the tap. The route re-reads the booking inside
    // its transaction and can refuse (409 PREP_NOT_WRITABLE) if the pro
    // cancelled between render and tap, so adopting the tap would leave a tick
    // on screen that nothing stored.
    @State private var checkedIds: Set<String> = []
    @State private var didSeedChecks = false
    @State private var tickError: String?

    /// Whether the write path would still accept a tick. Starts from the
    /// server's own `writable` and latches false on a refusal, so a client who
    /// gets one refusal isn't invited to collect four more.
    @State private var writableLocal: Bool?

    // The board hand-off.
    @State private var boards: [LooksBoard] = []
    @State private var didLoadBoards = false
    @State private var sharedIds: Set<String> = []
    @State private var confirmingBoard: LooksBoard?
    @State private var boardBusy = false
    @State private var boardError: String?

    private var writable: Bool { writableLocal ?? prep.writable }
    private var isFar: Bool { prep.countdown?.tone == .far }
    private var doneCount: Int { prep.items.filter { checkedIds.contains($0.id) }.count }

    /// Whether there is anything worth drawing — mirrors web's `showPrep`
    /// gate: rows, a note, or a board the client could send.
    ///
    /// Before the boards land we can only answer from what the pro wrote. That
    /// deliberately renders NOTHING for an empty checklist until the fetch
    /// resolves, rather than flashing "Nothing to prep" and then withdrawing
    /// it — the same lazy shape `aftercareCard` already uses.
    private var hasAnythingToShow: Bool {
        if prep.hasContent { return true }
        return didLoadBoards && !boards.isEmpty
    }

    /// An appointment that has already happened has nothing to prepare for; the
    /// care plan is the screen that matters then. A booking can sit in ACCEPTED
    /// past its own time, so the STATUS alone is not this check.
    private var isPast: Bool { prep.countdown?.tone == .past }

    var body: some View {
        Group {
            if hasAnythingToShow && !isPast {
                VStack(alignment: .leading, spacing: 12) {
                    countdownHero

                    // Far out, the board is the useful thing — so it leads.
                    if isFar { boardCard }

                    checklistCard

                    if let note = prep.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !note.isEmpty {
                        noteCard(note)
                    }

                    if !isFar { boardCard }

                    afterAppointmentTeaser
                }
            }
        }
        .task {
            seedChecks()
            await loadBoards()
        }
    }

    // MARK: - Countdown hero

    @ViewBuilder
    private var countdownHero: some View {
        if let countdown = prep.countdown {
            if countdown.tone == .far {
                // One quiet line: six weeks out, a 32pt "In 6 weeks" is shouting.
                BrandSurface {
                    HStack(alignment: .firstTextBaseline) {
                        Text(countdown.label)
                            .font(BrandFont.display(19))
                            .foregroundStyle(BrandColor.textPrimary)
                        Spacer(minLength: 12)
                        Text(whenLabel)
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } else {
                BrandSurface(
                    tint: countdown.tone == .urgent
                        ? BrandColor.gold.opacity(0.12)
                        : BrandColor.bgSurface
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your appointment")
                            .font(BrandFont.mono(10))
                            .tracking(2)
                            .textCase(.uppercase)
                            .foregroundStyle(
                                countdown.tone == .urgent
                                    ? BrandColor.gold
                                    : BrandColor.accent
                            )
                        Text(countdown.label)
                            .font(BrandFont.display(32))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(whenLabel)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Checklist

    @ViewBuilder
    private var checklistCard: some View {
        if prep.items.isEmpty {
            // The pro wrote nothing — very common early on. Say so plainly
            // rather than leaving a heading over blank space.
            //
            // ⚠️ Deliberately carries NO "send board" button: the board card
            // renders with the same call to action, and the design's own frame
            // showed both at once — two doors onto one decision.
            BrandSurface {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nothing to prep")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("\(proDisplayName) hasn’t asked for anything ahead of this one. If you’re unsure about something, just ask.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Before you go")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Spacer()
                        Text("\(doneCount) OF \(prep.items.count) DONE")
                            .font(BrandFont.mono(10))
                            .tracking(1.4)
                            .foregroundStyle(BrandColor.accent)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BrandColor.textMuted.opacity(0.18))
                            Capsule()
                                .fill(BrandColor.accent)
                                .frame(
                                    width: geo.size.width
                                        * (prep.items.isEmpty
                                            ? 0
                                            : CGFloat(doneCount) / CGFloat(prep.items.count))
                                )
                        }
                    }
                    .frame(height: 3)
                    .animation(.easeOut(duration: 0.25), value: doneCount)

                    ForEach(prep.items) { item in checklistRow(item) }

                    if doneCount == prep.items.count {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(BrandColor.accent)
                            Text("You’re ready. Just turn up.")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BrandColor.accent.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    } else if doneCount == 0 && writable {
                        Text("Tap a line as you do it")
                            .font(BrandFont.mono(10))
                            .tracking(1.4)
                            .textCase(.uppercase)
                            .foregroundStyle(BrandColor.textMuted)
                    }

                    if let tickError {
                        Text(tickError)
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.ember)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func checklistRow(_ item: ClientBookingPrepItem) -> some View {
        let isDone = checkedIds.contains(item.id)
        return Button {
            Task { await toggle(item) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isDone ? BrandColor.accent : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                isDone ? BrandColor.accent : BrandColor.textMuted.opacity(0.45),
                                lineWidth: 1
                            )
                    )
                    .overlay {
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(BrandColor.onAccent)
                        }
                    }
                    .frame(width: 22, height: 22)

                Text(item.text)
                    .font(BrandFont.body(13))
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? BrandColor.textMuted : BrandColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!writable)
        .accessibilityAddTraits(isDone ? [.isSelected] : [])
    }

    // MARK: - Note

    private func noteCard(_ note: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 7) {
                Text("Note from \(proDisplayName)")
                    .font(BrandFont.mono(10))
                    .tracking(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(BrandColor.textMuted)
                Text(note)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Send my board

    /// The board to offer: the first not-yet-sent one, else the first sent one
    /// so the card can show its state and offer to take it back. Same rule as
    /// the web card, so the two surfaces pick the same board.
    private var offeredBoard: LooksBoard? {
        boards.first(where: { !sharedIds.contains($0.id) }) ?? boards.first
    }

    @ViewBuilder
    private var boardCard: some View {
        if let board = offeredBoard {
            let isSent = sharedIds.contains(board.id)
            BrandSurface(tint: isFar ? BrandColor.accent.opacity(0.10) : BrandColor.bgSurface) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isFar ? "Send \(proDisplayName) your board" : "Your inspiration board")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)

                    Text(isFar
                        ? "There’s time to change the plan. \(proDisplayName) reads boards before starting."
                        : board.name)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isSent {
                        HStack {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(BrandColor.accent)
                                Text("Sent to \(proDisplayName)")
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                            }
                            Spacer(minLength: 8)
                            // 🔴 Revoking stays available whatever state the
                            // booking reached — the server allows it on a
                            // terminal booking too, because a client must be
                            // able to withdraw a disclosure. So this is NOT
                            // gated on `writable`.
                            Button {
                                Task { await setShare(board, shared: false) }
                            } label: {
                                Text("Take it back")
                                    .font(BrandFont.mono(10))
                                    .tracking(1.4)
                                    .textCase(.uppercase)
                                    .foregroundStyle(BrandColor.textMuted)
                                    .underline()
                            }
                            .disabled(boardBusy)
                        }
                    } else if writable {
                        Button { confirmingBoard = board } label: {
                            Text("Send my board to \(proDisplayName)")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(BrandColor.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(boardBusy)
                    }

                    if let confirmingBoard, confirmingBoard.id == board.id {
                        boardConsent(confirmingBoard)
                    }

                    if let boardError {
                        Text(boardError)
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.ember)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// 🔴 Asks before disclosing, and names what the pro will see — including,
    /// in as many words, that a PRIVATE board stays private. Sending is a scoped
    /// grant, not a visibility change, and a one-tap silent share would be the
    /// wrong shape for that. Same care the media-consent toggle gets.
    private func boardConsent(_ board: LooksBoard) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Send “\(board.name)” to \(proDisplayName)?")
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "\(proDisplayName) will be able to see the looks on this board, for this appointment."
                    + (board.visibility.uppercased() == "PRIVATE"
                        ? " This board is private — sending it here does not make it public, and it stays private to everyone else."
                        : "")
                    + " You can take it back any time."
            )
            .font(BrandFont.body(12))
            .foregroundStyle(BrandColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button { confirmingBoard = nil } label: {
                    Text("Not now")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(BrandColor.textMuted.opacity(0.4), lineWidth: 1)
                        )
                }
                .disabled(boardBusy)

                Button { Task { await setShare(board, shared: true) } } label: {
                    Text(boardBusy ? "Sending…" : "Send it")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(boardBusy)
            }
        }
        .padding(12)
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - After the appointment

    private var afterAppointmentTeaser: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("After the appointment")
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
            Text("Your before & after, care plan, payment and rebook window arrive here when \(proDisplayName) closes out.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .foregroundStyle(BrandColor.textMuted.opacity(0.35))
        )
    }

    // MARK: - Actions

    private func seedChecks() {
        guard !didSeedChecks else { return }
        didSeedChecks = true
        checkedIds = Set(prep.checkedItemIds)
        sharedIds = Set(initialSharedBoardIds)
    }

    private func toggle(_ item: ClientBookingPrepItem) async {
        guard writable else { return }

        let nowChecked = !checkedIds.contains(item.id)
        let previous = checkedIds

        // Optimistic: the box fills on tap and the bar moves, then the server
        // confirms — or refuses, and we roll back to what it actually holds.
        if nowChecked { checkedIds.insert(item.id) } else { checkedIds.remove(item.id) }
        tickError = nil

        do {
            let serverIds = try await session.client.bookings.setPrepCheck(
                bookingId: bookingId, prepItemId: item.id, checked: nowChecked
            )
            checkedIds = Set(serverIds)
        } catch {
            checkedIds = previous
            // The server's own copy — a refusal is copy on every client, not a
            // sentence each platform invents.
            tickError = (error as? APIError)?.userMessage ?? "Could not save that. Try again."
            if case let .server(_, _, code) = error as? APIError, code == "PREP_NOT_WRITABLE" {
                writableLocal = false
            }
        }
    }

    private func loadBoards() async {
        guard !didLoadBoards else { return }
        didLoadBoards = true
        // Best-effort: the board hand-off is one card of the screen, so a
        // failure hides it rather than taking the checklist down with it.
        boards = (try? await session.client.boards.list()) ?? []
    }

    private func setShare(_ board: LooksBoard, shared: Bool) async {
        boardBusy = true
        boardError = nil
        defer { boardBusy = false }

        do {
            let serverIds = try await session.client.bookings.setBoardShare(
                bookingId: bookingId, boardId: board.id, shared: shared
            )
            sharedIds = Set(serverIds)
            confirmingBoard = nil
        } catch {
            boardError = (error as? APIError)?.userMessage
                ?? "Could not send your board. Try again."
            if case let .server(_, _, code) = error as? APIError, code == "PREP_NOT_WRITABLE" {
                writableLocal = false
            }
        }
    }
}
