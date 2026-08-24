// What the coach knows about THIS room, in its own lines (camera plan P4.2,
// the wording half).
//
// `CoachStationRead` decides WHAT the coach learned at setup; this is where
// that knowledge reaches the pro's eyes and ears. SAME CONTRACT AS
// `LookDirectionScript` (#974), `CoachBookingVocabulary` (#358) and
// `CoachPlainLine` (#360), deliberately: this only ever REPLACES the words of
// a correction the coach has already decided to give, applied in
// `CoachEngine.apply` and nowhere else — never in `ShotCoach`, so every pinned
// `CoachReadinessTests` assertion and the offline tuning bench keep measuring
// exactly today's canonical text. It cannot make the coach speak more often,
// sooner, or about something else.
//
// The `CoachMoment` is KEPT, same as #358/#360 and for the same reason — so
// the room's words reach Calm Mentor (the default voice) and a pro on one of
// the four PACKS keeps their pack's own line. Teaching the packs the room's
// vocabulary is the same recorded follow-up as #358's
// (docs/design/camera-personality-packs.md §2.1), not a silent side effect.
//
// Precedence in `CoachEngine.apply`: booking vocabulary first, then this (it
// overrides the booking's entry only where it has one, and names the client
// itself where the line is about them), then a look line replaces everything,
// then the back-off's plain form wins while simplified — the coach stripping
// a line down is not the moment to grow it a room clause.
//
// ⚠️ No line here ever says which SIDE the window is on. The read knows the
// side, but only from where the pro stood at setup — mid-shoot the coach
// cannot know which way they are facing, and "the window's on your left" said
// to a pro shooting from the other side of the chair is confidently wrong
// advice, the one thing the north star rules out ahead of everything else.
// The lines claim only the invariants the read measured: the room HAS a
// window worth using, and what its ambient light reads as. (The side is
// spoken on the position-anchored surfaces — the setup confirmation and the
// hub row — where the pro is standing exactly where the read was taken.)
import Foundation

/// The room's measured facts, as vocabulary. `.empty` (no salon room, no
/// read, or an expired one) makes every lookup miss, so callers fall back to
/// today's lines without a separate "is this on" flag — the same shape as
/// `CoachBookingVocabulary.empty`.
struct CoachRoomVocabulary: Equatable, Sendable {
    static let empty = CoachRoomVocabulary(knowsWindow: false, cast: .neutral)

    /// The station read found a window worth pointing the pro at.
    let knowsWindow: Bool
    /// What the room's ambient light read as at setup.
    let cast: CoachStationRead.Profile.Cast

    private init(knowsWindow: Bool, cast: CoachStationRead.Profile.Cast) {
        self.knowsWindow = knowsWindow
        self.cast = cast
    }

    /// Build from the room's station read; nil (no read taken, or expired)
    /// resolves to `.empty` and the coach keeps its canonical lines.
    init(profile: CoachStationRead.Profile?) {
        self.knowsWindow = profile?.hasWindow ?? false
        self.cast = profile?.cast ?? .neutral
    }

    var isEmpty: Bool { !knowsWindow && cast == .neutral }

    // MARK: - The lines

    /// The room-specific line for a correction the coach has already decided
    /// to give, or nil to leave the words exactly as they are.
    ///
    /// Only the corrections a station read actually measured something about
    /// are listed: the room's light. Everything else is about the camera, the
    /// framing or the person, and the room has nothing truer to say there.
    ///
    /// `vocabulary` is read only for the client's name, exactly as
    /// `CoachPlainLine` reads it — the one line here whose object is the
    /// person reads better naming them, and re-deriving a name would be a
    /// second set of refusal rules to keep in step.
    func line(replacing nudge: CoachNudge, vocabulary: CoachBookingVocabulary) -> String? {
        guard !isEmpty else { return nil }
        let ctx = nudge.phraseCtx ?? CoachPhraseContext()
        switch nudge.moment {
        // The canonical line says "daylight reads truer" without saying where
        // daylight IS. The read knows: this room has one.
        case .colorWarm:
            guard knowsWindow else { return nil }
            return "Warm light — try the window"

        case .colorGreenish:
            guard knowsWindow else { return nil }
            return "Greenish light — try the window"

        // Mixed light names the half of the mix the station itself measured —
        // the same "turn off the overheads" instruction, with the room's own
        // colour on it. Neutral cast → nothing truer to say than canonical.
        case .colorMixed:
            switch cast {
            case .warm: return "Mixed light — turn off the warm overheads"
            case .green: return "Mixed light — turn off the fluorescents"
            case .neutral: return nil
            }

        // "Toward the light" becomes "toward the window" — the room knows
        // which light is worth turning toward. Gated on `namesAPerson` the
        // same way #358 gated it: the flat-lay variant of this moment is
        // about a tray of nails, and gets the window without the person.
        case .lightingTooDark:
            guard knowsWindow else { return nil }
            guard ctx.namesAPerson else { return "Too dark — try the window" }
            let who = vocabulary.clientName.map { "\($0)’s" } ?? "Their"
            return "\(who) face is too dark — turn them toward the window"

        default:
            return nil
        }
    }

    /// The nudge with the room's words. The category, the moment and the
    /// phrase context all survive — only `message` can change.
    func applied(to nudge: CoachNudge, vocabulary: CoachBookingVocabulary) -> CoachNudge {
        guard let line = line(replacing: nudge, vocabulary: vocabulary) else { return nudge }
        return CoachNudge(category: nudge.category, message: line,
                          moment: nudge.moment, phraseCtx: nudge.phraseCtx)
    }

    /// The same substitution for a dimensions-drawer row, through the SAME
    /// `line(replacing:)` — the drawer must never disagree with the lane
    /// about what the coach just said.
    func applied(to status: CoachStatus, vocabulary: CoachBookingVocabulary) -> CoachStatus {
        guard let message = status.message,
              let line = line(replacing: CoachNudge(
                  category: status.category, message: message,
                  moment: status.moment, phraseCtx: status.phraseCtx),
                  vocabulary: vocabulary)
        else { return status }
        return CoachStatus(category: status.category, score: status.score,
                           message: line, why: status.why,
                           moment: status.moment, phraseCtx: status.phraseCtx)
    }
}
