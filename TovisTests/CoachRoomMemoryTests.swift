// The coach's memory of a room (camera plan P4.1) — what it counts, what it
// will and won't retire, and what a threshold retune can and cannot do to it.
//
// Every test runs against its own `UserDefaults` suite, so nothing here can
// see, or leave behind, a real pro's dismissals.
import CoreGraphics
import Foundation
import Testing
@testable import Tovis

@Suite struct CoachRoomMemoryTests {
    /// A throwaway defaults suite per test. Removed on the way in so a crashed
    /// earlier run can't seed one.
    private func store(_ name: String = #function) -> UserDefaults {
        let suite = "tovis.test.room.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    private func salon(_ id: String = "loc-1", store: UserDefaults) -> CoachRoomMemory {
        CoachRoomMemory(locationId: id, locationType: "SALON", store: store)!
    }

    // MARK: - Which shoots get a room at all

    /// A MOBILE booking carries the PRO's own `ProfessionalLocation` id, not
    /// the house the pro drove to. Remembering it would let a dismissal made
    /// in one client's living room silence the coach in the next one.
    @Test func aMobileShootHasNoRoomToRemember() {
        #expect(CoachRoomMemory(locationId: "loc-1", locationType: "MOBILE", store: store()) == nil)
    }

    @Test func practiceAndAMissingLocationHaveNoRoomEither() {
        let s = store()
        #expect(CoachRoomMemory(locationId: nil, locationType: nil, store: s) == nil)
        #expect(CoachRoomMemory(locationId: nil, locationType: "SALON", store: s) == nil)
        #expect(CoachRoomMemory(locationId: "   ", locationType: "SALON", store: s) == nil)
    }

    @Test func aSalonBookingWithALocationHasOne() {
        #expect(CoachRoomMemory(locationId: "loc-1", locationType: "SALON", store: store()) != nil)
        // The wire value is the Prisma enum, but nothing downstream promises
        // its case, so the comparison doesn't depend on it.
        #expect(CoachRoomMemory(locationId: "loc-1", locationType: "salon", store: store()) != nil)
    }

    // MARK: - The Nth repeat, not the first

