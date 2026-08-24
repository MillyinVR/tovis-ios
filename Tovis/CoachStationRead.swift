// The station read: the coach learns a room at setup (camera plan P4.2).
//
// Tori's framing for this step: *"snap your station once → coach reads
// window/overheads and seeds the per-room memory (pairs with the persistent
// 'overheads stay on here' dismissal)."* The pro points the camera at their
// empty station once; the coach measures the light and remembers it against
// the same `CoachRoomMemory` record P4.1 built — so the coach already knows
// the room before the first correction of the next shoot has been fumbled
// through.
//
// ## What a station read is allowed to MOVE — decided, and argued
//
// The plan's wording said "seeds profile/priors, so the very first live frame
// is already calibrated". The PRIOR half is deliberately NOT built, and the
// word "calibrated" is deliberately not earned here. A station read moves:
//
//   1. **Words** — the coach's line for a colour/light correction can name
//      what it knows about this room ("try the window", "turn off the warm
//      overheads"), at the same seam as #974/#358/#360 (`CoachRoomVocabulary`,
//      applied in `CoachEngine.apply`). A substitution on a correction the
//      coach had already decided to give — never more speech, never sooner.
//   2. **The GOT IT offer's timing** — a room condition the station itself
//      measured (`corroborates`, below) is offered for retirement on the
//      FIRST shoot instead of the third. The pairing Tori named: the read is
//      independent evidence that the condition is the ROOM's, which is the
//      exact question `shootsBeforeOffering` exists to wait out.
//
// And it moves nothing else. Explicitly refused:
//
//   • **No score, no readiness, no drawer.** #359 and #360 both held the line
//     that the coach never lies about the photograph to be kind, and a
//     per-room prior is the first thing in P4 that could have broken it. A
//     ring that means different things in different rooms is a ring that
//     cannot be trusted in any of them.
//   • **No threshold prior.** The global colour thresholds have never been
//     salon-measured (`mixedLightSpread` is plan §3.2, gated on D3) — a
//     per-room delta on top of an unmeasured base compounds a guess with a
//     guess, and one frame of an empty station taken once, possibly months
//     ago, is not evidence strong enough to move a live measurement of a
//     frame with a person in it. When the salon pass has set the base, a
//     prior can be argued from data; today it would be drift wearing P4.2's
//     name. (This is also what keeps `ShotCoach`/`CoachTuning`/`FrameMath` —
//     the tuning bench's whole compile graph — untouched by this feature.)
//   • **The calibration card always wins, by construction.** The card
//     (`CardScanner`/`CardCorrection`) is a measured white-balance reference
//     for a SHOOT; this is a coarse reading of a ROOM. They never disagree
//     because they never share a variable: the station read touches no WB
//     gain, no matrix, no exposure anchor, and not the drift watcher. If the
//     room doesn't measure warm on the live frame today, `.colorWarm` never
//     fires and the room's words never appear.
//
// ## Why no coaching line ever speaks the window's SIDE
//
// The read can locate the window (the distinctly cool third of the station
// frame), and the profile stores which side — but "the window's on your
// left" is only true from where the pro STOOD when they took the read, and
// mid-shoot the coach cannot know which way they are facing. #358's rule: a
// direction must be a fact about the picture, never a second unverified sign
// convention. So the side is spoken exactly where it is anchored and
// instantly checkable — the setup screen's own confirmation and the session
// hub's summary row, read while the pro is standing there — and the live
// lines claim only the invariants: the room HAS a window worth using, and
// what the ambient light reads as.
//
// ## Where the photo goes: nowhere
//
// A station frame is a photo of a workplace taken outside any booking. It is
// never captured as a photo at all — the sampler measures live analysis
// frames at the coach's own working resolution and keeps only the numbers
// below. Nothing enters the Session Reel, the harvest tray, the publish or
// consent paths, or the capture-attestation chain, and there are no bytes to
// delete because none are ever written.
import CoreGraphics
import Foundation

enum CoachStationRead {
    /// One room's light, measured once. Raw numbers, not verdicts: every
    /// verdict below is derived at USE time against the current `CoachTuning`
    /// thresholds, so a future retune coherently moves what an old read means
    /// instead of freezing a stale interpretation into UserDefaults. (That is
    /// also why no `CoachRoomMemory.meaningVersions` bump is needed here — a
    /// read never changes what any moment CLAIMS, it only adds the room's own
    /// evidence for it.)
    struct Profile: Equatable, Sendable {
        /// Signed warmth of the station's light, whole frame (`FrameMath.warmth`).
        let warmth: Double
        /// Signed green excess, whole frame (`FrameMath.greenTint`).
        let greenTint: Double
        /// Warmth of the left / middle / right thirds, in the pro's own view
        /// from where they took the read (back camera, `.oriented(.right)`,
        /// no mirroring — image-left is scene-left, the #358 argument).
        let thirdWarmths: [Double]
        /// When the read was taken — the expiry clock (`CoachRoomMemory`).
        let readAt: Date

        /// Warm↔cool spread across the station — the same physical quantity
        /// `ColorSignal.mixed` measures live, on the same scale.
        var spread: Double {
            guard let hi = thirdWarmths.max(), let lo = thirdWarmths.min() else { return 0 }
            return max(0, hi - lo)
        }

