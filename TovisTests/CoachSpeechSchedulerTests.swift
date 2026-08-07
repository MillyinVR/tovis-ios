// Speech-delivery policy tests — pacing/coalescing, priority interrupt, and
// per-category repeat suppression. `CoachSpeechScheduler` is pure (no
// AVFoundation), so these are deterministic and don't sleep for real time to
// pass — same `now: TimeInterval` pattern as `CoachTipArbiterTests`.
import Testing
@testable import Tovis

@Suite struct CoachSpeechSchedulerTests {
    // MARK: - Pacing: at most one utterance in flight

    /// A tip that arrives while another tip is already speaking never starts
    /// a second utterance — it coalesces. This is what "no overlapping
    /// utterances" means for a synthesizer that can only say one thing at a
    /// time: the second request doesn't get its own `.speak`.
    @Test func aTipArrivingWhileATipIsSpeakingCoalescesRatherThanOverlapping() {
        var scheduler = CoachSpeechScheduler()
        let first = scheduler.request("Hold steady", priority: .tip)
        #expect(first == .speak("Hold steady"))

        let second = scheduler.request("Tap to focus", priority: .tip)
        #expect(second == .none, "a second tip while one is speaking must not start a new utterance")
    }

    /// Multiple requests arriving while the channel is busy don't queue up —
    /// only the LAST one survives to play once the channel frees. This is the
    /// "lines pile up" bug: the old behavior queued every directive, so a
    /// burst of them narrated several seconds of backlog after the fact.
    @Test func onlyTheFreshestCoalescedRequestPlaysWhenTheChannelFrees() {
        var scheduler = CoachSpeechScheduler()
        _ = scheduler.request("Next, the Front", priority: .directive)
        _ = scheduler.request("Next, the Left profile", priority: .directive)
        _ = scheduler.request("Next, the Right profile", priority: .directive)

        let freed = scheduler.channelFreed()
        #expect(freed == .speak("Next, the Right profile"), "only the freshest request should play — not a backlog of all three")
    }

    /// Nothing is pending → freeing the channel is a no-op, not a crash or a
    /// stray utterance.
    @Test func freeingAnIdleChannelDoesNothing() {
        var scheduler = CoachSpeechScheduler()
        let freed = scheduler.channelFreed()
        #expect(freed == .none)
    }

    // MARK: - Priority interrupt

    /// A directive arriving while a TIP is mid-flight interrupts it — it's
    /// the one thing the pro is actually waiting on.
    @Test func aDirectiveInterruptsATipInFlight() {
        var scheduler = CoachSpeechScheduler()
        _ = scheduler.request("Hold steady", priority: .tip)
        let action = scheduler.request("Got the Front.", priority: .directive)
        #expect(action == .interruptThenSpeak("Got the Front."))
    }

    /// Nothing interrupts a directive already speaking — a burst of
    /// directives coalesces (see above) rather than cutting each other off.
    @Test func aDirectiveDoesNotInterruptAnotherDirective() {
        var scheduler = CoachSpeechScheduler()
        _ = scheduler.request("Got the Front.", priority: .directive)
        let action = scheduler.request("Next, the Left profile.", priority: .directive)
        #expect(action == .none, "a directive-over-directive must coalesce, not interrupt")
    }

    /// A tip never interrupts anything, directive included — a routine
    /// correction doesn't get to cut off something the pro is deliberately
    /// waiting on.
    @Test func aTipNeverInterruptsADirective() {
        var scheduler = CoachSpeechScheduler()
        _ = scheduler.request("Got the Front.", priority: .directive)
        let action = scheduler.request("Hold steady", priority: .tip)
        #expect(action == .none)
    }

    /// After an interrupt, the channel freeing (the stop landing) is what
    /// actually starts the directive — not the original `request` call.
    @Test func theInterruptedDirectiveActuallyPlaysOnceTheChannelFrees() {
        var scheduler = CoachSpeechScheduler()
        _ = scheduler.request("Hold steady", priority: .tip)
        _ = scheduler.request("Got the Front.", priority: .directive)
        let freed = scheduler.channelFreed()
        #expect(freed == .speak("Got the Front."))
    }

    // MARK: - Per-category repeat suppression

    /// The core bug this exists to fix: the SAME fundamental's tip, spoken
    /// again well inside the cooldown, is suppressed — not re-spoken, not
    /// even coalesced (there's nothing useful to add).
    @Test func aTipForTheSameCategoryIsSuppressedWithinTheCooldown() {
        var scheduler = CoachSpeechScheduler(tipRepeatCooldown: 9)
        let first = scheduler.requestTip("Hold steady — shot looks soft", category: .sharpness, now: 0)
        #expect(first == .speak("Hold steady — shot looks soft"))
        _ = scheduler.channelFreed()   // finish speaking it

        let second = scheduler.requestTip("Hold steady — shot looks soft", category: .sharpness, now: 1)
        #expect(second == .none)
    }

    /// The flapping case specifically: the WORDING changes (soft → touch
    /// soft, a real re-wording within the same fundamental) but the category
    /// is the same — still suppressed. Suppressing only exact-moment repeats
    /// would let this alternation straight through, which is the actual bug
    /// reported ("hears the same line repeatedly").
    @Test func aDifferentlyWordedTipForTheSameCategoryIsAlsoSuppressed() {
        var scheduler = CoachSpeechScheduler(tipRepeatCooldown: 9)
        _ = scheduler.requestTip("Hold steady — shot looks soft", category: .sharpness, now: 0)
        _ = scheduler.channelFreed()

        let reworded = scheduler.requestTip("Tap to focus — a touch soft", category: .sharpness, now: 0.5)
        #expect(reworded == .none, "a re-worded tip for the SAME fundamental must still be suppressed")
    }

    /// Once the cooldown elapses, the same category is free to speak again —
    /// suppression is temporary, not permanent silence.
    @Test func theSameCategorySpeaksAgainOnceTheCooldownElapses() {
        var scheduler = CoachSpeechScheduler(tipRepeatCooldown: 9)
        _ = scheduler.requestTip("Hold steady", category: .sharpness, now: 0)
        _ = scheduler.channelFreed()

        let stillCooling = scheduler.requestTip("Hold steady", category: .sharpness, now: 8.9)
        #expect(stillCooling == .none)

        let cooledDown = scheduler.requestTip("Hold steady", category: .sharpness, now: 9.1)
        #expect(cooledDown == .speak("Hold steady"))
    }

    /// A DIFFERENT fundamental is never suppressed by another one's cooldown
    /// — lighting and sharpness cooling down independently.
    @Test func differentCategoriesHaveIndependentCooldowns() {
        var scheduler = CoachSpeechScheduler(tipRepeatCooldown: 9)
        _ = scheduler.requestTip("Hold steady", category: .sharpness, now: 0)
        _ = scheduler.channelFreed()

        let lighting = scheduler.requestTip("Turn toward the light", category: .lighting, now: 0.1)
        #expect(lighting == .speak("Turn toward the light"))
    }

}
