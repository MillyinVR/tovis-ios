// The camera's one lane — a single fixed-height row above the shutter that
// everything the camera wants to say competes for.
//
// It replaces a stack of fourteen rows that could all co-occur (light-match
// pill, drift nudge, "reading the look…", "enhancing…", the AI direction card,
// the onion controls, an error line, the retry button, the terminal button, the
// clip retry, "saving clip…", the best-shots button, the captured strip, the
// guidance banner). Because they were independent `if`s in a VStack, the shutter
// moved under the pro's thumb every time one appeared.
//
// Two rules make that impossible now:
//
//   1. ONE occupant. `CameraLane.message(_:)` is a pure function from the whole
//      camera state to at most one line — the highest-priority thing worth
//      saying. Everything below it loses the lane and waits.
//   2. FIXED height. `CameraLane.height` is reserved whether or not anything is
//      speaking, so the shutter and Done never shift.
//
// Background work (uploading, reading a look, AI enhance, saving a clip) never
// takes the lane at all: the pro can't act on it, so it draws as a hairline
// along the lane's top edge instead of taking the words.
import SwiftUI

/// The three meanings the camera has, and no more. Accent = shooting, warn =
/// one thing to fix, alert = something needs a decision. Neutral is the step
/// hint, which is information rather than a judgement.
enum LaneTone: Equatable {
    case accent, warn, alert, neutral

    /// The token this tone paints with. `.amber` (not `.gold`) is the semantic
    /// warn token; they resolve to the same value but say different things.
    var color: Color {
        switch self {
        case .accent: return BrandColor.accent
        case .warn: return BrandColor.amber
        case .alert: return BrandColor.ember
        case .neutral: return BrandColor.textSecondary
        }
    }
}

/// The trailing action word on a lane row. Only the rows that need a tap have
/// one; the coach line is not a button, it's a sentence.
struct LaneAction: Equatable {
    let label: String
    let kind: Kind

    enum Kind: Equatable {
        /// Photos the connection dropped — worth another tap.
        case retryUploads
        /// Photos the server refused — needs a keep-or-drop decision.
        case terminalOptions
        /// Auto-harvested best shots waiting on review.
        case reviewBestShots
        /// The light moved away from the card calibration — re-scan.
        case recalibrate
        /// This room's condition isn't the pro's to fix — retire the tip here
        /// (camera plan P4.1, `CoachRoomMemory`). The only action word that
        /// rides on the COACH row rather than replacing it, because the tip it
        /// answers is the thing being agreed with.
        case dismissRoomTip
        /// …and the way back out of it, for as long as the confirmation is on
        /// screen. A dismissal is permanent and one tap deep; this is the
        /// misfire escape, not a second standing control.
        case undoRoomDismissal
    }
}

/// What the lane is saying right now. Exactly one of these exists at a time.
struct LaneMessage: Equatable {
    let text: String
    let tone: LaneTone
    var action: LaneAction? = nil
    /// A trailing counter ("1/5") — the step row's progress, not an action.
    var trailing: String? = nil
    /// Swipe up (or double-tap under VoiceOver) opens the seven dimensions.
    /// False on the failure rows: they aren't a coaching read.
    var expandable: Bool = false
    /// The leading state dot. Off for the step row, which reads as a title.
    var showsDot: Bool = true
    /// The dot breathes while the pro is being asked to change something.
    var pulses: Bool = false
}

/// The lane's priority queue, as a pure function so the ordering is testable
/// without a camera, a coach, or a running app.
enum CameraLane {
    /// Reserved height, in points. Fixed on purpose — see the file header.
    static let height: CGFloat = 56

    // MARK: - Geometry the sentence has to live inside
    //
    // Named rather than spelled inline in `CameraLaneView` so a test can
    // measure the coach's longest REAL sentence against the real lane instead
    // of against a second copy of these numbers. A line that reads well in a
    // string literal and loses its tail on a phone is not shipped — see
    // `CameraLaneLineFitTests`.

