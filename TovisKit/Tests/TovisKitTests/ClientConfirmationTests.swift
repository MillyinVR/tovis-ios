import Foundation
import Testing
@testable import TovisKit

// K13: the client-confirmation state is consumed VERBATIM off the wire (derived
// by web's ONE helper, lib/booking/clientConfirmation.ts, from three orthogonal
// Booking timestamps). These pin the device-side duties: render exactly what the
// wire says, never let a malformed or future state crash a whole feed decode,
// and never confuse "the client answered" with "the booking's status changed".

struct ClientConfirmationTests {

    private func badge(_ json: String) throws -> ProClientConfirmation {
        try JSONDecoder().decode(ProClientConfirmation.self, from: Data(json.utf8))
    }

    @Test func rendersAWireStateVerbatim() throws {
        let display = try #require(badge(
            #"{"kind":"CLIENT_CONFIRMED","label":"Client confirmed","description":"Client confirmed this appointment","tone":"success","significant":true}"#
        ).display)
        #expect(display.state == .clientConfirmed)
        #expect(display.label == "Client confirmed")
        #expect(display.description == "Client confirmed this appointment")
        #expect(display.tone == "success")
        #expect(display.significant)
    }

    @Test func everyKnownStateIsRenderable() throws {
        for state in ProClientConfirmation.State.allCases {
            let display = try #require(
                badge(#"{"kind":"\#(state.rawValue)","label":"x","description":"y","tone":"neutral","significant":true}"#).display,
                "state \(state.rawValue) should render")
            #expect(display.state == state)
        }
    }

    @Test func knownKindsIsDerivedFromTheEnumNotHandListed() {
        // Two lists of the same four strings is two chances to drift. This pins
        // that there is only one — a fifth state added to the enum is known to
        // `knownKinds` the moment it exists.
        #expect(ProClientConfirmation.knownKinds == Set(
            ProClientConfirmation.State.allCases.map(\.rawValue)))
        #expect(ProClientConfirmation.knownKinds.count == 4)
    }

    @Test func noLabelIsTheBareWordConfirmed() throws {
        // 🔴 B10 gave the bare word "Confirmed" to BookingStatus.ACCEPTED, whose
        // pill sits on the SAME rows as this one. If the server ever shortened
        // "Client confirmed" to "Confirmed", one word would stand for two
        // different facts on one card — the exact disease B10 cured. Web pins
        // this against its own status table; this is the device's half, against
        // the wire text that actually reaches a pro's screen.
        let confirmed = try #require(badge(
            #"{"kind":"CLIENT_CONFIRMED","label":"Client confirmed","description":"Client confirmed this appointment","tone":"success","significant":true}"#
        ).display)
        #expect(confirmed.label != BookingStatusPresentation.label("ACCEPTED"))
        #expect(confirmed.label.contains("Client"))
    }

    @Test func notRequestedArrivesInsignificantSoNothingRenders() throws {
        // Web omits the field entirely for NOT_REQUESTED, but a row that carries
        // it explicitly must still render nothing: absence is the honest display
        // for "nobody asked", and the DECISION lives in the web helper's
        // `significant`, never in a view's own guess.
        let display = try #require(badge(
            #"{"kind":"NOT_REQUESTED","label":"Not requested","description":"Confirmation not requested","tone":"neutral","significant":false}"#
        ).display)
        #expect(display.significant == false)
    }

    @Test func anUnknownFutureStateHidesInsteadOfRendering() throws {
        let parsed = try badge(
            #"{"kind":"CLIENT_MAYBE","label":"Maybe","description":"A future state","tone":"pending","significant":true}"#)
        #expect(parsed.display == nil)
    }

    @Test func aBlankLabelHidesTheMark() throws {
        #expect(try badge(#"{"kind":"DECLINED","label":"  ","tone":"danger"}"#).display == nil)
        #expect(try badge(#"{"kind":"DECLINED","tone":"danger"}"#).display == nil)
    }

    @Test func aMissingDescriptionFallsBackToTheLabelNeverToSilence() throws {
        // The description is what VoiceOver speaks, and on the calendar tile the
        // state is a bare SHAPE — so an empty accessibility string would delete
        // the channel outright for a screen-reader user (the K9-A lesson).
        let display = try #require(badge(#"{"kind":"AWAITING_CLIENT","label":"Awaiting client","tone":"pending"}"#).display)
        #expect(display.description == "Awaiting client")
        #expect(display.significant)
    }

    @Test func aMalformedStateNeverFailsTheParentDecode() throws {
        // The value is a STRING here, not an object. `ProCalendarEvent` uses
        // SYNTHESIZED decoding, so a field that threw on a type mismatch would
        // blank the ENTIRE events array — one bad badge must never cost a pro
        // their whole day (the ProServiceSwatch lesson, K9).
        let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "bk_1", "kind": "BOOKING",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Balayage", "clientName": "Jordan Rivera", "status": "ACCEPTED",
          "durationMinutes": 60, "localDateKey": "2026-07-29",
          "clientConfirmation": "CLIENT_CONFIRMED"
        }
        """.utf8))
        #expect(event.clientConfirmationDisplay == nil)

        #expect(try badge(#"{"kind":42,"label":true}"#).display == nil)
    }

    @Test func aCalendarBookingEventCarriesTheState() throws {
        let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "bk_2", "kind": "BOOKING",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Full Color", "clientName": "Priya Nadkarni", "status": "ACCEPTED",
          "durationMinutes": 60, "localDateKey": "2026-07-29",
          "clientConfirmation": {"kind":"AWAITING_CLIENT","label":"Awaiting client","description":"Awaiting client confirmation","tone":"pending","significant":true}
        }
        """.utf8))
        let display = try #require(event.clientConfirmationDisplay)
        #expect(display.state == .awaitingClient)
        #expect(display.tone == "pending")
    }

    @Test func aBlockOrHoldNeverClaimsTheConfirmationChannel() throws {
        // A block is the pro's own time and a hold is a stranger mid-checkout —
        // neither has a client who could be asked. Web gates its glyph on
        // `ev.kind === 'BOOKING'`; this pins the same gate here even when a
        // server sends the field, so the two platforms can't disagree.
        for kind in ["BLOCK", "HOLD"] {
            let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
            {
              "id": "x_1", "kind": "\(kind)",
              "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
              "title": "Lunch", "clientName": "", "status": "BLOCKED",
              "durationMinutes": 60, "localDateKey": "2026-07-29",
              "clientConfirmation": {"kind":"CLIENT_CONFIRMED","label":"Client confirmed","description":"Client confirmed this appointment","tone":"success","significant":true}
            }
            """.utf8))
            #expect(event.clientConfirmation?.display != nil, "\(kind) decodes the field")
            #expect(event.clientConfirmationDisplay == nil, "\(kind) must not claim the channel")
        }
    }

    @Test func anAbsentFieldDecodesFineOnEverySurface() throws {
        // The common case, and the one a pre-#806 server always sends: the key
        // is OMITTED (not null). Every consumer must decode and show nothing.
        let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "bk_3", "kind": "BOOKING",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Cut", "clientName": "Sam Ray", "status": "ACCEPTED",
          "durationMinutes": 60, "localDateKey": "2026-07-29"
        }
        """.utf8))
        #expect(event.clientConfirmation == nil)
        #expect(event.clientConfirmationDisplay == nil)

        let listRow = try JSONDecoder().decode(ProBookingListItem.self, from: Data("""
        {
          "id": "bk_4", "status": "ACCEPTED", "statusLabel": "Confirmed",
          "sessionStep": null, "scheduledFor": "2026-07-29T17:00:00.000Z",
          "timeZone": "America/Los_Angeles", "whenLabel": "Wed, Jul 29 · 10:00 AM",
          "serviceName": "Cut", "addOnNames": [], "durationMinutes": 60,
          "total": "80.00",
          "client": {"id":"cl_1","fullName":"Sam Ray","email":null,"phone":null,"canViewClient":true},
          "location": {"formattedAddress":null,"lat":null,"lng":null,"isMobile":false},
          "needsCloseout": false, "startedAt": null, "finishedAt": null
        }
        """.utf8))
        #expect(listRow.clientConfirmation == nil)
    }

    // MARK: - The client's own view + in-app answer

    @Test func theClientsOwnBookingCarriesTheQuestion() throws {
        let booking = try JSONDecoder().decode(ClientBooking.self, from: Data("""
        {
          "id": "bk_5", "status": "ACCEPTED", "source": "CLIENT",
          "rebookOfBookingId": null, "sessionStep": "SCHEDULED",
          "scheduledFor": "2026-08-02T16:30:00.000Z",
          "totalDurationMinutes": 60, "bufferMinutes": 15,
          "timeZone": "America/Los_Angeles", "locationType": "SALON", "locationLabel": null,
          "professional": null, "bookedLocation": null,
          "display": {"title":"Haircut","baseName":"Haircut","addOnNames":[],"addOnCount":0},
          "checkout": {}, "items": [], "productSales": [], "consultation": null,
          "hasUnreadAftercare": false, "hasPendingConsultationApproval": false,
          "hasPendingRebookConfirmation": false, "rebookProposedFor": null,
          "mediaUseConsent": false,
          "clientConfirmation": {"kind":"AWAITING_CLIENT","label":"Awaiting client","description":"Awaiting client confirmation","tone":"pending","significant":true}
        }
        """.utf8))
        let display = try #require(booking.clientConfirmationDisplay)
        #expect(display.state == .awaitingClient)
    }

    @Test func aClientBookingWithNoAskOffersNothingToAnswer() throws {
        // 🔴 The kill switch reaches the CONTROL, not just the writers: web
        // suppresses this field entirely while ENABLE_CLIENT_CONFIRMATION_LOOP
        // is off, even for a row carrying stamps from an earlier trial, because
        // the answer route refuses then. So "absent" must mean "draw no
        // buttons" — the app never infers an ask from anything else.
        let booking = try JSONDecoder().decode(ClientBooking.self, from: Data("""
        {
          "id": "bk_6", "status": "ACCEPTED", "source": "CLIENT",
          "rebookOfBookingId": null, "sessionStep": "SCHEDULED",
          "scheduledFor": "2026-08-02T16:30:00.000Z",
          "totalDurationMinutes": 60, "bufferMinutes": 15,
          "timeZone": "America/Los_Angeles", "locationType": "SALON", "locationLabel": null,
          "professional": null, "bookedLocation": null,
          "display": {"title":"Haircut","baseName":"Haircut","addOnNames":[],"addOnCount":0},
          "checkout": {}, "items": [], "productSales": [], "consultation": null,
          "hasUnreadAftercare": false, "hasPendingConsultationApproval": false,
          "hasPendingRebookConfirmation": false, "rebookProposedFor": null,
          "mediaUseConsent": false
        }
        """.utf8))
        #expect(booking.clientConfirmation == nil)
        #expect(booking.clientConfirmationDisplay == nil)
    }

    @Test func theAnswerResultIsReadAsTheServerSawIt() throws {
        let result = try JSONDecoder().decode(AppointmentConfirmationResult.self, from: Data("""
        {
          "state": "DECLINED",
          "booking": {"id":"bk_5","status":"ACCEPTED","scheduledFor":"2026-08-02T16:30:00.000Z"},
          "meta": {"answeredAt":"2026-07-31T17:00:00.000Z"}
        }
        """.utf8))
        #expect(result.resolvedState == .declined)
        // 🔴 D5: declining does NOT free the slot. The booking the server echoes
        // back is still ACCEPTED, and no surface may read the answer as a
        // cancellation.
        #expect(result.booking?.status == "ACCEPTED")
    }

    // MARK: - The live captures

    // These decode the SAME fixtures scripts/contract/validate-fixtures.mjs
    // validates against the backend's generated schema, and every one is a
    // VERBATIM capture off the running route rather than a hand-built mock of
    // the shape this model hopes for ([[wire-shape-vs-mock-drift]]).

    @Test("the live calendar feed carries all three answers and one booking with none")
    func calendarFixtureCoversEveryState() throws {
        let response = try JSONDecoder().decode(
            ProCalendarResponse.self, from: fixture("proCalendar"))
        let states = response.events.compactMap(\.clientConfirmationDisplay).map(\.state)
        #expect(Set(states) == [.clientConfirmed, .declined, .awaitingClient])
        // …and the common case is still represented: bookings that carry no key
        // at all, because nobody asked. A fixture where every row had one would
        // pin the rare path and leave the usual one untested.
        let bookings = response.events.filter(\.isBooking)
        #expect(bookings.contains { $0.clientConfirmation == nil })
    }

    @Test("the pro booking detail carries the state web's page derives")
    func detailFixtureCarriesTheState() throws {
        let res = try JSONDecoder().decode(
            ProBookingDetailResponse.self, from: fixture("proBookingDetail"))
        let display = try #require(res.booking.clientConfirmation?.display)
        #expect(display.state == .clientConfirmed)
        #expect(display.label == "Client confirmed")
    }

    @Test("the client's own feed carries the question they can answer")
    func clientFixtureCarriesTheQuestion() throws {
        let res = try JSONDecoder().decode(
            ClientBookingsResponse.self, from: fixture("clientBookings"))
        let booking = try #require(res.buckets.upcoming.first)
        #expect(booking.clientConfirmationDisplay?.state == .awaitingClient)
        // The other buckets omit the key — nobody asked about those.
        #expect(res.buckets.pending.allSatisfy { $0.clientConfirmation == nil })
    }

    @Test func anUnknownAnsweredStateResolvesToNothingRatherThanAGuess() throws {
        let result = try JSONDecoder().decode(AppointmentConfirmationResult.self, from: Data("""
        {"state": "CLIENT_MAYBE", "booking": null}
        """.utf8))
        #expect(result.state == "CLIENT_MAYBE")
        #expect(result.resolvedState == nil)
    }
}
