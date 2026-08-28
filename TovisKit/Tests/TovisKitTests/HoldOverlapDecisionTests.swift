import Foundation
import Testing

@testable import TovisKit

// The pro's live-hold decision, on the wire and in words (Tori, 2026-08-28).
//
// B5 made a client's checkout an anonymous tile on the pro's calendar. This is
// the popup shown when a pro tries to book over one, and the ONE thing it adds
// to that anonymity is new-or-returning-to-this-pro.
//
// 🔴 The load-bearing assertions are the ABSENCE ones: a decoder that produced
// the right seven fields would pass a "renders correctly" test just as happily
// while also carrying a name. `HeldSlotDecision` has nowhere to put one, and
// these pin that it stays that way.
@Suite struct HoldOverlapDecisionTests {

    /// The identity of the client behind the hold. None of it is a field of
    /// `HeldSlotDecision` — that is the point.
    private static let heldClientName = "Marguerite Okonkwo"
    private static let heldClientEmail = "marguerite.okonkwo@example.com"
    private static let heldClientPhone = "+15558675309"

    private func errorBody(
        code: String = holdOverlapDecisionCode,
        heldSlot: String? = """
        {
          "holdId": "hold_1",
          "relationship": "RETURNING",
          "serviceName": "Signature Manicure",
          "startsAt": "2026-09-01T19:00:00.000Z",
          "endsAt": "2026-09-01T20:15:00.000Z",
          "expiresAt": "2026-09-01T18:40:00.000Z",
          "additionalHeldSlots": 0
        }
        """
    ) -> Data {
        let slot = heldSlot.map { ", \"heldSlot\": \($0)" } ?? ""
        return Data("""
        {
          "ok": false,
          "error": "A client is checking out for this time right now.",
          "code": "\(code)",
          "retryable": false,
          "uiAction": "NONE",
          "message": "A live client hold covers this time."\(slot)
        }
        """.utf8)
    }

    private func decodeDetails(_ data: Data) throws -> ServerErrorDetails {
        let parsed = try JSONDecoder().decode(APIErrorBody.self, from: data)
        return ServerErrorDetails(
            maskedDestination: parsed.maskedDestination,
            claimLinkSent: parsed.claimLinkSent,
            retryAfterSeconds: parsed.details?.retryAfterSeconds,
            heldSlot: parsed.heldSlot?.decoded()
        )
    }

    // MARK: - Decoding

    @Test func decodesTheDecisionOffTheFailureBody() throws {
        let decision = try #require(decodeDetails(errorBody()).heldSlot)

        #expect(decision.holdId == "hold_1")
        #expect(decision.relationship == .returning)
        #expect(decision.serviceName == "Signature Manicure")
        #expect(decision.additionalHeldSlots == 0)
        #expect(decision.expiresAt == Wire.date("2026-09-01T18:40:00.000Z"))
    }

    @Test func readsTheDecisionStraightOffAnAPIError() throws {
        let decision = try #require(decodeDetails(errorBody()).heldSlot)
        let error = APIError.serverDetails(
            status: 409,
            message: "x",
            code: holdOverlapDecisionCode,
            details: ServerErrorDetails(heldSlot: decision)
        )

        #expect(error.holdOverlapDecision?.holdId == "hold_1")
    }

    // Every other booking failure keeps its ordinary handling — the sheet must
    // not hijack a TIME_BOOKED that happens to carry a stray key.
    @Test func ignoresADifferentCode() throws {
        let decision = try #require(decodeDetails(errorBody()).heldSlot)
        let error = APIError.serverDetails(
            status: 409, message: "x", code: "TIME_BOOKED",
            details: ServerErrorDetails(heldSlot: decision))

        #expect(error.holdOverlapDecision == nil)
    }

    // 🔴 Load-bearing. A `.server` (no captured details) can never carry the
    // decision, so a call that forgets `captureErrorDetails: true` must read as
    // "no decision" rather than crashing or half-opening a sheet.
    @Test func aPlainServerErrorCarriesNoDecision() {
        let error = APIError.server(
            status: 409, message: "x", code: holdOverlapDecisionCode)

        #expect(error.holdOverlapDecision == nil)
    }

