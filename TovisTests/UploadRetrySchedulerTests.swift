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
    /// attempt-counter above. Margins are generous (15x the scheduled delay)
    /// because this suite runs its tests in parallel alongside genuinely
    /// CPU-heavy ones (video export/compositing) — a tight margin here would
    /// be a flaky test, not a meaningful assertion.
    @Test func fireRunsTheClosureAfterTheDelay() async throws {
        let scheduler = UploadRetryScheduler(steps: [0.1])
        let fired = Counter()
        scheduler.scheduleRetry { await fired.increment() }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await fired.value == 1)
    }

    /// Scheduling again before the previous timer fires must cancel it — only
    /// ONE next attempt is ever in flight, or a burst of failures would stack
    /// up redundant fires.
    @Test func reschedulingCancelsThePendingTimer() async throws {
        let scheduler = UploadRetryScheduler(steps: [0.1, 0.1])
        let fired = Counter()
        scheduler.scheduleRetry { await fired.increment() }
        scheduler.scheduleRetry { await fired.increment() }   // supersedes the first

        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await fired.value == 1)
    }

    @Test func stopCancelsAPendingTimerEntirely() async throws {
        let scheduler = UploadRetryScheduler(steps: [0.1])
        let fired = Counter()
        scheduler.scheduleRetry { await fired.increment() }
        scheduler.stop()

        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await fired.value == 0)
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
