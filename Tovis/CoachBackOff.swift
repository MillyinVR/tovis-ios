// When repeating itself has stopped helping (camera plan P4.3).
//
// P4's frame is MEMORY. `CoachRoomMemory` is its long horizon — the salon the
// pro shoots in every week. This is its short one: the last minute.
//
// A photographer standing next to you does not say the same sentence ten times
// in one breath. They say it once more, simpler, and then they let you work.
// The coach's lane does the opposite today: the focus ladder locks onto one
// rung and holds that line, unchanged and pulsing, for as long as the
// condition holds — which on a condition the pro can't fix (or won't, right
// now, mid-blowout, with a client in the chair) is the whole session. That is
// the mechanical shape of Tori's *"i feel like its just reading lines"*.
//
// So: when the rung the pro is being coached on has held the lane for
// `CoachTuning.coachPatienceSeconds` with **no measurable improvement in that
// rung's own score**, the coach says it once more with everything but the
// instruction removed (`CoachPlainLine`). If that doesn't move the score
// either, it stops saying it and coaches the next thing instead.
//
// ## Mechanical empathy only
//
// 🔴 This is arithmetic on a score history and NOTHING else. There is no
// sentiment detection here, no inference about how the pro feels, no simulated
// emotion — that is a standing hard line in the camera's north star, and this
// file is where it would be easiest to cross. What is measured is: did the
// number this rung is scored on go up? Everything else the feature does hangs
// off that one comparison.
//
// ## What it deliberately does NOT do
//
//   • **It does not move readiness.** Same guarantee as `CoachRoomMemory`, for
//     the same reason: this runs inside `CoachTipArbiter`, which is asked which
//     SENTENCE to publish long after `CoachAggregate.evaluate` has computed the
//     weighted mean. A backed-off rung is still a real deficit, the ring still
//     counts it, and the dimensions drawer still names it in full.
//   • **It does not read as "fixed".** Going quiet is not the stable-good path.
//     The ladder must never compliment a pro on a rung that was silenced rather
//     than solved, so a rung that backs off is taken out of the running the same
//     way a retired one is — the lock is DROPPED, not waited out. No `advanced`,
//     no `cleared`, no praise.
//   • **It never backs off a hard failure.** See the severity guard below.
//   • **It is not persisted.** A dismissal is a statement the pro made about
//     their salon and outlives the shoot; this is the coach's own inference
//     about the last minute, and it dies with the camera session. Nothing here
//     touches `UserDefaults`.
//
// ## Why it releases the lock rather than holding it silently
//
// The genuine fork, argued rather than assumed. A backed-off rung is still the
// highest-priority broken thing in the frame, so there is a real case for
// holding the lock and simply saying nothing: it would stop the coach ever
// promoting polish over a problem that is still the biggest one.
//
// It is refused because of what it costs. Holding the lock means the ladder can
// never advance past that rung, so ONE condition the pro can't currently fix
// silences the coach about everything else for the rest of the shoot — the
// framing, the pose, the tilt. That is a mute button with extra steps, which is
// precisely what P4.1 refused to build. A photographer who has said "the
// overheads are mixed" three times and got nowhere does not then stand there in
// silence; they move on to what you CAN change.
//
// The truth about the un-fixed rung is not lost when the lock is released — it
// is carried by the ring and by the drawer, neither of which this touches. What
// is given up is the WORDS, which is exactly what had stopped working.
import Foundation

/// Whether the coach should keep saying a rung's correction, say it plainer, or
/// stop saying it — decided purely from how that rung's score has moved.
struct CoachBackOff: Sendable {
    enum Stage: Sendable, Equatable {
        /// Say it normally. Every rung starts here and returns here the moment
        /// the score moves.
        case speaking
        /// Say it once more, with everything but the instruction taken off.
        case simplified
        /// Stop saying it; coach the next thing instead.
        case quiet
    }

    /// The smallest score change that counts as the pro making progress.
    ///
    /// Set below the smallest real step any coach can take WITHIN one rung —
    /// `.centering` moves 0.45 → 0.50 between "leave a little headroom" and
    /// "raise the camera" — and above nothing, because none of the correction
    /// scores are continuous: each is a fixed constant for as long as its
    /// condition holds (`ShotCoach.swift`). So on most rungs "no measurable
    /// improvement" means the literal thing it says — the condition has not
    /// changed at all. The two coaches that DO score continuously
    /// (`LightingCoach`, `SharpnessCoach`) only do so on their passing paths,
    /// which have no message and never reach here.
    static let improvementEpsilon = 0.02