    /// The lane's inset from the screen edge.
    static let outerInset: CGFloat = 18
    /// The row capsule's inset from the lane.
    static let rowInset: CGFloat = 16
    /// Gap between the state dot, the sentence, and whatever trails it.
    static let itemSpacing: CGFloat = 12
    /// The leading state dot.
    static let dotSize: CGFloat = 9
    /// The sentence's type size, the floor SwiftUI may scale it to before it
    /// starts dropping words instead, and how many lines it may wrap onto.
    static let textPointSize: CGFloat = 16.5
    static let minimumTextScale: CGFloat = 0.72
    static let maxTextLines = 2

    /// How long a transient (a step change, a light-match confirmation) holds
    /// the lane before it falls through to the coach tip.
    static let transientSeconds: Double = 2

    /// The room-memory offer's one word. Named rather than spelled inline
    /// because `CameraLaneLineFitTests` has to measure the coach's sentence
    /// against the room this REAL word leaves it — an action button is far
    /// wider than the expand chevron it replaces, and a second copy of the
    /// label in the test would measure the wrong row.
    static let dismissRoomTipLabel = "GOT IT"
    /// The undo offered alongside the confirmation, measured the same way.
    static let undoRoomDismissalLabel = "UNDO"

    /// Everything the lane arbitrates between. Assembled by the view each frame;
    /// nothing here reaches back into SwiftUI.
    struct Inputs: Equatable {
        /// Photos the server refused (retrying re-fails) — needs a decision.
        var terminalCount = 0
        /// Photos still owed to the server — worth a tap.
        var retryableCount = 0
        /// Clips still owed to the server.
        var failedClipCount = 0
        /// Auto-harvested best shots the pro hasn't reviewed.
        var bestShotCount = 0
        /// The card calibration's light has drifted and hasn't been dealt with.
        var lightDrifted = false
        /// A light-match confirmation/correction inside its transient window.
        var lightTransient: (text: String, ok: Bool)?
        /// The current step's hint, inside its 2s window after a step change.
        var stepTransient: String?
        /// Where the pro is in the guide — the step row's trailing counter.
        var stepProgress: (index: Int, total: Int)?
        /// The whole guided set is captured and the pro dismissed the card.
        var setComplete = false
        /// The coach reads the frame as good to shoot.
        var isReady = false
        /// The coach's single prioritized fix, already phrased as an instruction
        /// (Calm Mentor / canonical text — the fallback if `coachTipMoment`
        /// has no override in the active voice).
        var coachTip: String?
        /// The moment `coachTip` renders through, so the active `CoachVoice`
        /// can re-phrase it. Nil when there's no tip, or when the caller
        /// (tests, previews) doesn't set one — `message(_:)` then just shows
        /// `coachTip` verbatim, same as before personalities existed.
        var coachTipMoment: CoachMoment?
        var coachTipPhraseCtx: CoachPhraseContext?
        /// The current shot's how-to, the resting line when the coach is quiet.
        var stepHint: String?
        /// The current step's title + hint, for rendering `stepTransient`/
        /// `stepHint` through the active `CoachVoice` (`.shotStepHint`, docs/
        /// design/camera-personality-packs.md §4 site G). Nil when there's no
        /// current step — `message(_:)` then shows `stepTransient`/`stepHint`
        /// verbatim, same as before personalities existed.
        var stepPhraseCtx: CoachPhraseContext?
        /// A hard failure worth words — a capture that didn't happen, a spill
        /// that couldn't be kept. Not background work.
        var errorText: String?
        /// The standing disclosure while a reference photo is being read by
        /// Claude. This is the ONE moment bytes leave the device, so it gets
        /// words — the hairline rule for background work does not apply to a
        /// privacy disclosure, which exists precisely to be read.
        var aiDisclosure: String?
        /// There are dimensions to show, so the swipe-up affordance is real.
        var hasDimensions = false
        /// The coach tip on screen is a room condition this pro has met often
        /// enough at THIS location to be offered a way to retire it
        /// (`CoachRoomMemory`). Adds one trailing word to the coach row; it
        /// never changes which row wins the lane.
        var coachTipDismissible = false
        /// The confirmation of a tip the pro just retired, inside its
        /// transient window. Already rendered in the pro's voice by
        /// `CoachEngine.dismissRoomTip()` — shown verbatim, so the flourish
        /// isn't applied twice.
        var roomTipDismissed: String?
        /// Whether that confirmation still has a tip to put back — false once
        /// the undo has been taken, so the row can't offer it twice.
        var roomTipDismissalUndoable = false

