import Foundation
import Testing
@testable import TovisKit

/// Book the Look, slice B8 — the look-anchored consult and its booking door.
///
/// Every test here decodes the SAME fixtures the cross-repo contract job
/// validates against tovis-app's generated schema, so the two check the wire
/// from both sides: shape (ajv) and decode (Swift).
@Suite struct ConsultBookTheLookTests {
    private func root(_ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func proposalArm(_ key: String) throws -> ConsultBookingProposalAvailability {
        let arm = try #require(try root("consultProposal")[key] as? [String: Any])
        return try decode(ConsultBookingProposalResponse.self, value: arm).proposal
    }

    private func availabilityArm(_ key: String) throws -> ConsultLookAvailability {
        let arm = try #require(try root("consultLookAvailability")[key] as? [String: Any])
        return try decode(ConsultLookAvailabilityResponse.self, value: arm).availability
    }

    // MARK: - The look-anchored consult

    @Test func aLookAnchoredConsultDecodesItsOwnShape() throws {
        let arm = try #require(try root("consultFlow")["lookSession"])
        let consult = try decode(ConsultLookSessionResponse.self, value: arm).consult
        #expect(consult.lookPostId == "look_fixture_1")
        #expect(consult.status == .consentRequired)
    }

    /// 🔴 The decode that a non-optional `bookingId` used to fail outright. A
    /// look-anchored consult answers `bookingId: null`, and the booking-anchored
    /// one omits `lookPostId` entirely — exactly one anchor is ever set.
    @Test func resultsCarryExactlyOneAnchorAndBothDecode() throws {
        let flow = try root("consultFlow")

        let booking = try decode(
            ConsultClientResultsResponse.self, value: try #require(flow["results"])).results
        #expect(booking.bookingId == "booking_fixture_1")
        #expect(booking.lookPostId == nil)

        let look = try decode(
            ConsultClientResultsResponse.self, value: try #require(flow["lookResults"])).results
        #expect(look.bookingId == nil)
        #expect(look.lookPostId == "look_fixture_1")
    }

    /// The founder gate must leak NOTHING: a dark answer is `available: false`
    /// with no reason at all, indistinguishable from a client who simply has no
    /// consult. A named refusal is only for the two things saying so is safe.
    @Test func aDarkLookAnswersUnavailableWithNoReasonAtAll() throws {
        let dark = try availabilityArm("dark")
        #expect(dark.available == false)
        #expect(dark.reason == nil)
        #expect(dark.consult == nil)

        let unlinked = try availabilityArm("serviceUnlinked")
        #expect(unlinked.available == false)
        #expect(unlinked.reason == .lookServiceUnlinked)
    }

    /// An unrecognised code must decode to `.unknown` and render the
    /// reason-agnostic message. A build that failed to decode a tenth code would
    /// turn an explained refusal into a crash.
    @Test func anUnrecognisedRefusalReasonDecodesRatherThanThrowing() throws {
        let value: [String: Any] = ["available": false, "reason": "A_CODE_FROM_THE_FUTURE",
                                    "consult": NSNull()]
        let decoded = try decode(ConsultLookAvailability.self, value: value)
        #expect(decoded.reason == .unknown)

        let proposal: [String: Any] = ["available": false, "reason": "A_CODE_FROM_THE_FUTURE",
                                       "proposal": NSNull(), "professionalId": "pro_1"]
        let answer = try decode(ConsultBookingProposalAvailability.self, value: proposal)
        #expect(answer.reason == .unknown)
        #expect(ConsultBookingCopy.refusalMessage(answer.reason)
                == ConsultBookingCopy.refusalMessage(nil))
    }

    // MARK: - What a Book tap resolves to

    @Test func aCompletedConsultOpensTheBookingDoorAndAnythingElseResumes() {
        #expect(LookConsultEntry.destination(for: .completed, consultId: "c1")
                == .bookingProposal(consultId: "c1"))
        #expect(LookConsultEntry.destination(for: .consentRequired, consultId: "c1")
                == .resumeFlow(consultId: "c1"))
        #expect(LookConsultEntry.destination(for: .analyzing, consultId: "c1")
                == .resumeFlow(consultId: "c1"))
        // No id is no destination — never a sheet that cannot address anything.
        #expect(LookConsultEntry.destination(for: .completed, consultId: "   ") == nil)
    }

    // MARK: - The proposal

    @Test func theFloorAloneIsTheDefaultAndNothingArrivesTicked() throws {
        let answer = try proposalArm("salonFloorOnly")
        let proposal = try #require(answer.proposal)
        #expect(answer.available)
        #expect(proposal.recommendations.allSatisfy { !$0.selected })
        // 🔴 The promise the whole slice rests on: nothing is added unless she
        // adds it, so the finalize sends an EMPTY list until she does.
        #expect(proposal.selectedEnhancementLineIds.isEmpty)
        #expect(proposal.lines.count == 1)
    }

    @Test func aTickedEnhancementIsOnTheLinesAndOnTheAnswer() throws {
        let proposal = try #require(try proposalArm("salonOneEnhancementSelected").proposal)
        #expect(proposal.selectedEnhancementLineIds == ["estimate_line_gloss_1"])
        // The server re-derived the WHOLE proposal: the enhancement is a LINE
        // now, and the total moved with it. Nothing was summed on the device.
        #expect(proposal.lines.count == 2)
        #expect(proposal.totalDurationMinutes == 270)
        #expect(proposal.startingAtLabel == "Starting at $330")
    }

    /// The ids the next question and the finalize send are the SERVER's own
    /// order, not the order she happened to tap in.
    @Test func selectedIdsFollowTheServersOrder() throws {
        let proposal = ConsultBookingProposal(
            consultId: "c", locationType: "SALON", offeringId: "o",
            professionalId: "p", serviceId: "s", lookPostId: "l",
            totalDurationMinutes: 60, startingAtPrice: "10.00",
            startingAtLabel: nil, estimateNote: "", proDecidesNote: "",
            autoAccepts: false, commitNote: "", lines: [],
            recommendations: [
                .init(estimateLineId: "a", outcome: "", priceDeltaLabel: nil,
                      durationDeltaLabel: nil, selected: true),
                .init(estimateLineId: "b", outcome: "", priceDeltaLabel: nil,
                      durationDeltaLabel: nil, selected: false),
                .init(estimateLineId: "c", outcome: "", priceDeltaLabel: nil,
                      durationDeltaLabel: nil, selected: true),
            ])
        #expect(proposal.selectedEnhancementLineIds == ["a", "c"])
    }

    /// A complimentary enhancement has no price delta and an instant one has no
    /// duration delta — both arrive nil so no surface ever prints "+$0".
    @Test func aMissingDeltaIsNilRatherThanZero() throws {
        let proposal = try #require(try proposalArm("salonFloorOnly").proposal)
        let bond = try #require(
            proposal.recommendations.first { $0.estimateLineId == "estimate_line_bond_1" })
        #expect(bond.priceDeltaLabel == nil)
        #expect(bond.durationDeltaLabel == "+15 min")
    }

    /// Decision 5: a non-positive total renders as NO price rather than "$0",
    /// and the framing lines stay either way — "we can't quote this" still needs
    /// "your professional makes the final call" beside it.
    @Test func anUnquotableProposalRendersNoPriceButKeepsItsFraming() throws {
        let proposal = try #require(try proposalArm("noRecommendations").proposal)
        #expect(proposal.startingAtLabel == nil)
        #expect(!proposal.estimateNote.isEmpty)
        #expect(!proposal.proDecidesNote.isEmpty)
        // No recommendations means no section at all, not an empty one.
        #expect(proposal.recommendations.isEmpty)
    }

    /// Every refusal is a rendered, explained state. Each code gets its own
    /// sentence, and the safety one — the load-bearing refusal — says the test
    /// has to happen with the professional first.
    @Test func everyRefusalCodeHasItsOwnExplanation() throws {
        let codes: [ConsultBookingProposalRefusalCode] = [
            .estimateMissing, .estimateRefused, .safetyReviewRequired, .offeringOffMenu,
            .modeNotOffered, .modePriceUnset, .modeDurationUnset,
            .proSchedulingNotReady, .slotTooLong,
        ]
        let messages = codes.map { ConsultBookingCopy.refusalMessage($0) }
        #expect(Set(messages).count == codes.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(ConsultBookingCopy.refusalMessage(.safetyReviewRequired)
            .contains("with your professional first"))

        // A refusal still carries the way OUT of it — the pro's id, so the
        // device never has to assemble one.
        let refusal = try proposalArm("safetyReviewRequired")
        #expect(refusal.available == false)
        #expect(refusal.proposal == nil)
        #expect(!refusal.professionalId.isEmpty)
    }

    /// 🔴 A LOOK never names the service that produced it (B1). The wire simply
    /// does not carry a service name on a recommendation, which is what makes
    /// that rule impossible to break by a careless render.
    @Test func aRecommendationCarriesNoServiceNameOnTheWire() throws {
        let arm = try #require(try root("consultProposal")["salonFloorOnly"] as? [String: Any])
        let proposal = try #require(
            (arm["proposal"] as? [String: Any])?["proposal"] as? [String: Any])
        let recommendations = try #require(proposal["recommendations"] as? [[String: Any]])
        #expect(!recommendations.isEmpty)
        for recommendation in recommendations {
            #expect(recommendation["serviceName"] == nil)
            let outcome = try #require(recommendation["outcome"] as? String)
            #expect(!outcome.isEmpty)
        }
    }
}