    /// One rung's history: the best score it has read since the pro last made
    /// progress on it, and how long it has been ON THE LANE since then.
    private struct Track {
        var best: Double
        /// Seconds this rung's correction has been the sentence the pro is
        /// reading without its score improving. ACCUMULATED rather than
        /// measured from a start instant, because the coach's patience is spent
        /// only while it is actually talking: a rung that stalls for fifteen
        /// seconds, gets preempted by a lighting regression, and comes back two
        /// minutes later has been on the lane for fifteen seconds, not two
        /// minutes — and a wall-clock start would have it skip its plainer pass
        /// and go straight to silence the moment it returned.
        var stalled: TimeInterval
        /// The frame this rung was last observed on, or nil while it is not the
        /// rung being said — which is what pauses the clock above.
        var lastObservedAt: TimeInterval?
    }

    private var tracks: [FocusRung: Track] = [:]
    /// The rungs currently backed off all the way to silence. Kept explicitly
    /// rather than recomputed from `tracks` alone so that a rung stays quiet
    /// once earned — its lock has already been released, so it is no longer the
    /// rung being coached, and only its own score improving brings it back.
    private var quieted: Set<FocusRung> = []

    init() {}

    /// How long a rung must read stalled before the coach simplifies it.
    static var simplifyAfter: TimeInterval { CoachTuning.coachPatienceSeconds }
    /// …and before it stops saying it. The same patience again, spent twice:
    /// once on the sentence the pro has been reading, once on the plainest form
    /// of it. Deliberately not a second knob — there is one question here ("how
    /// long is too long to be saying the same thing?") and one number for it.
    static var quietAfter: TimeInterval { CoachTuning.coachPatienceSeconds * 2 }

    /// The rungs the coach has stopped saying anything about.
    var quietedRungs: Set<FocusRung> { quieted }

    /// Advance the clock for one analyzed frame.
    ///
    /// `brokenScores` is every rung with a correction on it this frame and the
    /// score its signal read — **corrections only**: a `CoachSeverity.failure`
    /// must never appear here (the caller's guard is what keeps it out, and
    /// `CoachTipArbiterTests` pins it).
    /// `locked` is the rung whose sentence the pro is actually reading, which
    /// is the only one whose clock can START running: a rung the coach has
    /// never spoken about cannot have worn out its welcome.
    mutating func update(brokenScores: [FocusRung: Double], locked: FocusRung?, now: TimeInterval) {
        // A rung that isn't broken this frame has nothing to be patient about —
        // it was fixed, or it escalated to a hard failure and left this set.
        // Either way its history goes with it, so the next time it breaks it
        // gets the coach's full patience again from zero.
        for rung in tracks.keys where brokenScores[rung] == nil { tracks[rung] = nil }
        quieted.formIntersection(brokenScores.keys)

        // The rung being said, plus the ones already backed off — those are
        // still watched so that the pro making progress on one brings its words
        // straight back.
        let observed = brokenScores.keys.filter { $0 == locked || quieted.contains($0) }
        for rung in tracks.keys where !observed.contains(rung) { tracks[rung]?.lastObservedAt = nil }

        for rung in observed {
            guard let score = brokenScores[rung] else { continue }
            guard var track = tracks[rung] else {
                tracks[rung] = Track(best: score, stalled: 0, lastObservedAt: now)
                continue
            }
            // `best` is a high-water mark, not the last reading: a score that
            // dips and recovers to where it already was is not progress, and
            // treating it as progress would let an unfixable condition reset
            // the coach's patience forever on sensor noise alone.
            if score > track.best + Self.improvementEpsilon {
                track.best = score
                track.stalled = 0
                quieted.remove(rung)
            } else if let last = track.lastObservedAt {
                track.stalled += max(0, now - last)
            }
            track.lastObservedAt = now
            tracks[rung] = track
            if track.stalled >= Self.quietAfter { quieted.insert(rung) }
        }
    }

    /// What the coach should do about this rung.
    ///
    /// A rung with no history — one that has never been the locked rung, and so
    /// has never been said out loud — is always `.speaking`. That includes
    /// every rung on the memory-free `CoachAggregate.evaluate(_:_:)` overload
    /// the offline bench and the pinned readiness tests run through, whose
    /// arbiter is fresh and is asked exactly once.
    func stage(of rung: FocusRung) -> Stage {
        guard let track = tracks[rung] else { return .speaking }
        if track.stalled >= Self.quietAfter { return .quiet }
        if track.stalled >= Self.simplifyAfter { return .simplified }
        return .speaking
    }
}
