// The Session Reel's HARVEST POLICY — which analyzed frames earn a place in the
// best-shots tray. No camera, no CoreImage, no clock of its own, so it can be
// driven a frame at a time in a test. Mirrors `CoachTipArbiter` /
// `CoachSpeechScheduler`'s explicit `now: TimeInterval` pattern for the same
// reason: deterministic tests, no sleeping to make time pass.
//
// `CoachAnalyzer` owns the frames, the full-res JPEG encode and the tray cap.
// This only ever decides WHETHER the frame in hand is worth banking.
//
// ## Why there are two ways in
//
// The reel used to admit one thing only: a frame at or above `harvestThreshold`
// (0.85). The ring goes green at `readyThreshold` (0.8). Between them sits a
// band that an ORDINARY salon frame lands in — mixed light plus a busy backdrop
// plus a few degrees of hand tilt measures **0.826** (docs/camera-tuning-bench.md,
// 2026-08-23) — so a pro could shoot a whole session that read green from the
// first frame to the last and come away with an empty tray. Green has to mean
// "I've got you"; a reel that collects nothing out of a green session breaks
// that promise quietly, at the end, when the session is over and unrepeatable.
//
// So a steady green HOLD is a second way in. The peak path is untouched: an
// excellent frame still banks the instant it appears, spacing permitting.
// Underneath it, a hold that has been continuously ready for as long as the
// guided shutter itself needs (`autoCaptureHoldSeconds`) banks a frame too —
// and then banks again only if the hold gets BETTER than what the reel already
// took from it. That last clause is the whole defence against tray flooding: a
// pro who holds one pose for thirty green seconds gets one keeper out of it,
// not twelve copies of it.
//
// ## What "its best frame" can and cannot mean here
//
// Only the frame in hand can be encoded — there is no going back for the good
// one from two seconds ago (the pixel buffer is gone, and holding buffers
// across frames is the path that has already been jetsam-killed once; see
// `CoachAnalyzer`). So "banks its best frame" is served forward, not backward:
// the hold banks once as soon as it is steady, and re-banks on each genuine
// improvement. By the end of the hold the reel holds the best frame it was ever
// OFFERED, which is the most a live stream can honestly promise.
//
// ## Not the same hold as the shutter's
//
// This shares `autoCaptureHoldSeconds` with the guided auto-shutter, but not the
// hold itself: `CoachEngine.resetHold()` re-arms the SHUTTER after a shot fires
// so it can't immediately re-trigger, and deliberately does not reach in here.
// The two are asking different questions — the shutter's hold is about when to
// fire again, this one is about whether the frame quality has been continuous —
// and a firing shutter is no reason to forget that it has. Nothing double-banks
// either way: an auto-shot and the backstop land on the same frame, and the
// improvement rule means the reel takes it once.
import Foundation

struct CoachHarvestGate: Sendable {
    /// What a frame is worth — and, when it is worth something, which way in it
    /// took. The tests assert on the case, not just on a Bool, so a change that
    /// breaks one path cannot read as the other one still working.
    enum Decision: Equatable, Sendable {
        /// Nothing to bank from this frame.
        case skip
        /// At or above `harvestThreshold`: the reel's original admission, and
        /// still the one that needs no hold behind it. A fleeting excellent
        /// frame is worth keeping even if the pro never settles.
        case peak
        /// Below `harvestThreshold`, but the shot has held green long enough to
        /// be worth keeping and this is the best the hold has offered so far.
        case steadyHold

        /// Whether the caller should try to claim a tray slot for this frame.
        var banks: Bool { self != .skip }
    }

    /// When the current unbroken run of ready frames began; nil between holds.
    private var holdStartedAt: TimeInterval?
    /// The best readiness ALREADY BANKED out of the current hold. Nil while the
    /// hold has banked nothing yet — which is exactly what guarantees a steady
    /// hold banks at least once. Cleared with the hold.
    private var bankedThisHold: Double?
    /// When the reel last actually took a frame; nil = not yet, this session.
    private var lastBankAt: TimeInterval?

    /// What this frame is worth. Call on EVERY analyzed frame, not only the ones
    /// that look like they might pass: the backstop is built out of how long the
    /// hold has lasted, and the frames that *don't* pass are the ones that
    /// measure it.
    ///
    /// This decides only. The caller still has to claim a tray slot and the tray
    /// can be full, so nothing is recorded as banked until the caller confirms
    /// it with `didHarvest` — exactly as the old inline gate only moved its
    /// timestamp once `reserveHarvestSlot()` had already succeeded.
    mutating func shouldHarvest(readiness: Double, now: TimeInterval) -> Decision {
        let ready = readiness >= CoachTuning.readyThreshold
        if ready {
            if holdStartedAt == nil { holdStartedAt = now }
        } else {
            // The hold is over. The next one starts owing its own frame.
            holdStartedAt = nil
            bankedThisHold = nil
        }

        // The floor under how often the reel may take anything at all, by either
        // way in. Checked after the hold bookkeeping above, never instead of it.
        if let last = lastBankAt, now - last < CoachTuning.minHarvestInterval { return .skip }

        // An excellent frame banks on its own merit, with no hold behind it —
        // deliberately not gated on `ready`, so that dragging the two thresholds
        // past each other in the DEBUG tuning console can only ever widen what
        // the reel accepts, never silently narrow it.
        if readiness >= CoachTuning.harvestThreshold { return .peak }

        guard ready, let started = holdStartedAt,
              now - started >= CoachTuning.autoCaptureHoldSeconds else { return .skip }
        // The first frame of a hold to get this far banks unconditionally: that
        // is the backstop, and it is what makes a green session end with
        // something in it. After that the hold has to actually beat what the
        // reel already took from it.
        guard readiness > (bankedThisHold ?? -.infinity) else { return .skip }
        return .steadyHold
    }

    /// Confirm the frame `shouldHarvest` offered was actually claimed. Only this
    /// advances the spacing floor and the hold's banked-best — an offer the tray
    /// had no room for must leave the gate exactly as it found it, so the frame
    /// is offered again as soon as reviewing frees a slot.
    mutating func didHarvest(readiness: Double, at now: TimeInterval) {
        lastBankAt = now
        // A `.peak` frame can land outside a hold (see above); there is no
        // hold's-best to raise when it does.
        if holdStartedAt != nil {
            bankedThisHold = max(bankedThisHold ?? readiness, readiness)
        }
    }
}