    // 🔴 The trap this change had to close: `.serverDetails` is `.server` plus
    // opted-in fields, and the override prompt used to match ONLY `.server`.
    // Opting the pro create/reschedule calls in for the hold decision would
    // have silently removed every "Book anyway" retry on them.
    @Test func overridePromptStillWorksOnAnOptedInCall() {
        let error = APIError.serverDetails(
            status: 400, message: "x", code: "OUTSIDE_WORKING_HOURS",
            details: ServerErrorDetails())

        #expect(
            error.bookingOverridePrompt(intent: .create)?.flag
                == .allowOutsideWorkingHours)
    }

    // A popup that renders half a fact is worse than the plain refusal it
    // replaced, so an unusable field means no popup at all.
    @Test(arguments: [
        #"{"relationship":"RETURNING","serviceName":"S","startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:00:00Z","expiresAt":"2026-09-01T18:40:00Z"}"#,
        #"{"holdId":"h","serviceName":"S","startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:00:00Z","expiresAt":"2026-09-01T18:40:00Z"}"#,
        #"{"holdId":"h","relationship":"MAYBE","serviceName":"S","startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:00:00Z","expiresAt":"2026-09-01T18:40:00Z"}"#,
        #"{"holdId":"h","relationship":"NEW","serviceName":"  ","startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:00:00Z","expiresAt":"2026-09-01T18:40:00Z"}"#,
        #"{"holdId":"h","relationship":"NEW","serviceName":"S","startsAt":"nope","endsAt":"2026-09-01T20:00:00Z","expiresAt":"2026-09-01T18:40:00Z"}"#,
        #"{"holdId":"h","relationship":"NEW","serviceName":"S","startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:00:00Z","expiresAt":"nope"}"#,
    ])
    func rejectsAnUnusablePayload(_ slot: String) throws {
        #expect(try decodeDetails(errorBody(heldSlot: slot)).heldSlot == nil)
    }

    @Test func survivesAMissingPayloadEntirely() throws {
        #expect(try decodeDetails(errorBody(heldSlot: nil)).heldSlot == nil)
    }

    // The count is a nicety. A server that omits it (or sends a negative) still
    // gets the popup, just without the extra line.
    @Test(arguments: ["-3", "null"])
    func floorsAnUnusableAdditionalCount(_ raw: String) throws {
        let slot = """
        {"holdId":"h","relationship":"NEW","serviceName":"S",
         "startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:00:00Z",
         "expiresAt":"2026-09-01T18:40:00Z","additionalHeldSlots":\(raw)}
        """
        let decision = try #require(decodeDetails(errorBody(heldSlot: slot)).heldSlot)

        #expect(decision.additionalHeldSlots == 0)
    }

    // 🔴 The decoder is also a leak guard on the way IN: whatever the server
    // sent, only the seven known fields survive into the model a view renders.
    @Test func dropsAnyExtraFieldAPayloadCarries() throws {
        let slot = """
        {"holdId":"h","relationship":"NEW","serviceName":"Manicure",
         "startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:00:00Z",
         "expiresAt":"2026-09-01T18:40:00Z","additionalHeldSlots":0,
         "clientName":"\(Self.heldClientName)",
         "clientEmail":"\(Self.heldClientEmail)",
         "clientPhone":"\(Self.heldClientPhone)",
         "clientAvatarUrl":"https://cdn.example.com/a.jpg"}
        """
        let decision = try #require(decodeDetails(errorBody(heldSlot: slot)).heldSlot)
        let dumped = String(describing: decision)

        #expect(!dumped.contains(Self.heldClientName))
        #expect(!dumped.contains(Self.heldClientEmail))
        #expect(!dumped.contains(Self.heldClientPhone))
        #expect(!dumped.contains("avatar"))
    }

    // MARK: - Copy

    @Test func leadsWithTheRelationshipAndNothingElse() {
        #expect(HoldOverlapPromptCopy.leadIn(.new) == "A new client is booking")
        #expect(HoldOverlapPromptCopy.leadIn(.returning) == "A returning client is booking")
        // A hold with no client is not "new" — say only what is true.
        #expect(HoldOverlapPromptCopy.leadIn(.unknown) == "A client is booking")
    }

    @Test func changesOnlyTheActionWordingBetweenIntents() {
        #expect(HoldOverlapPromptCopy.proceedLabel(.create) == "Book it anyway")
        #expect(HoldOverlapPromptCopy.proceedLabel(.edit) == "Move it here anyway")
    }

    @Test func pluralizesTheExtraHoldsNote() {
        #expect(HoldOverlapPromptCopy.additionalHeldSlotsNote(0) == nil)
        #expect(HoldOverlapPromptCopy.additionalHeldSlotsNote(1)?.contains("One more client") == true)
        #expect(HoldOverlapPromptCopy.additionalHeldSlotsNote(3)?.contains("3 more clients") == true)
    }

    // 🔴 The whole rendered sentence, asserted as an ABSENCE. The decoder test
    // above proves the MODEL cannot carry a name; this proves the COPY built
    // from it does not invent one either — the only variable about the person
    // is the three-case label.
    @Test func theSummaryNamesTheServiceAndTheTimeAndNobodyElse() throws {
        let slot = """
        {"holdId":"h","relationship":"RETURNING","serviceName":"Signature Manicure",
         "startsAt":"2026-09-01T19:00:00Z","endsAt":"2026-09-01T20:15:00Z",
         "expiresAt":"2026-09-01T18:40:00Z","additionalHeldSlots":0,
         "clientName":"\(Self.heldClientName)"}
        """
        let decision = try #require(decodeDetails(errorBody(heldSlot: slot)).heldSlot)
        let summary = HoldOverlapPromptCopy.summary(
            decision, timeZone: "America/Los_Angeles")

        #expect(summary.hasPrefix("A returning client is booking Signature Manicure for "))
        // 19:00Z is noon in Los Angeles — the pro's day, not the device's.
        #expect(summary.contains("12:00 PM"))
        #expect(!summary.contains(Self.heldClientName))
        #expect(!summary.contains(Self.heldClientEmail))
        #expect(!summary.contains(Self.heldClientPhone))
        #expect(!summary.contains(decision.holdId))
    }

    @Test(arguments: [
        HeldSlotDecision.Relationship.new,
        .returning,
        .unknown,
    ])
    func everySummaryVariantStillNamesNobody(
        _ relationship: HeldSlotDecision.Relationship
    ) {
        let decision = HeldSlotDecision(
            holdId: "h", relationship: relationship, serviceName: "Manicure",
            startsAt: Date(), endsAt: Date(), expiresAt: Date(),
            additionalHeldSlots: 0)

        #expect(
            HoldOverlapPromptCopy.summary(decision, timeZone: "UTC")
                .hasPrefix(HoldOverlapPromptCopy.leadIn(relationship)))
    }

    // The countdown must be the SAME formatter the client's checkout and the
    // pro's calendar tile use — one reservation, one clock (web parity:
    // `lib/booking/holdCountdown`).
    @Test func readsTheSameClockAsEverySurface() {
        #expect(BookingSheetPresentation.holdCountdownLabel(secondsRemaining: 462) == "07:42")
        #expect(BookingSheetPresentation.holdIsUrgent(secondsRemaining: 119))
        #expect(!BookingSheetPresentation.holdIsUrgent(secondsRemaining: 121))
    }
}
