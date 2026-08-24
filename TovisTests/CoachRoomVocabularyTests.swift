// The room's words (camera plan P4.2, the wording half) — which corrections
// the station read may reword, what survives the substitution, and every
// refusal that keeps a canonical line standing.
import Foundation
import Testing
@testable import Tovis

@Suite struct CoachRoomVocabularyTests {
    private func room(window: Bool = false,
                      warmth: Double = 0, green: Double = 0) -> CoachRoomVocabulary {
        let cool = min(-0.1, CoachTuning.warmCastWarmth - 0.5)
        let spread = CoachTuning.mixedLightSpread + 0.05
        return CoachRoomVocabulary(profile: CoachStationRead.Profile(
            warmth: warmth, greenTint: green,
            thirdWarmths: window ? [cool, cool + spread, cool + spread] : [0, 0, 0],
            readAt: Date(timeIntervalSince1970: 0)))
    }

    private func nudge(_ moment: CoachMoment,
                       ctx: CoachPhraseContext = CoachPhraseContext()) -> CoachNudge {
        CoachNudge(category: .color, message: "canonical", moment: moment, phraseCtx: ctx)
    }

    private let booking = CoachBookingVocabulary(serviceName: "Caramel Balayage",
                                                 clientFullName: "Maya Lopez")

    // MARK: - The lines

