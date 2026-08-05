// When the guided auto-shot is allowed to fire — the whole arming rule, pulled
// out of the camera view so it can be tested without a camera.
//
// THE BUG THIS EXISTS TO PIN. The old rule lived in two `.onChange` handlers and
// re-armed in exactly one place: when readiness dropped out of the green ring.
// Trace a QC-rejected burst while the client holds perfectly still:
//
//   1. `attemptGuidedCapture` disarms and shoots.
//   2. The burst's three frames all fail QC. Nothing uploads, the guide doesn't
//      advance, and the lane says "…holding for another try."
//   3. `resetHold()` clears the steady hold; the next frame re-establishes it,
//      so `isSteadyReady` flips false → true and the handler fires…
//   4. …and finds the arm still DISARMED, because readiness never left the
//      green ring, so the one re-arm site never ran.
//
// Auto-capture was then dead until something broke the ready state — while the
// screen promised another try. The success path self-healed (advancing the step
// changes the expectations, which drops readiness), so this only bit on the
// rejection path: precisely when the pro most needs the retry.
//
// The fix is one more re-arm site — a burst that kept nothing re-arms — and the
// point of this type is that it is now a fact a test can assert instead of a
// control-flow shape you have to hold in your head.
import Foundation

struct GuidedCaptureArm: Equatable {
    /// Whether a steady, ready frame may fire the shutter right now.
    private(set) var isArmed = true

    init() {}

    /// The coach's green ring came or went. Dropping out of ready re-arms, so
    /// the next setup shoots once rather than continuously.
    mutating func readinessChanged(ready: Bool) {
        if !ready { isArmed = true }
    }

    /// A capture is being started — don't fire again until something re-arms.
    mutating func didFire() {
        isArmed = false
    }

    /// A capture finished. `kept` is whether a frame actually survived QC and
    /// was filed. A burst that kept NOTHING must re-arm: the subject is still
    /// in position, and the retry is the whole promise of "holding for another
    /// try."
    mutating func captureFinished(kept: Bool) {
        if !kept { isArmed = true }
    }

    /// The firing condition itself, so the view never re-derives it.
    func shouldFire(steady: Bool) -> Bool { steady && isArmed }
}
