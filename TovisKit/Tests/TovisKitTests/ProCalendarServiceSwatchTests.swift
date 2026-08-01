import Foundation
import Testing
@testable import TovisKit

// The SERVICE colour channel on the pro calendar (K7 → K9) — `serviceSwatch` on
// a BOOKING event of `GET /api/v1/pro/calendar`.
//
// The pro picks a colour per service offering (K8); the calendar paints it on
// the tile's leading stripe while booking STATUS keeps the fill (decision D2).
// The device resolves NOTHING: web's one helper walks the chain (the BASE
// service item's offering → the pro's offering for `Booking.serviceId` →
// category default → none) and sends the answer, or sends no key at all.
//
// 🔴 What these pin, and why each would otherwise bite:
//   • ABSENT is the common case, not an error state. Nobody has a colour until
//     a pro picks one, so a build that needs the key is a build that breaks on
//     every ordinary booking.
//   • A value this build can't paint must degrade to "no colour", never fail
//     the decode. `serviceSwatch` is a plain TEXT column on purpose — the
//     palette is a brand token set a white-label tenant can change, so a stored
//     id can outlive the palette that defined it.
//   • The channel belongs to bookings. A block is the pro's own time and a hold
//     is a stranger mid-checkout; neither is a service.
//
// The JSON is drawn from `proCalendar.json`, a VERBATIM capture off the live
// route (see the fixture header) — not a hand-built mock of the shape this model
// hopes for. [[wire-shape-vs-mock-drift]] The deliberately-BROKEN shapes below
// are inline, because a contract fixture models TODAY's server and could never
// carry a value the schema forbids. [[contract-fixture-models-the-current-server]]
struct ProCalendarServiceSwatchTests {

    private func decodeFeed() throws -> ProCalendarResponse {
        try JSONDecoder().decode(ProCalendarResponse.self, from: fixture("proCalendar"))
    }

    private func decodeEvent(_ json: String) throws -> ProCalendarEvent {
        try JSONDecoder().decode(ProCalendarEvent.self, from: Data(json.utf8))
    }

    /// A BOOKING event with `serviceSwatch` spliced to an arbitrary raw JSON
    /// value — the only way to model a server this build should survive but the
    /// schema would reject.
    private func bookingRow(rawSwatch: String?) -> String {
        let swatchLine = rawSwatch.map { "\"serviceSwatch\": \($0)," } ?? ""
        return """
        {
          "id": "cmrr6vdjg0033po3nn4o0s6dv",
          "kind": "BOOKING",
          "startsAt": "2026-07-29T16:15:00.000Z",
          "endsAt": "2026-07-29T17:00:00.000Z",
          "title": "Balayage",
          "clientName": "Test Client",
          "status": "ACCEPTED",
          "locationType": "SALON",
          "locationId": "cmrbry47t000fpo0dz0kdy80z",
          "durationMinutes": 30,
          "timeZone": "America/Los_Angeles",
          \(swatchLine)
          "localDateKey": "2026-07-29"
        }
        """
    }

    // MARK: - The live capture

    @Test("the live feed carries two different hues and one uncoloured booking")
    func fixtureCarriesBothSides() throws {
        let response = try decodeFeed()
        let bookings = response.events.filter(\.isBooking)

        // The Balayage rows share the pro's colour for that service; the Root
        // Touch-Up rows are a DIFFERENT service with a different colour — so the
        // stripe is genuinely per-service, not per-pro or per-day.
        #expect(bookings.filter { $0.serviceSwatchId == "09" }.count == 4)
        #expect(bookings.filter { $0.serviceSwatchId == "02" }.count == 2)

        // And the uncoloured one: the server omits the key entirely rather than
        // sending null, and the tile must read that as "keep the status tone".
        let uncoloured = try #require(bookings.first { $0.title == "Haircut & Style" })
        #expect(uncoloured.serviceSwatch == nil)
        #expect(uncoloured.serviceSwatchId == nil)
    }

    @Test("waitlist rows claim no colour")
    func waitlistRowsHaveNoSwatch() throws {
        let response = try decodeFeed()
        let waitlist = response.management.waitlistToday

        #expect(!waitlist.isEmpty)
        #expect(waitlist.allSatisfy { $0.serviceSwatchId == nil })
    }

    // MARK: - Degrading, never throwing

    @Test("a swatch id outside the palette is no colour, not a broken tile")
    func unknownIdIsNoColour() throws {
        let event = try decodeEvent(bookingRow(rawSwatch: "\"13\""))

        // A 13th swatch may exist on a server this build predates. Painting
        // nothing is honest; painting a substitute hue would claim the pro
        // picked a colour they didn't.
        #expect(event.serviceSwatchId == nil)
    }

    @Test("a swatch of the wrong TYPE loses the colour, not the pro's whole day")
    func malformedSwatchStillDecodes() throws {
        // `events` is a single array: one throw here blanks the entire calendar.
        // A colour is never worth that.
        let numeric = try decodeEvent(bookingRow(rawSwatch: "9"))
        #expect(numeric.serviceSwatchId == nil)
        #expect(numeric.title == "Balayage")

        let object = try decodeEvent(bookingRow(rawSwatch: "{\"id\":\"09\"}"))
        #expect(object.serviceSwatchId == nil)
        #expect(object.title == "Balayage")

        let null = try decodeEvent(bookingRow(rawSwatch: "null"))
        #expect(null.serviceSwatchId == nil)
        #expect(null.title == "Balayage")
    }

    @Test("a blank or padded id is normalized rather than trusted")
    func blankAndPaddedIds() throws {
        #expect(try decodeEvent(bookingRow(rawSwatch: "\"\"")).serviceSwatchId == nil)
        #expect(try decodeEvent(bookingRow(rawSwatch: "\"   \"")).serviceSwatchId == nil)
        #expect(try decodeEvent(bookingRow(rawSwatch: "\" 09 \"")).serviceSwatchId == "09")
    }

    @Test("an absent swatch decodes like every other pre-K8 booking")
    func absentSwatchDecodes() throws {
        let event = try decodeEvent(bookingRow(rawSwatch: nil))

        #expect(event.serviceSwatch == nil)
        #expect(event.serviceSwatchId == nil)
    }

    // MARK: - Whose channel it is

    @Test("blocks and holds never claim the service channel")
    func onlyBookingsCarryTheSwatch() throws {
        // Even if a future server were to send the field on one: a block is the
        // pro's own time and a hold is somebody mid-checkout — neither is a
        // service, so neither may repaint the stripe.
        for kind in ["BLOCK", "HOLD"] {
            let row = bookingRow(rawSwatch: "\"09\"")
                .replacingOccurrences(of: "\"kind\": \"BOOKING\"", with: "\"kind\": \"\(kind)\"")
            let event = try decodeEvent(row)

            #expect(event.serviceSwatch?.id == "09")   // decoded…
            #expect(event.serviceSwatchId == nil)      // …but not claimed
        }
    }

    // MARK: - The palette list itself

    @Test("the twelve ids match web's CALENDAR_SWATCH_IDS exactly")
    func knownIdsMirrorWeb() {
        // Mirrors `CALENDAR_SWATCH_IDS` in tovis-app lib/calendar/eventColor.ts.
        // Zero-padded two-digit strings, in picker order — an id is a TOKEN
        // name, not a number, so "9" is not "09".
        #expect(ProServiceSwatch.knownIds == [
            "01", "02", "03", "04", "05", "06",
            "07", "08", "09", "10", "11", "12",
        ])
        #expect(ProServiceSwatch.parse("9") == nil)
    }
}