        // Equatable by hand: the optional tuples above aren't Equatable for free.
        static func == (a: Inputs, b: Inputs) -> Bool {
            a.terminalCount == b.terminalCount
                && a.retryableCount == b.retryableCount
                && a.failedClipCount == b.failedClipCount
                && a.bestShotCount == b.bestShotCount
                && a.lightDrifted == b.lightDrifted
                && a.lightTransient?.text == b.lightTransient?.text
                && a.lightTransient?.ok == b.lightTransient?.ok
                && a.stepTransient == b.stepTransient
                && a.stepProgress?.index == b.stepProgress?.index
                && a.stepProgress?.total == b.stepProgress?.total
                && a.setComplete == b.setComplete
                && a.isReady == b.isReady
                && a.coachTip == b.coachTip
                && a.coachTipMoment == b.coachTipMoment
                && a.coachTipPhraseCtx == b.coachTipPhraseCtx
                && a.stepHint == b.stepHint
                && a.stepPhraseCtx == b.stepPhraseCtx
                && a.errorText == b.errorText
                && a.aiDisclosure == b.aiDisclosure
                && a.hasDimensions == b.hasDimensions
                && a.coachTipDismissible == b.coachTipDismissible
                && a.roomTipDismissed == b.roomTipDismissed
                && a.roomTipDismissalUndoable == b.roomTipDismissalUndoable
        }
    }