    @Test func aKnownWindowRewordsTheColourTips() {
        let vocab = room(window: true)
        #expect(vocab.line(replacing: nudge(.colorWarm), vocabulary: .empty)
                == "Warm light — try the window")
        #expect(vocab.line(replacing: nudge(.colorGreenish), vocabulary: .empty)
                == "Greenish light — try the window")
    }

    @Test func theMixedLineNamesTheCastTheStationMeasured() {
        #expect(room(warmth: CoachTuning.warmCastWarmth + 0.05)
            .line(replacing: nudge(.colorMixed), vocabulary: .empty)
            == "Mixed light — turn off the warm overheads")
        #expect(room(green: CoachTuning.greenCastTint + 0.05)
            .line(replacing: nudge(.colorMixed), vocabulary: .empty)
            == "Mixed light — turn off the fluorescents")
        // A neutral station has nothing truer than canonical to say here.
        #expect(room(window: true).line(replacing: nudge(.colorMixed), vocabulary: .empty) == nil)
    }

    @Test func tooDarkPointsAtTheWindowAndStillNamesTheClient() {
        let vocab = room(window: true)
        let person = CoachPhraseContext(namesAPerson: true)
        #expect(vocab.line(replacing: nudge(.lightingTooDark, ctx: person), vocabulary: booking)
                == "Maya’s face is too dark — turn them toward the window")
        #expect(vocab.line(replacing: nudge(.lightingTooDark, ctx: person), vocabulary: .empty)
                == "Their face is too dark — turn them toward the window")
        // The flat-lay variant of the same moment is about a tray of nails —
        // the window still helps, the name would be #358's confidently-wrong
        // advice.
        #expect(vocab.line(replacing: nudge(.lightingTooDark), vocabulary: booking)
                == "Too dark — try the window")
    }

    /// ⚠️ No coaching line ever says the window's SIDE. It is only true from
    /// where the pro stood at setup, and mid-shoot the coach cannot know
    /// which way they are facing — a side would be #358's unverified sign
    /// convention wearing a room's name. Swept over every moment and both
    /// window sides, so a line added later that leaks one fails here.
    @Test func noLineEverNamesASide() {
        let cool = min(-0.1, CoachTuning.warmCastWarmth - 0.5)
        let spread = CoachTuning.mixedLightSpread + 0.05
        for thirds in [[cool, cool + spread, cool + spread],
                       [cool + spread, cool + spread, cool]] {
            let vocab = CoachRoomVocabulary(profile: CoachStationRead.Profile(
                warmth: 1, greenTint: 1, thirdWarmths: thirds,
                readAt: Date(timeIntervalSince1970: 0)))
            for moment in CoachMoment.allCases {
                for ctx in [CoachPhraseContext(), CoachPhraseContext(namesAPerson: true)] {
                    guard let line = vocab.line(replacing: nudge(moment, ctx: ctx),
                                                vocabulary: booking) else { continue }
                    #expect(!line.lowercased().contains("left")
                            && !line.lowercased().contains("right"),
                            "\(moment) leaked a side: “\(line)”")
                }
            }
        }
    }

    // MARK: - Refusals

    @Test func noReadMeansEveryCanonicalLineStands() {
        let vocab = CoachRoomVocabulary(profile: nil)
        #expect(vocab.isEmpty)
        for moment in CoachMoment.allCases {
            #expect(vocab.line(replacing: nudge(moment), vocabulary: booking) == nil, "\(moment)")
        }
    }

    @Test func aWindowlessRoomKeepsTheCanonicalWindowlessLines() {
        let vocab = room(warmth: CoachTuning.warmCastWarmth + 0.05)   // warm, no window
        #expect(vocab.line(replacing: nudge(.colorWarm), vocabulary: .empty) == nil)
        #expect(vocab.line(replacing: nudge(.colorGreenish), vocabulary: .empty) == nil)
        #expect(vocab.line(replacing: nudge(.lightingTooDark), vocabulary: .empty) == nil)
        // …while the cast it DID measure still speaks.
        #expect(vocab.line(replacing: nudge(.colorMixed), vocabulary: .empty) != nil)
    }

    /// Only the room's light is the room's to reword. Everything else — the
    /// framing, the camera, the person, the backdrop — has nothing truer in
    /// a station read, and rewording it would be noise dressed as knowledge.
    @Test func nothingOutsideTheColourAndLightMomentsIsTouched() {
        let vocab = room(window: true, warmth: 1, green: 1)
        let allowed: Set<CoachMoment> = [.colorWarm, .colorGreenish, .colorMixed, .lightingTooDark]
        for moment in CoachMoment.allCases where !allowed.contains(moment) {
            for ctx in [CoachPhraseContext(), CoachPhraseContext(namesAPerson: true)] {
                #expect(vocab.line(replacing: nudge(moment, ctx: ctx), vocabulary: booking) == nil,
                        "\(moment)")
            }
        }
    }

    // MARK: - What survives the substitution

    /// Words only: the category, the moment and the phrase context all ride
    /// through, so the dismissal offer, the packs and the drawer keep working
    /// off the same identity — the same contract as #358 and #360, and the
    /// structural half of "a station read moves no score".
    @Test func appliedChangesTheMessageAndNothingElse() {
        let vocab = room(window: true)
        let ctx = CoachPhraseContext(namesAPerson: true)
        let original = CoachNudge(category: .lighting, message: "canonical",
                                  moment: .lightingTooDark, phraseCtx: ctx)
        let reworded = vocab.applied(to: original, vocabulary: booking)
        #expect(reworded.message != original.message)
        #expect(reworded.category == original.category)
        #expect(reworded.moment == original.moment)
        #expect(reworded.phraseCtx == original.phraseCtx)

        let untouched = vocab.applied(to: nudge(.levelTilted), vocabulary: booking)
        #expect(untouched == nudge(.levelTilted))
    }

    /// The drawer reads the SAME substitution as the lane, so the two can
    /// never disagree about what the coach just said.
    @Test func theDrawerRowGetsTheSameWordsAsTheLane() {
        let vocab = room(window: true)
        let status = CoachStatus(category: .color, score: 0.5,
                                 message: "canonical", why: "why",
                                 moment: .colorWarm, phraseCtx: nil)
        let reworded = vocab.applied(to: status, vocabulary: .empty)
        #expect(reworded.message == "Warm light — try the window")
        #expect(reworded.score == status.score)
        #expect(reworded.why == status.why)
        #expect(reworded.moment == status.moment)

        // A passing row (no message) is untouched — there is nothing to reword.
        let passing = CoachStatus(category: .color, score: 1, message: nil)
        #expect(vocab.applied(to: passing, vocabulary: .empty).message == nil)
    }

    /// The plain form still wins while the coach is backing off (P4.3): the
    /// engine applies `CoachPlainLine` AFTER this vocabulary, and stripping a
    /// line down is not the moment to grow it a room clause. Asserted at the
    /// same seam the engine composes.
    @Test func theBackOffsPlainFormOutranksTheRoomsWords() {
        let vocab = room(warmth: CoachTuning.warmCastWarmth + 0.05)
        let spoken = vocab.applied(to: nudge(.colorMixed), vocabulary: .empty)
        #expect(spoken.message == "Mixed light — turn off the warm overheads")
        let plain = CoachPlainLine.applied(to: spoken, simplified: true, vocabulary: .empty)
        #expect(plain.message == "Turn off the overheads")
    }
}
