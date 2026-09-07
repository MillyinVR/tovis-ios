import Foundation
import Testing
@testable import TovisKit

// P7a-4: the prep flag is consumed VERBATIM off the wire (derived by web's ONE
// helper, lib/consult/prepBadge.ts). These pin the two device-side duties:
// render exactly what the wire says, and NEVER let a malformed or future state
// crash the pro's whole bookings decode — it hides instead.
//
// 🔴 The list-decode test is the load-bearing one. A booking with no consult
// omits the field entirely, which is nearly every booking on nearly every pro's
// screen; if the absence broke decoding, this feature would take the pro's
// schedule down with it.

struct ConsultPrepBadgeTests {

    private func badge(_ json: String) throws -> ConsultPrepBadge {
        try JSONDecoder().decode(ConsultPrepBadge.self, from: Data(json.utf8))
    }

    @Test func rendersAWireBadgeVerbatim() throws {
        let display = try #require(badge(
            #"{"kind":"INCOMPLETE","label":"Prep incomplete","description":"Your client still has questions to answer before the appointment.","tone":"warn","significant":true}"#
        ).display)
        #expect(display.state == .incomplete)
        #expect(display.label == "Prep incomplete")
        #expect(display.description == "Your client still has questions to answer before the appointment.")
        #expect(display.tone == "warn")
        #expect(display.significant)
    }

    @Test func overdueIsItsOwnState() throws {
        // Past the deadline the PRO is the one who has to act, and the copy
        // says so. Collapsing it into INCOMPLETE would lose the day-of signal
        // this whole step exists to give.
        let display = try #require(badge(
            #"{"kind":"OVERDUE","label":"Prep overdue","description":"The questions were due and are still unanswered.","tone":"danger","significant":true}"#
        ).display)
        #expect(display.state == .overdue)
        #expect(display.tone == "danger")
    }

    @Test func everyKnownKindIsRenderable() throws {
        for kind in ConsultPrepBadge.knownKinds {
            let display = try #require(badge(
                #"{"kind":"\#(kind)","label":"L","description":"D","tone":"neutral","significant":true}"#
            ).display, "known kind \(kind) must render")
            #expect(display.kind == kind)
        }
    }

    @Test func aFutureStateHidesInsteadOfGuessing() throws {
        // A state web adds tomorrow must not print a claim about a client's
        // safety answers that this build cannot vouch for.
        let future = try badge(
            #"{"kind":"PREP_WAIVED","label":"Waived","description":"D","tone":"neutral","significant":true}"#
        )
        #expect(future.display == nil)
    }

    @Test func aBlankLabelHidesRatherThanPrintingNothing() throws {
        // The words are server-composed and never rebuilt on device, so an
        // empty label means there is nothing truthful to show.
        let blank = try badge(#"{"kind":"INCOMPLETE","label":"   ","tone":"warn"}"#)
        let missing = try badge(#"{"kind":"INCOMPLETE","tone":"warn"}"#)
        #expect(blank.display == nil)
        #expect(missing.display == nil)
    }

    @Test func descriptionFallsBackToTheLabel() throws {
        // It is the accessibility string — the one place this must not go
        // silent, since the pill is otherwise just a coloured shape.
        let display = try #require(
            badge(#"{"kind":"COMPLETE","label":"Prep complete","tone":"success"}"#).display
        )
        #expect(display.description == "Prep complete")
    }

    @Test func noConsultIsInsignificantSoNothingRenders() throws {
        let display = try #require(badge(
            #"{"kind":"NO_CONSULT","label":"No prep","description":"D","tone":"neutral","significant":false}"#
        ).display)
        #expect(!display.significant)
    }

    // MARK: - the list row

    private func row(_ json: String) throws -> ProBookingListItem {
        try JSONDecoder().decode(ProBookingListItem.self, from: Data(json.utf8))
    }

    private func rowJSON(prep: String?) -> String {
        let prepField = prep.map { #","consultPrep":\#($0)"# } ?? ""
        return """
        {"id":"b1","status":"ACCEPTED","statusLabel":"Confirmed","sessionStep":null,\
        "scheduledFor":"2026-10-16T14:00:00.000Z","timeZone":"America/Los_Angeles",\
        "whenLabel":"Fri, Oct 16","serviceName":"Balayage","addOnNames":[],\
        "durationMinutes":60,"total":"180.00",\
        "client":{"id":"c1","fullName":"Test Client","email":null,"phone":null,\
        "canViewClient":true,"publicProfileHandle":null},\
        "location":{"formattedAddress":null,"lat":null,"lng":null,"isMobile":false},\
        "needsCloseout":false,"startedAt":null,"finishedAt":null\(prepField)}
        """
    }

    @Test func aRowWithNoConsultDecodesWithTheFieldABSENT() throws {
        // 🔴 The case that is nearly every booking. Web omits the field
        // entirely when there is nothing to prepare, so its absence must be
        // ordinary — not a decode failure that costs the pro their schedule.
        let item = try row(rowJSON(prep: nil))
        #expect(item.consultPrep == nil)
        #expect(item.id == "b1")
    }

    @Test func aRowCarriesTheBadgeWhenThereIsPrepToDo() throws {
        let item = try row(rowJSON(
            prep: #"{"kind":"INCOMPLETE","label":"Prep incomplete","description":"D","tone":"warn","significant":true}"#
        ))
        let display = try #require(item.consultPrep?.display)
        #expect(display.state == .incomplete)
        #expect(display.label == "Prep incomplete")
    }

    @Test func aMalformedBadgeDoesNotTakeTheROWDown() throws {
        // The badge decodes leniently (every field `try?`), so junk inside it
        // yields a badge that hides — never a thrown decode that blanks the
        // whole list.
        let item = try row(prep: #"{"kind":42,"label":["nope"],"tone":{}}"#)
        #expect(item.consultPrep?.display == nil)
        #expect(item.serviceName == "Balayage")
    }

    private func row(prep: String) throws -> ProBookingListItem {
        try row(rowJSON(prep: prep))
    }
}
