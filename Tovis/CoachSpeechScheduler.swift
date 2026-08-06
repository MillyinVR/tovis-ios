// The speech-delivery POLICY — pacing/coalescing, priority interrupt, and
// per-category repeat suppression — with no AVFoundation dependency, so it's
// testable without a live synthesizer. Mirrors `CoachTipArbiter`'s explicit
// `now: TimeInterval` pattern for the same reason: deterministic tests, no
// sleeping to make time pass.
//
// `CoachEngine` owns the real `AVSpeechSynthesizer` and asks this what to do;
// this never touches audio, an audio session, or anything actor-isolated —
// it only ever decides WHEN a request reaches the synthesizer, never what
// text is said (that's `CoachVoiceRenderer`, upstream of this entirely).
import Foundation

struct CoachSpeechScheduler: Sendable {
    enum Priority: Equatable, Sendable {
        /// An ongoing coaching correction. Never interrupts what's playing;
        /// coalesces behind it instead of queuing, so only the freshest tip
        /// survives to actually be spoken.
        case tip
        /// A deliberate thing the pro is waiting on — the next guided shot, a
        /// capture confirmation. May interrupt a TIP that's mid-flight;
        /// coalesces behind another directive rather than queuing behind it.
        case directive
    }

    /// What the caller should actually do in response to a request.
    enum Action: Equatable, Sendable {
        /// Start this utterance right now — the channel was free.
        case speak(String)
        /// Interrupt whatever's currently playing, then start this one once
        /// the interrupt lands. Two steps because stopping a synthesizer is
        /// itself asynchronous — see `channelFreed`.
        case interruptThenSpeak(String)
        /// Nothing to do right now: coalesced behind what's already playing,
        /// or suppressed by the per-category repeat cooldown.
        case none
    }

    private var currentPriority: Priority?
    private var pending: (text: String, priority: Priority)?
    /// When each fundamental was last actually SPOKEN (not just considered).
    /// Keyed by category, not the exact `CoachMoment` — a nudge that flaps at
    /// a sub-threshold (sharpness bouncing between "hold steady" and "tap to
    /// focus" right at the boundary between two thresholds, say) changes
    /// WORDING every flip while staying the same fundamental's problem;
    /// suppressing only exact-moment repeats would let that alternation
    /// straight through.
    private var lastSpokenTipAt: [CoachCategory: TimeInterval] = [:]

    /// How long a fundamental's tip stays suppressed after being spoken once.
    private let tipRepeatCooldown: TimeInterval
    /// How long a fundamental must have gone unspoken before a "cleared"
    /// signal for it is trusted to reset the cooldown early. A clear landing
    /// almost instantly after speaking is the SAME flapping the cooldown
    /// exists to silence, seen from the other side — sensor noise briefly
    /// reading as "fixed" between two frames faster than a person could have
    /// reacted, not a real correction. Trusting it would let the flap reset
    /// its own cooldown every time. A clear that holds longer than this is
    /// plausibly real, and gets the early reset.
    private let clearResetGuard: TimeInterval

    init(tipRepeatCooldown: TimeInterval = 9, clearResetGuard: TimeInterval = 2) {
        self.tipRepeatCooldown = tipRepeatCooldown
        self.clearResetGuard = clearResetGuard
    }

    /// A directive, or a non-suppressed line (the `.dimensionCleared`
    /// congratulation) — not subject to per-category repeat suppression;
    /// only `requestTip` is.
    mutating func request(_ text: String, priority: Priority) -> Action {
        guard let current = currentPriority else {
            currentPriority = priority
            return .speak(text)
        }
        if priority == .directive, current == .tip {
            pending = (text, priority)
            return .interruptThenSpeak(text)
        }
        pending = (text, priority)
        return .none
    }

    /// A coaching tip for `category` — suppressed if that category was
    /// already spoken within `tipRepeatCooldown`, regardless of whether the
    /// exact wording changed.
    mutating func requestTip(_ text: String, category: CoachCategory, now: TimeInterval) -> Action {
        if let last = lastSpokenTipAt[category], now - last < tipRepeatCooldown {
            return .none
        }
        lastSpokenTipAt[category] = now
        return request(text, priority: .tip)
    }

    /// `category` reads as clear now. Resets its cooldown (so a later genuine
    /// re-trigger isn't stuck waiting out a stale window) only when trusted —
    /// see `clearResetGuard`. Returns whether the reset was trusted, so the
    /// caller knows whether to actually speak the "got it" line: celebrating
    /// a fix that's about to un-fix itself next frame is its own flavor of
    /// the same annoyance.
    @discardableResult
    mutating func categoryCleared(_ category: CoachCategory, now: TimeInterval) -> Bool {
        guard let last = lastSpokenTipAt[category] else { return true }
        guard now - last >= clearResetGuard else { return false }
        lastSpokenTipAt.removeValue(forKey: category)
        return true
    }

    /// The channel just freed — an utterance finished, or an interrupt
    /// landed. What to actually start next, if anything was coalesced behind
    /// it.
    mutating func channelFreed() -> Action {
        currentPriority = nil
        guard let next = pending else { return .none }
        pending = nil
        currentPriority = next.priority
        return .speak(next.text)
    }
}