/// The reducer's half: every response must keep naming the anchor the flow was
/// opened on.
@Suite struct ConsultAnchorTests {
    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        let root = try #require(
            JSONSerialization.jsonObject(with: fixture("consultFlow")) as? [String: Any])
        return try JSONDecoder().decode(
            T.self, from: JSONSerialization.data(withJSONObject: try #require(root[key])))
    }

    @Test func aLookSessionBindsALookAnchoredMachine() throws {
        let consult = try decode(ConsultLookSessionResponse.self, key: "lookSession").consult
        var machine = ConsultFlowMachine(anchor: .look(consult.lookPostId))
        try machine.apply(lookSession: consult)
        #expect(machine.consultId == consult.id)
        #expect(machine.stage == .prerequisites)
    }

    @Test func aLookSessionForAnotherLookIsRefused() throws {
        let consult = try decode(ConsultLookSessionResponse.self, key: "lookSession").consult
        var machine = ConsultFlowMachine(anchor: .look("some_other_look"))
        #expect(throws: ConsultClientFailure.self) {
            try machine.apply(lookSession: consult)
        }
    }

    /// 🔴 The nil-vs-nil trap. A booking-anchored flow must NOT accept
    /// look-anchored results just because both `lookPostId`s happen to be
    /// absent — the check is against the anchor's OWN field.
    @Test func resultsForTheOtherAnchorAreRefusedBothWays() throws {
        let bookingResults = try decode(ConsultClientResultsResponse.self, key: "results").results
        let lookResults = try decode(ConsultClientResultsResponse.self, key: "lookResults").results

        var lookMachine = ConsultFlowMachine(anchor: .look("look_fixture_1"))
        #expect(throws: ConsultClientFailure.self) {
            try lookMachine.apply(results: bookingResults)
        }

        var bookingMachine = ConsultFlowMachine(anchor: .booking("booking_fixture_1"))
        #expect(throws: ConsultClientFailure.self) {
            try bookingMachine.apply(results: lookResults)
        }
    }

    @Test func aLookAnchoredMachineAcceptsItsOwnResults() throws {
        let lookResults = try decode(ConsultClientResultsResponse.self, key: "lookResults").results
        var machine = ConsultFlowMachine(anchor: .look("look_fixture_1"))
        try machine.apply(results: lookResults)
        #expect(machine.stage == .results)
    }

    @Test func theBookingConvenienceInitStillBuildsABookingAnchor() {
        #expect(ConsultFlowMachine(bookingId: "b1").anchor == .booking("b1"))
        #expect(ConsultFlowMachine(bookingId: "b1").anchor.lookPostId == nil)
    }
}