    /// The single highest-priority thing worth saying, in the spec's order:
    ///
    ///   1. terminal failure — needs a decision
    ///   2. retryable failure — needs a tap
    ///   3. set complete / best shots ready
    ///   4. light drifted / light matched
    ///   5. step changed — the hint, briefly
    ///   6. the coach tip — the resting state
    ///
    /// Returns nil when the camera genuinely has nothing to say; the lane keeps
    /// its height and draws empty.
    ///
    /// `voice` renders the personality-tagged lines (§2.2 of the design doc);
    /// it defaults to Calm Mentor so every existing caller — tests, previews —
    /// keeps seeing exactly today's text without passing anything new.
    static func message(_ i: Inputs, voice: CoachVoice = CalmMentorVoice()) -> LaneMessage? {
        // 1 — the server refused these bytes. No retry: it can never work.
        if i.terminalCount > 0 {
            return LaneMessage(
                text: i.terminalCount == 1
                    ? "1 photo can’t be saved here"
                    : "\(i.terminalCount) photos can’t be saved here",
                tone: .alert,
                action: LaneAction(label: "OPTIONS", kind: .terminalOptions)
            )
        }
        // 2 — owed to the server, and a tap is worth making. Named by CAUSE so
        // the pro can tell it from the refusal above: this one gets better when
        // the signal does.
        let owed = i.retryableCount + i.failedClipCount
        if owed > 0 {
            return LaneMessage(
                text: owed == 1 ? "1 photo waiting on signal"
                                : "\(owed) photos waiting on signal",
                tone: .alert,
                action: LaneAction(label: "RETRY", kind: .retryUploads)
            )
        }
        // A capture that didn't happen is a failure with words, not background
        // work — it outranks coaching but not the queues above.
        if let error = i.errorText {
            return LaneMessage(text: error, tone: .warn, pulses: true)
        }
        // The one moment a photo leaves the device. It is NOT background work:
        // the hairline rule exists because the pro can't act on progress, and a
        // disclosure is the opposite — it exists to be read while it's true.
        if let disclosure = i.aiDisclosure {
            return LaneMessage(text: disclosure, tone: .neutral, showsDot: false)
        }
        // 3 — the set landed. Both readings of "there's something to review".
        if i.bestShotCount > 0 {
            return LaneMessage(
                text: i.bestShotCount == 1 ? "1 keeper from that burst"
                                           : "\(i.bestShotCount) keepers from that burst",
                tone: .accent,
                action: LaneAction(label: "REVIEW", kind: .reviewBestShots)
            )
        }
        // 4 — the room's light moved out from under the calibration. This one
        // persists rather than expiring: it carries an action, and dropping an
        // actionable warning after two seconds would be a regression on what
        // the drift pill already did.
        if i.lightDrifted {
            return LaneMessage(
                text: CoachVoiceRenderer.renderCanonical(.laneCalibrationDrift, voice: voice),
                tone: .warn,
                action: LaneAction(label: "FIX", kind: .recalibrate),
                pulses: true
            )
        }
        // The coach answering the pro's own tap — a confirmation, so it
        // expires the same way. It outranks the coaching line underneath it on
        // purpose: the tip it is about is the thing that just went away, and a
        // dismissal with no visible answer reads as a control that did nothing.
        if let dismissed = i.roomTipDismissed {
            return LaneMessage(
                text: dismissed, tone: .accent,
                action: i.roomTipDismissalUndoable
                    ? LaneAction(label: undoRoomDismissalLabel, kind: .undoRoomDismissal)
                    : nil,
                expandable: i.hasDimensions)
        }
        // …and the before/after light match, which is a confirmation, so it
        // expires (the view only supplies it inside its transient window).
        if let light = i.lightTransient {
            return LaneMessage(text: light.text, tone: light.ok ? .accent : .warn,
                               expandable: i.hasDimensions, pulses: !light.ok)
        }
        // 5 — the shot just changed; say what it is, then get out of the way.
        if let hint = i.stepTransient {
            let rendered = CoachVoiceRenderer.render(
                .shotStepHint, fallback: hint, ctx: i.stepPhraseCtx ?? CoachPhraseContext(), voice: voice) ?? hint
            return LaneMessage(
                text: rendered,
                tone: .neutral,
                trailing: i.stepProgress.map { "\($0.index + 1)/\($0.total)" },
                expandable: i.hasDimensions,
                showsDot: false
            )
        }
        // 6 — the resting state. Instructions, never scores.
        if i.setComplete {
            return LaneMessage(text: CoachVoiceRenderer.renderCanonical(.laneSetComplete, voice: voice),
                               tone: .accent, expandable: i.hasDimensions)
        }
        if i.isReady {
            return LaneMessage(text: CoachVoiceRenderer.renderCanonical(.laneHoldShooting, voice: voice),
                               tone: .accent, expandable: i.hasDimensions)
        }
        if let tip = i.coachTip {
            let rendered = CoachVoiceRenderer.render(
                i.coachTipMoment, fallback: tip, ctx: i.coachTipPhraseCtx ?? CoachPhraseContext(), voice: voice) ?? tip
            return LaneMessage(
                text: rendered, tone: .warn,
                // The offer only ever ADDS a word to a line the coach had
                // already decided to say — it can't put a row on the lane, and
                // it can't take one off.
                action: i.coachTipDismissible
                    ? LaneAction(label: dismissRoomTipLabel, kind: .dismissRoomTip)
                    : nil,
                expandable: i.hasDimensions, pulses: true)
        }
        if let hint = i.stepHint {
            let rendered = CoachVoiceRenderer.render(
                .shotStepHint, fallback: hint, ctx: i.stepPhraseCtx ?? CoachPhraseContext(), voice: voice) ?? hint
            return LaneMessage(text: rendered, tone: .neutral,
                               expandable: i.hasDimensions, showsDot: false)
        }
        return nil
    }

    /// The whole coaching picture in one utterance, for the collapsed line's
    /// VoiceOver value. The pills carried this visually; losing them must not
    /// lose the information, so the summary names the weakest fundamental and
    /// how many are good before it repeats the spoken instruction.
    static func accessibilityValue(message: LaneMessage?, statuses: [CoachStatus]) -> String {
        var parts: [String] = []
        if !statuses.isEmpty {
            let good = statuses.filter { $0.message == nil }.count
            if let worst = statuses.filter({ $0.message != nil }).min(by: { $0.score < $1.score }) {
                parts.append("\(worst.category.spokenName) needs work.")
            }
            parts.append("\(good) of \(statuses.count) good.")
        }
        if let message { parts.append(message.text) }
        return parts.isEmpty ? "Nothing to fix" : parts.joined(separator: " ")
    }
}