        /// Whether the station has a window worth pointing the pro at: one
        /// third reads distinctly cooler than the rest (the spread that means
        /// "two light sources", reusing `mixedLightSpread` because it IS that
        /// claim) AND that third actually reads like daylight rather than
        /// merely "the less-warm bulb" (below the warm-cast line).
        var hasWindow: Bool {
            spread > CoachTuning.mixedLightSpread
                && (thirdWarmths.min() ?? .infinity) < CoachTuning.warmCastWarmth
        }

        /// Which side of the pro's view the window sat on AT THE READ —
        /// "left"/"right", nil when there is no window or it sat in the
        /// middle third. Spoken only on position-anchored surfaces (the
        /// setup confirmation, the hub row); see the header for why no
        /// coaching line ever says it.
        var windowSide: String? {
            guard hasWindow, thirdWarmths.count == 3,
                  let lo = thirdWarmths.min(),
                  let index = thirdWarmths.firstIndex(of: lo) else { return nil }
            switch index {
            case 0: return "left"
            case 2: return "right"
            default: return nil
            }
        }

        /// What the room's ambient light reads as, in the live coach's own
        /// vocabulary and precedence (`ColorCoach` reports green before warm).
        enum Cast: Equatable, Sendable { case warm, green, neutral }
        var cast: Cast {
            if greenTint > CoachTuning.greenCastTint { return .green }
            if warmth > CoachTuning.warmCastWarmth { return .warm }
            return .neutral
        }

        /// Whether the station itself measured this room condition — the
        /// evidence that lets `CoachRoomMemory` offer GOT IT on the first
        /// shoot instead of the third. Colour moments only, each against the
        /// same threshold the live coach fires on.
        ///
        /// `.backgroundBusy` is deliberately NEVER corroborated: with no
        /// person to segment, a station frame's edge energy measures how busy
        /// the PICTURE is, not the backdrop — the exact confusion the bench's
        /// portraits-only finding exists to warn about (docs/camera-tuning-
        /// bench.md, 2026-08-23).
        func corroborates(_ moment: CoachMoment) -> Bool {
            switch moment {
            case .colorMixed: return spread > CoachTuning.mixedLightSpread
            case .colorGreenish: return greenTint > CoachTuning.greenCastTint
            case .colorWarm: return warmth > CoachTuning.warmCastWarmth
            default: return false
            }
        }

        /// The read, in a sentence — the setup confirmation and the hub row.
        /// The one surface allowed to say the window's side (position-anchored:
        /// the pro is standing where the read was taken, and can check it by
        /// looking up).
        var summary: String {
            let window: String
            if let side = windowSide {
                window = "Window on your \(side)"
            } else if hasWindow {
                window = "Window in view"
            } else {
                window = "No window in view"
            }
            let light: String
            switch cast {
            case .warm: light = "warm light"
            case .green: light = "greenish light"
            case .neutral: light = "neutral light"
            }
            return "\(window) · \(light)"
        }
    }

    // MARK: - Taking the read

    /// One analyzed frame's contribution to a read.
    struct Sample: Equatable, Sendable {
        let thirdWarmths: [Double]
        let warmth: Double
        let greenTint: Double
        let luma: Double
        let faceSeen: Bool
    }

    /// What one read attempt concluded. Both refusals are written as refusals
    /// (the `CoachBookingVocabulary` discipline): a wrong room fact spoken for
    /// months is worse than asking the pro to try again now.
    enum Outcome: Equatable, Sendable {
        case read(Profile)
        /// A face was in frame — this is a read of the STATION, and a person
        /// in it would put their skin and clothes into the "room's light".
        case someoneInFrame
        /// Too dark to read (below `lumaTooDark`): a reading of a dark room
        /// would seed confident nonsense about its light.
        case tooDark
    }

    /// How many consecutive analyzed frames one read averages over — ~1s at
    /// the analyzer's 6fps, enough for auto-exposure to settle and for one
    /// noisy frame not to become the room's permanent record.
    static let samplesPerRead = 6

    /// Accumulates one read attempt. Pure — the AVCapture glue in
    /// `StationReadView` feeds it and the tests drive it directly.
    struct Accumulator: Sendable {
        private(set) var samples: [Sample] = []

        var isComplete: Bool { samples.count >= CoachStationRead.samplesPerRead }

        mutating func add(_ sample: Sample) {
            guard !isComplete else { return }
            samples.append(sample)
        }

        /// The attempt's verdict once complete; nil while still collecting.
        /// A face in ANY sample refuses the whole read — a client stepping
        /// through frame for one sixth of a second still skews the average.
        func outcome(readAt: Date) -> Outcome? {
            guard isComplete else { return nil }
            guard !samples.contains(where: \.faceSeen) else { return .someoneInFrame }
            func mean(_ values: [Double]) -> Double {
                values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            }
            guard mean(samples.map(\.luma)) >= CoachTuning.lumaTooDark else { return .tooDark }
            let thirds = (0..<3).map { i in
                mean(samples.compactMap { $0.thirdWarmths.indices.contains(i) ? $0.thirdWarmths[i] : nil })
            }
            return .read(Profile(warmth: mean(samples.map(\.warmth)),
                                 greenTint: mean(samples.map(\.greenTint)),
                                 thirdWarmths: thirds,
                                 readAt: readAt))
        }
    }
}
