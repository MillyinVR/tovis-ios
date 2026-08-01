import Foundation
import Testing
@testable import TovisKit

// K15/K17-A: the unsigned-consent mark on the calendar, and the outstanding-form
// list at session start. Two fields, one subject, DELIBERATELY different rules —
// which is the thing these tests exist to hold still.
//
// 🔴 The calendar badge goes quiet once the appointment has started
// (`significant: false`), because a pro who binds their first form today would
// otherwise light up every past appointment for that service. The session list
// carries NO such gate, because at session start `scheduledFor <= now` is true by
// definition: the same gate there would blank the warning at the exact moment it
// is worth the most. A future reader that "tidies up" by sharing one rule between
// them breaks one of the two surfaces, and only one of those breakages is visible.

@Suite struct ConsentRequirementTests {

    private func badge(_ json: String) throws -> ProConsentRequirement {
        try JSONDecoder().decode(ProConsentRequirement.self, from: Data(json.utf8))
    }

    private func event(_ json: String) throws -> ProCalendarEvent {
        try JSONDecoder().decode(ProCalendarEvent.self, from: Data(json.utf8))
    }

    // MARK: - The badge

    @Test func rendersTheWireMarkVerbatim() throws {
        let display = try #require(badge(
            #"{"kind":"UNSIGNED_CONSENT","label":"Form due","description":"Corrective colour waiver not signed","tone":"warn","significant":true}"#
        ).display)
        #expect(display.kind == .unsignedConsent)
        #expect(display.label == "Form due")
        #expect(display.description == "Corrective colour waiver not signed")
        #expect(display.tone == "warn")
        #expect(display.significant)
    }

    @Test func knownKindsIsDerivedFromTheEnumNotHandListed() {
        #expect(ProConsentRequirement.knownKinds == Set(
            ProConsentRequirement.Kind.allCases.map(\.rawValue)))
        #expect(ProConsentRequirement.knownKinds == ["UNSIGNED_CONSENT"])
    }

    @Test func anUnknownFutureKindHidesInsteadOfWarning() throws {
        // A mark this build cannot describe must not be printed as one it can:
        // "Form due" over a future EXPIRED_CONSENT would be a sentence the server
        // never said.
        #expect(try badge(
            #"{"kind":"EXPIRED_CONSENT","label":"Form expired","description":"x","tone":"warn","significant":true}"#
        ).display == nil)
    }

    @Test func aBlankOrMissingLabelHidesTheChip() throws {
        #expect(try badge(#"{"kind":"UNSIGNED_CONSENT","label":"   ","tone":"warn"}"#).display == nil)
        #expect(try badge(#"{"kind":"UNSIGNED_CONSENT","tone":"warn"}"#).display == nil)
    }

    @Test func theDescriptionFallsBackToTheLabelNeverToEmpty() throws {
        // It is the accessibility string. A chip reading "Form due" with nothing
        // behind it is the K9-A failure — a mark only sighted users can resolve.
        let display = try #require(badge(
            #"{"kind":"UNSIGNED_CONSENT","label":"Form due","description":"  ","tone":"warn"}"#
        ).display)
        #expect(display.description == "Form due")
    }

    @Test func aMalformedValueDegradesToNoChipRatherThanThrowing() throws {
        // Every field the wrong type at once. The decode must still succeed —
        // this rides on the calendar feed, where a throw blanks the whole grid.
        let parsed = try badge(
            #"{"kind":123,"label":false,"description":[],"tone":{},"significant":"yes"}"#)
        #expect(parsed.display == nil)
    }

    // MARK: - On a calendar event

    /// A booking carrying the mark — the shape the live route sends.
    private let bookingWithConsent = """
    {
      "id": "k9todayhaircut0000000001",
      "kind": "BOOKING",
      "startsAt": "2026-08-02T16:30:00.000Z",
      "endsAt": "2026-08-02T17:30:00.000Z",
      "title": "Haircut & Style",
      "clientName": "Test Client",
      "status": "ACCEPTED",
      "durationMinutes": 60,
      "localDateKey": "2026-08-02",
      "consentRequirement": {
        "kind": "UNSIGNED_CONSENT", "label": "Form due",
        "description": "K17 drive release not signed",
        "tone": "warn", "significant": true
      }
    }
    """

    @Test func aBookingSurfacesTheMark() throws {
        let display = try #require(event(bookingWithConsent).consentRequirementDisplay)
        #expect(display.label == "Form due")
        #expect(display.description == "K17 drive release not signed")
    }

    @Test func anAbsentFieldIsTheCommonCaseAndDecodesFine() throws {
        // Every booking, until a pro binds a form to a service. Web omits the
        // key entirely — there is no `null` to handle and no chip to draw.
        let row = bookingWithConsent.replacingOccurrences(
            of: #""consentRequirement": {"#, with: #""ignored": {"#)
        let decoded = try event(row)
        #expect(decoded.consentRequirement == nil)
        #expect(decoded.consentRequirementDisplay == nil)
    }

    @Test func anInsignificantMarkRendersNothing() throws {
        // Web's route omits an insignificant badge outright; a row that carries
        // one anyway must still be silent. The DECISION lives in the web helper
        // (`deriveConsentRequirementBadge`), and no view re-derives it.
        let row = bookingWithConsent.replacingOccurrences(
            of: #""tone": "warn", "significant": true"#,
            with: #""tone": "warn", "significant": false"#)
        let decoded = try event(row)
        #expect(decoded.consentRequirement?.display?.significant == false)
        #expect(decoded.consentRequirementDisplay == nil)
    }

    @Test func aBlockOrHoldNeverClaimsTheChannel() throws {
        // A block is the pro's own time; a hold is a stranger mid-checkout.
        // Neither has a client who could sign anything, so neither may print the
        // mark even if a future server were to send it on one.
        for kind in ["BLOCK", "HOLD"] {
            let row = bookingWithConsent.replacingOccurrences(
                of: #""kind": "BOOKING""#, with: #""kind": "\#(kind)""#)
            let decoded = try event(row)
            #expect(decoded.consentRequirement?.display != nil, "\(kind) still decodes the field")
            #expect(decoded.consentRequirementDisplay == nil, "\(kind) must not render it")
        }
    }

    @Test func aWrongTypedFieldDoesNotBlankTheWholeEventsArray() throws {
        // 🔴 The K9 lesson, one field later: `ProCalendarEvent` uses SYNTHESIZED
        // decoding, so a nested type that throws takes the entire feed down with
        // it. `consentRequirement` as a bare string must cost the chip, nothing
        // more.
        let row = bookingWithConsent.replacingOccurrences(
            of: """
            "consentRequirement": {
                "kind": "UNSIGNED_CONSENT", "label": "Form due",
                "description": "K17 drive release not signed",
                "tone": "warn", "significant": true
              }
            """,
            with: #""consentRequirement": "UNSIGNED_CONSENT""#)
        let decoded = try event(row)
        #expect(decoded.id == "k9todayhaircut0000000001")
        #expect(decoded.consentRequirementDisplay == nil)
    }

    // MARK: - The session-start list

    private func form(_ json: String) throws -> ProUnsignedConsentForm {
        try JSONDecoder().decode(ProUnsignedConsentForm.self, from: Data(json.utf8))
    }

    @Test func aNamedFormIsRenderable() throws {
        let display = try #require(form(
            #"{"formId":"cmf1","title":"K17 drive release","kindLabel":"Service waiver"}"#
        ).display)
        #expect(display.formId == "cmf1")
        #expect(display.title == "K17 drive release")
        #expect(display.kindLabel == "Service waiver")
        #expect(display.accessibilityLabel == "K17 drive release, Service waiver, not signed")
    }

    @Test func aFormWithNoKindLabelStillWarns() throws {
        // The kind is a qualifier beside the name. Losing it costs a nuance, not
        // the warning.
        let display = try #require(form(#"{"formId":"cmf1","title":"Patch test"}"#).display)
        #expect(display.kindLabel == nil)
        #expect(display.accessibilityLabel == "Patch test, not signed")
    }

    @Test func aRowThatCannotNameOrIdentifyItselfIsDropped() throws {
        // No id ⇒ no link can be sent for it; no title ⇒ nothing to call it.
        // Web already substitutes "Consent form" for a blank title, so a blank
        // one arriving here means the wire is broken, not that the pro left it
        // empty.
        #expect(try form(#"{"title":"K17 drive release","kindLabel":"Service waiver"}"#).display == nil)
        #expect(try form(#"{"formId":"  ","title":"K17 drive release"}"#).display == nil)
        #expect(try form(#"{"formId":"cmf1","title":"   "}"#).display == nil)
        #expect(try form(#"{"formId":"cmf1"}"#).display == nil)
    }

    @Test func displayableKeepsWireOrderAndDropsOnlyTheBrokenRows() throws {
        let rows = try JSONDecoder().decode(
            [ProUnsignedConsentForm].self,
            from: Data("""
            [
              {"formId":"a","title":"Colour waiver","kindLabel":"Service waiver"},
              {"formId":"","title":"Broken"},
              {"formId":"b","title":"Patch test","kindLabel":"Patch test"}
            ]
            """.utf8))
        #expect(rows.displayable.map(\.formId) == ["a", "b"])
    }

    // MARK: - The state response

    private func stateResponse(_ json: String) throws -> ProSessionStateResponse {
        try JSONDecoder().decode(ProSessionStateResponse.self, from: Data(json.utf8))
    }

    private let stateOnly = """
    {
      "state": {
        "bookingId": "k9todayhaircut0000000001",
        "status": "ACCEPTED",
        "sessionStep": "CONSULTATION",
        "effectiveSessionStep": "CONSULTATION",
        "terminal": false
      },
      "stateHash": "abc123"
    }
    """

    @Test func anAbsentListIsTheDarkAndTheQuietCase() throws {
        // The route omits the key both when the technical-record gate is off and
        // when there is nothing outstanding — one representation for "nothing to
        // sign", so an empty array never reaches the screen.
        let decoded = try stateResponse(stateOnly)
        #expect(decoded.unsignedConsentForms == nil)
        #expect(decoded.state.bookingId == "k9todayhaircut0000000001")
    }

    @Test func theListIsASiblingOfStateAndSurvivesBesideIt() throws {
        let decoded = try stateResponse(stateOnly.replacingOccurrences(
            of: #""stateHash": "abc123""#,
            with: """
            "stateHash": "abc123",
              "unsignedConsentForms": [
                {"formId":"cmf1","title":"K17 drive release","kindLabel":"Service waiver"}
              ]
            """))
        #expect(decoded.state.terminal == false)
        #expect((decoded.unsignedConsentForms ?? []).displayable.map(\.title)
            == ["K17 drive release"])
    }

    @Test func oneMalformedFormDoesNotCostTheBookingItsSessionState() throws {
        // 🔴 This list rides on the hub's spine. A row that is the wrong shape
        // must cost that row and nothing else — a throw here would leave the pro
        // staring at a failed session screen mid-appointment.
        let decoded = try stateResponse(stateOnly.replacingOccurrences(
            of: #""stateHash": "abc123""#,
            with: """
            "stateHash": "abc123",
              "unsignedConsentForms": [
                {"formId":42,"title":["nope"],"kindLabel":{}},
                {"formId":"cmf1","title":"K17 drive release","kindLabel":"Service waiver"}
              ]
            """))
        #expect(decoded.state.bookingId == "k9todayhaircut0000000001")
        #expect((decoded.unsignedConsentForms ?? []).displayable.map(\.formId) == ["cmf1"])
    }

    // MARK: - The live captures

    // These decode the SAME fixtures scripts/contract/validate-fixtures.mjs
    // validates against the backend's generated schema, and both are VERBATIM
    // captures off the running routes rather than hand-built mocks of the shape
    // this model hopes for ([[wire-shape-vs-mock-drift]]).

    @Test("the live calendar carries ONE mark and seven bookings without one")
    func calendarFixtureCarriesBothSides() throws {
        let response = try JSONDecoder().decode(
            ProCalendarResponse.self, from: fixture("proCalendar"))
        let bookings = response.events.filter(\.isBooking)

        let marked = bookings.filter { $0.consentRequirementDisplay != nil }
        #expect(marked.count == 1)
        #expect(marked.first?.consentRequirementDisplay?.label == "Form due")
        #expect(marked.first?.consentRequirementDisplay?.description == "K17 drive release not signed")
        #expect(marked.first?.consentRequirementDisplay?.tone == "warn")

        // The common case — no key at all, which is every booking until a pro
        // binds a form to a service.
        #expect(bookings.filter { $0.consentRequirement == nil }.count == 7)
    }

    @Test("🔴 the PAST booking with the SAME unsigned form carries no mark")
    func theSignificanceGateIsInTheCapture() throws {
        // Both Haircut & Style rows need the same unsigned form; only the FUTURE
        // one is marked. The route drops an insignificant badge outright, so
        // this is the gate itself, captured off the wire rather than argued
        // about — and it is the calendar's answer alone. The SESSION route,
        // asked about that same past booking, still lists the form (see below).
        let response = try JSONDecoder().decode(
            ProCalendarResponse.self, from: fixture("proCalendar"))
        let haircuts = response.events.filter { $0.title == "Haircut & Style" }
        #expect(haircuts.count == 2)

        let past = try #require(haircuts.first { $0.startsAt < "2026-08-01" })
        let future = try #require(haircuts.first { $0.startsAt > "2026-08-01" })
        #expect(past.consentRequirement == nil)
        #expect(future.consentRequirementDisplay != nil)
    }

    @Test("the live session state carries the list beside an untouched state")
    func sessionFixtureCarriesTheList() throws {
        let response = try JSONDecoder().decode(
            ProSessionStateResponse.self, from: fixture("proSessionStateConsent"))

        #expect(response.state.bookingId == "k9todayhaircut0000000001")
        let forms = (response.unsignedConsentForms ?? []).displayable
        #expect(forms.map(\.title) == ["K17 drive release"])
        #expect(forms.map(\.kindLabel) == ["Service waiver"])
    }

    @Test("the older capture with nothing outstanding omits the key entirely")
    func quietSessionFixtureOmitsTheKey() throws {
        // "Nothing to sign" has ONE representation on this route, and it is the
        // absence of the field — never an empty array. A device that treated
        // `[]` as the quiet case would still be right; one that required the key
        // would break on every booking that has nothing outstanding, which is
        // almost all of them.
        let response = try JSONDecoder().decode(
            ProSessionStateResponse.self, from: fixture("proSessionState"))
        #expect(response.unsignedConsentForms == nil)
    }

    @Test func theSessionListCarriesNoSignificanceGateToReachFor() throws {
        // 🔴 The heart of #812's finding, pinned as a SHAPE rather than a
        // behaviour: the badge has `significant`, this row does not, so no
        // surface can accidentally gate the session warning on the calendar's
        // question. At session start the scheduled time has arrived by
        // definition — the gate would blank the warning exactly then.
        let json = #"{"formId":"cmf1","title":"K17 drive release","kindLabel":"Service waiver","significant":false}"#
        let display = try #require(form(json).display)
        #expect(display.title == "K17 drive release")

        let mirror = Mirror(reflecting: display)
        #expect(!mirror.children.contains { $0.label == "significant" })
    }
}
