// Automatic retry-with-backoff for the session camera's owed-photo queue.
//
// Two failure shapes need different medicine. A genuine offline→online edge
// (airplane mode toggled off, wifi reassociates) is caught by
// `ConnectivityMonitor` and deserves an immediate retry. A connection that
// stays "satisfied" the whole time but times out anyway — flaky salon wifi,
// the more common case in practice — never fires that signal at all, so this
// scheduler's own capped exponential-backoff timer is the net that catches
// it: armed on every failure, it keeps trying on its own until the queue
// drains, without the pro ever tapping Retry.
import Foundation

@MainActor
final class UploadRetryScheduler {
    /// Capped exponential backoff, in seconds — caps how aggressively a
    /// struggling connection gets hammered while still recovering promptly
    /// once it's healthy again.
    let steps: [TimeInterval]
    private(set) var attempt = 0
    private var timerTask: Task<Void, Never>?

    init(steps: [TimeInterval] = [2, 4, 8, 16, 30]) {
        self.steps = steps
    }

    /// The delay the next `scheduleRetry` call would use — pure, no side
    /// effects, so the backoff sequence is testable without sleeping or
    /// firing anything.
    var nextDelay: TimeInterval { steps[min(attempt, steps.count - 1)] }

    /// Arm (or re-arm) the timer for one retry attempt, replacing any pending
    /// one — there is only ever one next attempt in flight.
    ///
    /// `resetBackoff`: a fresh failure or a reconnect signal is worth trying
    /// soon again. Otherwise (a retry that failed again) keep backing off.
    func scheduleRetry(resetBackoff: Bool = false, fire: @escaping () async -> Void) {
        if resetBackoff { attempt = 0 }
        let delay = nextDelay
        attempt = min(attempt + 1, steps.count - 1)
        timerTask?.cancel()
        timerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    /// Nothing left to retry, or the view is going away.
    func stop() {
        timerTask?.cancel()
        timerTask = nil
        attempt = 0
    }
}
