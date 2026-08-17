// The backoff sequence behind automatic retry of the session camera's
// owed-photo queue. Pins the pure attempt-counting/delay-selection logic —
// `scheduleRetry` mutates `attempt` synchronously, before its Task ever
// sleeps, so the whole sequence is assertable without waiting on a real timer.
import Testing
@testable import Tovis

@MainActor
@Suite struct UploadRetrySchedulerTests {
    @Test func startsAtTheFirstStep() {
        let scheduler = UploadRetryScheduler(steps: [2, 4, 8, 16, 30])
        #expect(scheduler.nextDelay == 2)
    }

    @Test func backsOffOnEachScheduleCall() {
        let scheduler = UploadRetryScheduler(steps: [2, 4, 8, 16, 30])
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.nextDelay == 4)
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.nextDelay == 8)
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.nextDelay == 16)
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.nextDelay == 30)
    }

    @Test func capsAtTheLastStepRatherThanRunningOff() {
        let scheduler = UploadRetryScheduler(steps: [2, 4])
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.nextDelay == 4)
        scheduler.scheduleRetry(fire: {})   // would be step 3 — none exists
        #expect(scheduler.nextDelay == 4)
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.nextDelay == 4)
    }

    /// A fresh failure or a reconnect signal is worth trying soon again —
    /// `resetBackoff` must start the sequence over, not just resume it.
    @Test func resetBackoffStartsOverFromTheFirstStep() {
        let scheduler = UploadRetryScheduler(steps: [2, 4, 8])
        scheduler.scheduleRetry(fire: {})
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.nextDelay == 8)

        scheduler.scheduleRetry(resetBackoff: true, fire: {})
        #expect(scheduler.nextDelay == 4)   // used step 0, then advanced past it
    }

    /// `stop()` is what a view's `.onDisappear` calls — it must not leave a
    /// stale attempt count behind for the NEXT camera session to inherit.
    @Test func stopResetsTheAttemptCount() {
        let scheduler = UploadRetryScheduler(steps: [2, 4, 8])
        scheduler.scheduleRetry(fire: {})
        scheduler.scheduleRetry(fire: {})
        #expect(scheduler.attempt == 2)

        scheduler.stop()
        #expect(scheduler.attempt == 0)
        #expect(scheduler.nextDelay == 2)
    }

    /// The actual timer fires and calls back — this is the one place the
    /// class's async side needs a real wait rather than the pure
    /// attempt-counter above. Polls instead of sleeping a fixed window: this
    /// suite runs its tests in parallel alongside genuinely CPU-heavy ones
    /// (video export/compositing), and CI runners are slower still, so even a
    /// 15x-margin FIXED sleep-then-check (what this used to do) measured
    /// flaky in practice — a scheduling delay under load isn't proportional
    /// to the scheduled interval, so no fixed multiple of it is safe. Polling
    /// resolves in milliseconds in the common case and only spends the full
    /// budget under genuine contention or a real bug.
    @Test func fireRunsTheClosureAfterTheDelay() async throws {
        let scheduler = UploadRetryScheduler(steps: [0.01])
        let fired = Counter()
        scheduler.scheduleRetry { await fired.increment() }

        try await pollUntil { await fired.value == 1 }
        #expect(await fired.value == 1)
    }

    /// Scheduling again before the previous timer fires must cancel it — only
    /// ONE next attempt is ever in flight, or a burst of failures would stack
    /// up redundant fires.
    @Test func reschedulingCancelsThePendingTimer() async throws {
        let scheduler = UploadRetryScheduler(steps: [0.01, 0.01])
        let fired = Counter()
        scheduler.scheduleRetry { await fired.increment() }
        scheduler.scheduleRetry { await fired.increment() }   // supersedes the first

        try await pollUntil { await fired.value >= 1 }
        // Give an (incorrect) second fire a further window to show up before
        // asserting there wasn't one.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await fired.value == 1)
    }

    @Test func stopCancelsAPendingTimerEntirely() async throws {
        let scheduler = UploadRetryScheduler(steps: [0.01])
        let fired = Counter()
        scheduler.scheduleRetry { await fired.increment() }
        scheduler.stop()

        // Nothing to poll FOR here (asserting an absence) — a flat wait long
        // enough to have caught the fire above is the right shape.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await fired.value == 0)
    }

    /// Polls `condition` every 20ms for up to 5s. Succeeds the instant the
    /// condition is true rather than waiting out a fixed window — fast on a
    /// healthy machine, tolerant of a genuinely overloaded CI runner, and
    /// still fails (correctly) if the condition never becomes true.
    private func pollUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