extension CoachCategory {
    /// The pills' short label, kept for the expanded dimensions drawer.
    var shortLabel: String {
        switch self {
        case .lighting: return "LIGHT"
        case .color: return "COLOR"
        case .level: return "LEVEL"
        case .composition: return "FRAME"
        case .sharpness: return "FOCUS"
        case .background: return "CLEAN"
        case .pose: return "POSE"
        }
    }
}

// MARK: - The lane view

/// The lane itself: one row, fixed height, one occupant.
struct CameraLaneView: View {
    let message: LaneMessage?
    /// Background work in flight (upload, look analysis, AI enhance, clip save)
    /// — drawn as a hairline along the top edge, never as words.
    let backgroundBusy: Bool
    let onAction: (LaneAction.Kind) -> Void
    let onExpand: () -> Void
    /// The whole coaching read, spoken — see `CameraLane.accessibilityValue`.
    let accessibilityValue: String

    @State private var pulsing = false

    var body: some View {
        // The height is reserved whether or not anything is speaking, so the
        // shutter below never moves.
        ZStack {
            if let message {
                row(message)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(height: CameraLane.height)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CameraLane.outerInset)
        .animation(.easeOut(duration: 0.18), value: message)
    }

    private func row(_ message: LaneMessage) -> some View {
        HStack(spacing: CameraLane.itemSpacing) {
            if message.showsDot {
                Circle()
                    .fill(message.tone.color)
                    .frame(width: CameraLane.dotSize, height: CameraLane.dotSize)
                    .opacity(message.pulses && pulsing ? 1 : 0.55)
                    .animation(message.pulses
                               ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                               : .default,
                               value: pulsing)
            }
            // 16.5pt is the design's size and the reason the line reads on a
            // tripod at arm's length — but the coach's own longest instruction
            // ("Light's behind them — turn them to face the window", 49 chars)
            // does not fit one line beside an action word. Wrapping to two and
            // scaling down keeps the whole sentence: a coaching instruction
            // that loses its tail is worse than one rendered a point smaller.
            Text(message.text)
                .font(BrandFont.display(CameraLane.textPointSize, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .lineLimit(CameraLane.maxTextLines)
                .minimumScaleFactor(CameraLane.minimumTextScale)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let action = message.action {
                Button { onAction(action.kind) } label: {
                    Text(action.label)
                        .font(BrandFont.mono(11))
                        .tracking(0.8)
                        .foregroundStyle(message.tone.color)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(message.tone.color.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            } else if let trailing = message.trailing {
                Text(trailing)
                    .font(BrandFont.mono(11))
                    .foregroundStyle(BrandColor.textMuted)
            } else if message.expandable {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(BrandColor.textPrimary.opacity(0.5))
            }
        }
        .padding(.horizontal, CameraLane.rowInset)
        // Tight enough that two scaled lines still fit the fixed 56pt lane.
        .padding(.vertical, 9)
        .background(BrandColor.bgPrimary.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(message.tone.color.opacity(0.42), lineWidth: 1)
        )
        // Background work is a hairline on the lane's top edge — no words,
        // because there is nothing for the pro to do about it.
        .overlay(alignment: .top) {
            if backgroundBusy {
                Capsule()
                    .fill(BrandColor.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 22)
                    .opacity(pulsing ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: pulsing)
            }
        }
        // The collapsed line carries the whole picture in ONE utterance — the
        // seven pills' information, not just the sentence that replaced them.
        .contentShape(Rectangle())
        .onAppear { pulsing = true }
        .onTapGesture { if message.expandable { onExpand() } }
        .gesture(
            DragGesture(minimumDistance: 18).onEnded { value in
                if message.expandable, value.translation.height < -18 { onExpand() }
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shot coach")
        .accessibilityValue(accessibilityValue)
        // Still accurate on the coach row when it also carries the
        // room-memory offer: a double-tap does open the seven, and the action
        // word is reached through the actions rotor (`children: .combine`
        // keeps a child Button's action), exactly as RETRY / OPTIONS / FIX
        // already are.
        .accessibilityHint(message.expandable ? "Double-tap for all seven" : "")
    }
}