    /// Tori's line for the phase — "a photographer who has shot in your salon
    /// TWICE stops mentioning the overheads". So the offer lands on the third
    /// shoot, after the two it takes to learn the room. Offering on the first
    /// would turn every tip into a dismissal prompt, which is the opposite
    /// feature.
    @Test func theOfferArrivesOnTheThirdShootNotTheFirst() {
        let s = store()
        for shoot in 1...CoachRoomMemory.shootsBeforeOffering {
            let memory = salon(store: s)          // a new shoot = a new instance
            memory.noteShown(.colorMixed)
            let expected = shoot >= CoachRoomMemory.shootsBeforeOffering
            #expect(memory.shouldOfferDismissal(of: .colorMixed) == expected,
                    "shoot \(shoot): offer \(memory.shouldOfferDismissal(of: .colorMixed))")
        }
    }

    /// A tip on screen for two minutes is ONE experience of it. Counting
    /// frames would put the offer up inside the first shoot.
    @Test func aTipShownAllShootLongCountsOnce() {
        let s = store()
        let memory = salon(store: s)
        for _ in 0..<500 { memory.noteShown(.colorMixed) }
        #expect(memory.shootsShown(.colorMixed) == 1)
        #expect(!memory.shouldOfferDismissal(of: .colorMixed))
    }

    @Test func eachRoomCountsSeparately() {
        let s = store()
        for _ in 0..<5 { salon("loc-A", store: s).noteShown(.colorMixed) }
        #expect(salon("loc-B", store: s).shootsShown(.colorMixed) == 0)
        #expect(!salon("loc-B", store: s).shouldOfferDismissal(of: .colorMixed))
    }

    // MARK: - What may be retired

    /// The allowlist is the whole difference between "it learned my room" and
    /// "there's a button that switches the coach off". Only the room's light
    /// and the room's backdrop — everything else is answered by the next frame.
    @Test func onlyRoomConditionsAreDismissible() {
        #expect(CoachRoomMemory.dismissible == [.colorMixed, .colorGreenish, .colorWarm, .backgroundBusy])
        for actionable: CoachMoment in [.compositionTooFar, .compositionRecenter, .levelTilted,
                                        .sharpnessHoldSteady, .lightingBacklit, .poseClipped] {
            #expect(!CoachRoomMemory.dismissible.contains(actionable),
                    "\(actionable) is something the very next frame can fix")
        }
    }

    @Test func dismissingSomethingOutsideTheAllowlistChangesNothing() {
        let memory = salon(store: store())
        #expect(memory.dismiss(.compositionTooFar) == false)
        #expect(memory.dismissedMoments.isEmpty)
        #expect(!memory.isDismissed(.compositionTooFar))
    }

    /// Filtered on the way OUT as well as in, so a record written by a build
    /// with a wider allowlist — or a hand-edited defaults plist — can never
    /// retire a correction the pro can act on.
    @Test func aStoredDismissalOutsideTheAllowlistIsIgnoredOnRead() {
        let s = store()
        s.set(true, forKey: CoachRoomMemory.dismissedKey(locationId: "loc-1", moment: .compositionTooFar))
        let memory = salon(store: s)
        #expect(memory.dismissedMoments.isEmpty)
    }

    /// Every dismissible moment is an ordinary `.correction` at its coach, so
    /// nothing in the allowlist can retire a lost frame even before
    /// `CoachTipArbiter`'s own refusal. Read off the real coaches rather than
    /// asserted, so a future severity change here fails loudly.
    @Test func nothingDismissibleIsEverAHardFailure() {
        let ctx = FrameContext(
            avgLuma: 0.5, faceBounds: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4),
            faceLuma: 0.5, backgroundLuma: 0.5, sharpness: 1,
            // Every colour signal and the backdrop pinned past their thresholds,
            // so both coaches are definitely speaking.
            backgroundClutter: 1, subjectFill: 0.4, pose: nil, deviceTilt: 0,
            color: ColorSignal(mixed: 1, greenTint: 1, warmth: 1, backgroundScoped: true),
            expectations: nil)
        for coach in [ColorCoach() as ShotCoach, BackgroundCoach()] {
            let signal = coach.evaluate(ctx)
            if let moment = signal.moment, CoachRoomMemory.dismissible.contains(moment) {
                #expect(signal.severity == .correction, "\(moment) has become a hard failure")
            }
        }
    }

    // MARK: - Dismissing

    @Test func aDismissedTipStaysDismissedAcrossShoots() {
        let s = store()
        #expect(salon(store: s).dismiss(.colorMixed))
        let laterShoot = salon(store: s)
        #expect(laterShoot.isDismissed(.colorMixed))
        #expect(laterShoot.dismissedMoments == [.colorMixed])
        #expect(!laterShoot.shouldOfferDismissal(of: .colorMixed), "already retired — nothing left to offer")
    }

    @Test func aDismissedTipStopsCounting() {
        let s = store()
        let memory = salon(store: s)
        memory.noteShown(.colorMixed)
        memory.dismiss(.colorMixed)
        let before = memory.shootsShown(.colorMixed)
        for _ in 0..<5 { salon(store: s).noteShown(.colorMixed) }
        #expect(salon(store: s).shootsShown(.colorMixed) == before)
    }

    @Test func retiringOneTipLeavesTheOthersAlone() {
        let s = store()
        salon(store: s).dismiss(.colorMixed)
        let memory = salon(store: s)
        #expect(memory.isDismissed(.colorMixed))
        #expect(!memory.isDismissed(.backgroundBusy))
        #expect(!memory.isDismissed(.colorGreenish))
    }

    // MARK: - The per-frame rule the engine runs

    @Test func theOfferIsWithheldUntilTheTipHasEarnedItAndThenStands() {
        let s = store()
        for shoot in 1...4 {
            let memory = salon(store: s)
            let offer = memory.offer(forRaw: .colorMixed, published: .colorMixed)
            #expect((offer != nil) == (shoot >= CoachRoomMemory.shootsBeforeOffering),
                    "shoot \(shoot)")
        }
    }

    /// A match look's bespoke direction replaces the whole correction and
    /// strips the moment. The condition is the same one, so it still counts
    /// toward the room — but "GOT IT" must not sit beside words that no
    /// longer mention the overheads.
    @Test func aLookLineStillCountsButIsNeverOfferedAgainst() {
        let s = store()
        for _ in 0..<10 {
            #expect(salon(store: s).offer(forRaw: .colorMixed, published: nil) == nil)
        }
        #expect(salon(store: s).shootsShown(.colorMixed) == 10, "the sightings were still real")
        #expect(salon(store: s).offer(forRaw: .colorMixed, published: .colorMixed) == .colorMixed,
                "…and the offer lands as soon as the coach's own words are back")
    }

    @Test func noTipMeansNoOfferAndNoCount() {
        let s = store()
        #expect(salon(store: s).offer(forRaw: nil, published: nil) == nil)
        for moment in CoachRoomMemory.dismissible {
            #expect(salon(store: s).shootsShown(moment) == 0)
        }
    }

    /// A correction the pro can act on is counted by nothing and offered
    /// against nothing, however often it is on screen.
    @Test func anActionableTipIsNeverCountedOrOffered() {
        let s = store()
        for _ in 0..<20 {
            #expect(salon(store: s).offer(forRaw: .compositionTooFar,
                                          published: .compositionTooFar) == nil)
        }
        #expect(salon(store: s).shootsShown(.compositionTooFar) == 0)
    }

    // MARK: - Undo

    /// A dismissal is permanent and one tap deep, reached from a control the
    /// pro has never seen before. The way back has to exist.
    @Test func aMistakenDismissalCanBePutBack() {
        let s = store()
        let memory = salon(store: s)
        memory.dismiss(.colorMixed)
        #expect(memory.restore(.colorMixed))
        #expect(!memory.isDismissed(.colorMixed))
        #expect(!salon(store: s).isDismissed(.colorMixed), "and it stays back across shoots")
    }

    /// Restoring leaves the shoot count where it was, so a pro who DID mean it
    /// is offered the tap again immediately rather than having to earn the
    /// offer a second time.
    @Test func undoLeavesTheOfferStandingForAProWhoDidMeanIt() {
        let s = store()
        for _ in 0..<CoachRoomMemory.shootsBeforeOffering { salon(store: s).noteShown(.colorMixed) }
        let memory = salon(store: s)
        #expect(memory.shouldOfferDismissal(of: .colorMixed))
        memory.dismiss(.colorMixed)
        #expect(!memory.shouldOfferDismissal(of: .colorMixed))
        memory.restore(.colorMixed)
        #expect(memory.shouldOfferDismissal(of: .colorMixed))
    }

    @Test func restoringSomethingThatWasNeverDismissedChangesNothing() {
        let memory = salon(store: store())
        #expect(memory.restore(.colorMixed) == false)
        #expect(memory.restore(.compositionTooFar) == false)
    }

    // MARK: - The retune question

    /// The decision recorded at the top of `CoachRoomMemory`: the record is
    /// keyed on tip-id + location and NOTHING else, so moving
    /// `mixedLightSpread` or `clutterReference` — which P1's salon pass will
    /// do — cannot resurrect a tip the pro already retired. A dismissal is a
    /// statement about the salon, and the salon didn't change when the
    /// constant did.
    ///
    /// Proved by reading the WHOLE persisted record rather than by moving the
    /// live thresholds: those are process-global `static var`s, and writing
    /// them here would race every other suite Swift Testing runs in parallel.
    /// If the only two keys the feature writes are built from location + tip +
    /// meaning version, there is nothing for a retune to reach.
    @Test func aThresholdRetuneCannotResurrectADismissal() {
        let s = store()
        let memory = salon(store: s)
        memory.noteShown(.colorMixed)
        memory.dismiss(.colorMixed)

        let written = s.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("tovis.coach.room.") }
            .sorted()
        #expect(written == [
            CoachRoomMemory.countKey(locationId: "loc-1", moment: .colorMixed),
            CoachRoomMemory.dismissedKey(locationId: "loc-1", moment: .colorMixed),
        ].sorted(), "the feature wrote something other than location + tip: \(written)")

        for key in written {
            for value in ["\(CoachTuning.mixedLightSpread)", "\(CoachTuning.clutterReference)",
                          "\(CoachTuning.clutterBusy)", "\(CoachTuning.greenCastTint)",
                          "\(CoachTuning.warmCastWarmth)"] {
                #expect(!key.contains(value), "a threshold value reached the key: \(key)")
            }
        }
        // …and the record reads back through a fresh instance, which is the
        // only path a later shoot has to it.
        #expect(salon(store: s).isDismissed(.colorMixed))
    }

    /// …and the deliberate escape hatch for the other half of that trade: a
    /// retune that genuinely changes what a moment CLAIMS about a room bumps
    /// its meaning version, in a diff, and every dismissal of it is forgotten
    /// at once. Empty today, which is what this pins — the key format has to
    /// actually carry the version or the hatch is decorative.
    @Test func aMeaningVersionBumpIsTheOnlyThingThatForgetsADismissal() {
        #expect(CoachRoomMemory.meaningVersions.isEmpty,
                "no moment has been redefined yet — bumping one forgets every pro's dismissal of it")
        let v1 = CoachRoomMemory.dismissedKey(locationId: "loc-1", moment: .colorMixed)
        #expect(v1.contains(".v1."), "the key must carry the meaning version: \(v1)")
        #expect(v1.contains("loc-1") && v1.contains("colorMixed"),
                "…and the location and the tip id, and nothing else: \(v1)")
    }

    // MARK: - The station read (P4.2)

    private func read(warmth: Double = 0, green: Double = 0,
                      thirds: [Double] = [0, 0, 0],
                      readAt: Date) -> CoachStationRead.Profile {
        CoachStationRead.Profile(warmth: warmth, greenTint: green,
                                 thirdWarmths: thirds, readAt: readAt)
    }

    @Test func aStationReadIsRememberedAcrossShoots() {
        let s = store()
        let taken = Date(timeIntervalSince1970: 1_000_000)
        salon(store: s).recordStationRead(read(warmth: 0.4, thirds: [-0.2, 0.1, 0.2],
                                               readAt: taken))
        let later = salon(store: s).stationProfile(now: taken.addingTimeInterval(3600))
        #expect(later == read(warmth: 0.4, thirds: [-0.2, 0.1, 0.2], readAt: taken))
    }

    @Test func eachRoomHasItsOwnRead() {
        let s = store()
        let taken = Date(timeIntervalSince1970: 1_000_000)
        salon("loc-A", store: s).recordStationRead(read(readAt: taken))
        #expect(salon("loc-B", store: s).stationProfile(now: taken) == nil)
    }

    /// A salon's light does change — a bulb, a rearrange, a season — and the
    /// coach cannot see it happen. An aged-out read is treated as no read at
    /// all: the words go back to canonical, the offer goes back to three
    /// shoots, and the hub's setup card returns.
    @Test func aStaleReadExpiresOnItsOwn() {
        let s = store()
        let taken = Date(timeIntervalSince1970: 1_000_000)
        salon(store: s).recordStationRead(read(readAt: taken))
        let memory = salon(store: s)
        #expect(memory.stationProfile(
            now: taken.addingTimeInterval(CoachRoomMemory.stationReadMaxAge)) != nil)
        #expect(memory.stationProfile(
            now: taken.addingTimeInterval(CoachRoomMemory.stationReadMaxAge + 1)) == nil)
        // A read stamped in the future is a broken clock, not a fresh read.
        #expect(memory.stationProfile(now: taken.addingTimeInterval(-1)) == nil)
    }

    @Test func aReReadReplacesTheOldRead() {
        let s = store()
        let first = Date(timeIntervalSince1970: 1_000_000)
        salon(store: s).recordStationRead(read(warmth: 0.5, readAt: first))
        let again = first.addingTimeInterval(3600)
        salon(store: s).recordStationRead(read(warmth: 0.0, readAt: again))
        #expect(salon(store: s).stationProfile(now: again)?.warmth == 0.0)
    }

    // MARK: - The corroborated offer (the read pairs with the dismissal)

    /// The three-shoot wait exists because the coach cannot tell a room
    /// condition from a circumstance. A station read the pro took of the
    /// EMPTY station is that telling-apart — the room itself measured warm —
    /// so the offer lands the first time the tip fires here.
    @Test func aCorroboratedTipIsOfferedOnTheFirstShoot() {
        let s = store()
        let taken = Date(timeIntervalSince1970: 1_000_000)
        salon(store: s).recordStationRead(read(warmth: CoachTuning.warmCastWarmth + 0.05,
                                               readAt: taken))
        let memory = salon(store: s)
        let now = taken.addingTimeInterval(3600)
        #expect(memory.offer(forRaw: .colorWarm, published: .colorWarm, now: now) == .colorWarm)
        // …and only for what the station actually measured: the others still
        // earn the offer the slow way.
        #expect(!memory.shouldOfferDismissal(of: .colorGreenish, now: now))
        #expect(!memory.shouldOfferDismissal(of: .colorMixed, now: now))
        #expect(!memory.shouldOfferDismissal(of: .backgroundBusy, now: now))
    }

    /// The offer comes early; the DISMISSAL is still the pro's tap, and an
    /// already-dismissed tip has nothing left to offer.
    @Test func corroborationMovesTheOfferNotTheDismissal() {
        let s = store()
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let now = taken.addingTimeInterval(3600)
        salon(store: s).recordStationRead(read(warmth: CoachTuning.warmCastWarmth + 0.05,
                                               readAt: taken))
        let memory = salon(store: s)
        #expect(!memory.isDismissed(.colorWarm), "the read itself retired nothing")
        memory.dismiss(.colorWarm)
        #expect(!memory.shouldOfferDismissal(of: .colorWarm, now: now))
    }

    @Test func anExpiredReadStopsCorroboratingButTheCountStillStands() {
        let s = store()
        let taken = Date(timeIntervalSince1970: 1_000_000)
        salon(store: s).recordStationRead(read(warmth: CoachTuning.warmCastWarmth + 0.05,
                                               readAt: taken))
        let stale = taken.addingTimeInterval(CoachRoomMemory.stationReadMaxAge + 1)
        let memory = salon(store: s)
        #expect(!memory.shouldOfferDismissal(of: .colorWarm, now: stale))
        for _ in 0..<CoachRoomMemory.shootsBeforeOffering { salon(store: s).noteShown(.colorWarm) }
        #expect(salon(store: s).shouldOfferDismissal(of: .colorWarm, now: stale),
                "the slow path still works under a stale read")
    }

    /// The read and the dismissals live under SEPARATE keys, so a re-read can
    /// never touch what the pro has retired, and the retired set can never
    /// leak into what the room measured — the same orthogonality the retune
    /// decision demands, proved the same way (by the persisted record).
    @Test func aStationReadTouchesNoDismissalKey() {
        let s = store()
        let memory = salon(store: s)
        memory.dismiss(.colorMixed)
        let before = s.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("tovis.coach.room.") && !$0.contains(".station.") }.sorted()
        memory.recordStationRead(read(warmth: 1, readAt: Date(timeIntervalSince1970: 1)))
        let after = s.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("tovis.coach.room.") && !$0.contains(".station.") }.sorted()
        #expect(before == after, "a read wrote outside its own namespace")
        #expect(salon(store: s).isDismissed(.colorMixed))
        let stationKeys = s.dictionaryRepresentation().keys.filter { $0.contains(".station.") }
        #expect(stationKeys.allSatisfy { $0.contains(".station.v1.") },
                "station keys must carry their schema version: \(stationKeys)")
    }

    // MARK: - The one sentence it says back

    @Test func everyDismissibleTipHasItsOwnConfirmation() {
        var seen: Set<String> = []
        for moment in CoachRoomMemory.dismissible {
            let line = CoachRoomMemory.confirmation(for: moment)
            #expect(line != nil, "\(moment) can be retired with nothing to say about it")
            #expect(seen.insert(line ?? "").inserted,
                    "\(moment) reuses another condition's confirmation: \(line ?? "")")
        }
    }

    @Test func nothingOutsideTheAllowlistHasAConfirmation() {
        for moment in CoachMoment.allCases where !CoachRoomMemory.dismissible.contains(moment) {
            #expect(CoachRoomMemory.confirmation(for: moment) == nil, "\(moment)")
        }
    }
}
