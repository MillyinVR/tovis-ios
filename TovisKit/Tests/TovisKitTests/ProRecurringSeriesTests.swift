import Foundation
import Testing
@testable import TovisKit

// Phase 8 on the device (K18-D/K19-D, shipped in K20): the recurring MARK on a
// calendar tile, and the SERIES it points at.
//
// 🔴 What these pin, and why each would otherwise bite:
//
//   • ABSENT is the common case for the mark, not an error state. No booking is
//     part of a series while `ENABLE_RECURRING_APPOINTMENTS` is unset, so a
//     build that needs the key is a build that breaks on every ordinary booking.
//   • A mark with no `seriesId` must vanish, not render. It exists to point at
//     something; a mark that points nowhere is a control that does nothing.
//   • THE SKIPS. A series can have booked five of six dates, and a screen
//     rendering only `occurrences` tells the pro they got six
//     ([[an-always-empty-key-looks-like-an-export]]). `attemptedCount` and
//     `skippedRows` are what make the headline honest, so both are pinned
//     against a capture that genuinely contains a skip.
//   • OPEN-ENDED is `null`, and null is an ANSWER. `occurrenceCount == nil`
//     means "keeps going", not "the server forgot" — and `rollForward` says so
//     in words the device must not re-derive.
//
// The JSON is drawn from VERBATIM captures off the live local route
// (`proCalendarRecurring.json`, `proBookingSeries.json`,
// `proBookingSeriesOpenEnded.json`) rather than hand-built mocks of the shape
// this model hopes for ([[wire-shape-vs-mock-drift]]). The deliberately-BROKEN
// shapes are inline, because a contract fixture models TODAY's server and could
// never carry a value the schema forbids
// ([[contract-fixture-models-the-current-server]]).
struct ProRecurringSeriesTests {

    private func decodeFeed() throws -> ProCalendarResponse {
        try JSONDecoder().decode(
            ProCalendarResponse.self, from: fixture("proCalendarRecurring")
        )
    }

    private func decodeSeries(_ name: String) throws -> ProBookingSeriesDetail {
        try JSONDecoder().decode(ProBookingSeriesDetail.self, from: fixture(name))
    }

    private func decodeEvent(_ json: String) throws -> ProCalendarEvent {
        try JSONDecoder().decode(ProCalendarEvent.self, from: Data(json.utf8))
    }

    /// A BOOKING event with `recurring` spliced to an arbitrary raw JSON value —
    /// the only way to model a server this build should survive but the schema
    /// would reject.
    private func bookingRow(rawRecurring: String?) -> String {
        let line = rawRecurring.map { "\"recurring\": \($0)," } ?? ""
        return """
        {
          "id": "cmrr6vdjg0033po3nn4o0s6dv",
          "kind": "BOOKING",
          "startsAt": "2026-08-11T17:00:00.000Z",
          "endsAt": "2026-08-11T20:00:00.000Z",
          "title": "Balayage",
          "clientName": "Test Client",
          "status": "ACCEPTED",
          "locationType": "SALON",
          "locationId": "cmrbry47t000fpo0dz0kdy80z",
          "durationMinutes": 180,
          "timeZone": "America/Los_Angeles",
          \(line)
          "localDateKey": "2026-08-11"
        }
        """
    }

    // MARK: - The mark, on the live capture

    @Test("the live feed carries BOTH sides: marked occurrences and unmarked bookings")
    func feedCarriesBothSides() throws {
        let response = try decodeFeed()
        let bookings = response.events.filter(\.isBooking)

        let marked = bookings.compactMap(\.recurringDisplay)
        #expect(marked.count == 9)

        // Two different series in one week — so the mark is genuinely per-series
        // and not a per-pro or per-day flag.
        #expect(Set(marked.map(\.seriesId)).count == 2)

        // 🔴 The absent case, in the same file. The server omits the key
        // entirely rather than sending null, and the tile must read that as
        // "not part of anything".
        let ordinary = try #require(bookings.first { $0.title == "Haircut & Style" })
        #expect(ordinary.recurring == nil)
        #expect(ordinary.recurringDisplay == nil)
    }

    @Test("the ordinal is 1-based and the words come from the server")
    func ordinalAndWords() throws {
        let response = try decodeFeed()
        let first = try #require(
            response.events
                .compactMap(\.recurringDisplay)
                .first { $0.occurrenceNumber == 1 }
        )
        // `seriesOccurrenceIndex` is 0-based on the wire and stays that way
        // everywhere it is a KEY; the ordinal is the ONE place it is +1.
        #expect(first.description == "Repeating appointment 1")
    }

    // MARK: - The mark, degrading

    @Test("a mark with no seriesId does not render — it points nowhere")
    func markWithoutSeriesIdHides() throws {
        let event = try decodeEvent(
            bookingRow(rawRecurring: #"{"occurrenceNumber": 3, "description": "Repeating appointment 3"}"#)
        )
        #expect(event.recurringDisplay == nil)
    }

    @Test("a blank seriesId is the same as none")
    func blankSeriesIdHides() throws {
        let event = try decodeEvent(
            bookingRow(rawRecurring: #"{"seriesId": "   ", "occurrenceNumber": 1}"#)
        )
        #expect(event.recurringDisplay == nil)
    }

    @Test("a malformed mark degrades instead of failing the whole decode")
    func malformedMarkDoesNotBreakTheEvent() throws {
        // A future server sending a scalar where an object belongs must cost the
        // pro a mark, never their calendar.
        let event = try decodeEvent(bookingRow(rawRecurring: #""nonsense""#))
        #expect(event.title == "Balayage")
        #expect(event.recurringDisplay == nil)
    }

    @Test("a mark with no words still speaks — the description is the a11y string")
    func descriptionFallsBack() throws {
        let event = try decodeEvent(
            bookingRow(rawRecurring: #"{"seriesId": "ser_1", "occurrenceNumber": 4}"#)
        )
        let mark = try #require(event.recurringDisplay)
        #expect(mark.description == "Repeating appointment 4")

        let noNumber = try decodeEvent(bookingRow(rawRecurring: #"{"seriesId": "ser_1"}"#))
        let bare = try #require(noNumber.recurringDisplay)
        #expect(bare.occurrenceNumber == nil)
        #expect(bare.description == "Repeating appointment")
    }

    @Test("the channel belongs to BOOKINGS — a block never claims it")
    func blocksNeverCarryTheMark() throws {
        let json = """
        {
          "id": "block:abc",
          "kind": "BLOCK",
          "startsAt": "2026-08-11T17:00:00.000Z",
          "endsAt": "2026-08-11T18:00:00.000Z",
          "title": "Lunch",
          "clientName": "",
          "status": "BLOCKED",
          "durationMinutes": 60,
          "timeZone": "America/Los_Angeles",
          "localDateKey": "2026-08-11",
          "recurring": { "seriesId": "ser_1", "occurrenceNumber": 2, "description": "Repeating appointment 2" }
        }
        """
        let event = try decodeEvent(json)
        // The field decodes (it is on the wire) but the tile must not paint it:
        // a block is the pro's own time, not an occurrence of anything.
        #expect(event.recurring != nil)
        #expect(event.recurringDisplay == nil)
    }

    // MARK: - The series: a capture WITH a skip

    @Test("🔴 five of six — the skip is in the count and named")
    func skipsAreVisible() throws {
        let series = try decodeSeries("proBookingSeries")

        #expect(series.occurrenceRows.count == 5)
        #expect(series.skippedRows.count == 1)
        // The headline. Six were attempted; five became appointments. A screen
        // reading `occurrences.count` alone would say "5 of 5".
        #expect(series.attemptedCount == 6)
        // The client-identity axis: a handle here means a world-readable
        // /u/{handle} page exists, independent of chart access. The open-ended
        // fixture carries nil for the same field — both directions decode.
        #expect(series.clientPublicProfileHandle == "ava")

        let skip = try #require(series.skippedRows.first)
        #expect(skip.occurrenceNumber == 2)
        #expect(skip.reason == .slotUnavailable)
        #expect(skip.detail == "TIME_BOOKED")
        #expect(skip.explanation.contains("already taken"))
        // A skip has an instant it WANTED — that is the date the pro lost.
        #expect(skip.intendedStart != nil)
    }

    @Test("a finished series says nothing about dates to come")
    func endedSeriesHasNoRollForwardSentence() throws {
        let series = try decodeSeries("proBookingSeries")
        #expect(series.statusDisplay == .ended)
        #expect(series.statusDisplay?.label == "Finished")
        #expect(series.rollForward?.willContinue == false)
        // Silence, not a negative restatement: "no more dates are coming" reads
        // as a fault, and the counts above already say it.
        #expect(series.rollForward?.sentence == nil)
    }

    @Test("the pin is what the client is charged, and the catalog agrees here")
    func pricingReadsThePin() throws {
        let series = try decodeSeries("proBookingSeries")
        let pricing = try #require(series.pricing)
        #expect(pricing.pinnedTotalCents == 18_000)
        #expect(pricing.listPriceMoved == false)
        // No comparison note when nothing has moved — a note naming the same
        // number twice is noise.
        #expect(pricing.showsListPriceComparison == false)
    }

    // MARK: - The series: OPEN-ENDED, still rolling

    @Test("🔴 open-ended is null, and null is an ANSWER")
    func openEndedReadsAsOpenEnded() throws {
        let series = try decodeSeries("proBookingSeriesOpenEnded")

        #expect(series.occurrenceCount == nil)
        #expect(series.plannedLabel == "Open-ended")
        #expect(series.statusDisplay == .active)
        // A PRIVATE client — no public page by design, so nil, and the heading
        // must render as plain text rather than link to /u/.
        #expect(series.clientPublicProfileHandle == nil)

        let roll = try #require(series.rollForward)
        #expect(roll.willContinue == true)
        // nil pendingCount is "no total to count down from", not a missing field.
        #expect(roll.pendingCount == nil)
        #expect(roll.leadDays == 90)
        let sentence = try #require(roll.sentence)
        #expect(sentence.contains("open-ended"))
        #expect(sentence.contains("90 days"))
    }

    @Test("the capture shows K20's DEFERRAL: eight dates, and NO skips")
    func deferralLeavesNoSkips() throws {
        let series = try decodeSeries("proBookingSeriesOpenEnded")
        #expect(series.occurrenceRows.count == 8)
        // 🔴 The whole point of K20's deferral. Creation stopped at the pro's
        // 60-day booking horizon; before K20 those dates became PERMANENT
        // exception rows the roll-forward would never revisit. Zero skips here
        // is the fix, captured off the live route.
        #expect(series.skippedRows.isEmpty)
        #expect(series.attemptedCount == 8)
        #expect(series.nextOccurrenceIndex == 8)
    }

    @Test("cadence and zone are read from the wire, not invented")
    func cadenceAndZone() throws {
        let series = try decodeSeries("proBookingSeriesOpenEnded")
        #expect(series.intervalWeeks == 1)
        #expect(series.cadenceLabel == "Every week")
        // The zone the PATTERN steps through is the LOCATION's — render a date
        // in any other and the pro reads a different day near midnight.
        #expect(series.timeZone == "America/Los_Angeles")
    }

    @Test("a fortnightly cadence pluralises")
    func cadencePluralises() throws {
        let json = #"{"seriesId":"s","intervalWeeks":2}"#
        let series = try JSONDecoder().decode(
            ProBookingSeriesDetail.self, from: Data(json.utf8)
        )
        #expect(series.cadenceLabel == "Every 2 weeks")
    }

    // MARK: - Degrading

    @Test("a malformed occurrence is dropped, not fatal to the series")
    func malformedOccurrenceIsDropped() throws {
        // A row with no bookingId cannot be opened and a row with no index
        // cannot be numbered; either would be a list entry that lies.
        let json = """
        {
          "seriesId": "ser_1",
          "status": "ACTIVE",
          "occurrences": [
            { "index": 0, "bookingId": "bkg_0", "scheduledFor": "2026-08-11T17:00:00.000Z", "status": "ACCEPTED" },
            { "index": 1, "scheduledFor": "2026-08-18T17:00:00.000Z" },
            { "bookingId": "bkg_2", "scheduledFor": "2026-08-25T17:00:00.000Z" }
          ]
        }
        """
        let series = try JSONDecoder().decode(
            ProBookingSeriesDetail.self, from: Data(json.utf8)
        )
        #expect(series.occurrenceRows.count == 1)
        #expect(series.occurrenceRows.first?.occurrenceNumber == 1)
    }

    @Test("an unknown skip reason still shows the lost date")
    func unknownSkipReasonStillRenders() throws {
        // 🔴 Hiding a skip this build cannot explain would be the exact failure
        // the skip list exists to prevent — it is still a date the pro did not
        // get.
        let json = """
        {
          "seriesId": "ser_1",
          "skipped": [
            { "index": 3, "intendedStart": "2026-09-01T17:00:00.000Z", "reason": "SOMETHING_NEW", "detail": "WHATEVER" }
          ]
        }
        """
        let series = try JSONDecoder().decode(
            ProBookingSeriesDetail.self, from: Data(json.utf8)
        )
        let skip = try #require(series.skippedRows.first)
        #expect(skip.reason == nil)
        #expect(skip.occurrenceNumber == 4)
        #expect(skip.explanation == "This date could not be booked.")
    }

    @Test("a DST-gap skip has no instant, and says so with the wall clock")
    func dstGapSkip() throws {
        let json = """
        {
          "seriesId": "ser_1",
          "skipped": [
            { "index": 5, "intendedStart": null, "reason": "NONEXISTENT_LOCAL_TIME", "detail": "2027-03-14T02:30" }
          ]
        }
        """
        let series = try JSONDecoder().decode(
            ProBookingSeriesDetail.self, from: Data(json.utf8)
        )
        let skip = try #require(series.skippedRows.first)
        #expect(skip.intendedStart == nil)
        #expect(skip.reason == .nonexistentLocalTime)
        #expect(skip.detail == "2027-03-14T02:30")
        #expect(skip.explanation.contains("clocks moved forward"))
    }

    @Test("an unknown series status renders nothing rather than a made-up state")
    func unknownStatusHides() throws {
        let json = #"{"seriesId":"s","status":"PAUSED_SOMEDAY"}"#
        let series = try JSONDecoder().decode(
            ProBookingSeriesDetail.self, from: Data(json.utf8)
        )
        #expect(series.statusDisplay == nil)
    }

    @Test("an empty body decodes — every field is optional by design")
    func emptyBodyDecodes() throws {
        let series = try JSONDecoder().decode(
            ProBookingSeriesDetail.self, from: Data("{}".utf8)
        )
        #expect(series.seriesId == nil)
        #expect(series.occurrenceRows.isEmpty)
        #expect(series.skippedRows.isEmpty)
        #expect(series.attemptedCount == 0)
        #expect(series.plannedLabel == "Open-ended")
    }

    // MARK: - The sentence

    @Test("a counted series names how many are still to come")
    func countedRollForwardSentence() throws {
        let roll = ProBookingSeriesDetail.RollForward(
            willContinue: true, pendingCount: 3, leadDays: 90
        )
        let sentence = try #require(roll.sentence)
        #expect(sentence.contains("3 more appointments are still to come"))

        let one = ProBookingSeriesDetail.RollForward(
            willContinue: true, pendingCount: 1, leadDays: 90
        )
        #expect(try #require(one.sentence).contains("1 more appointment is still to come"))
    }

    @Test("🔴 willContinue is rendered as GIVEN — the device never re-derives it")
    func willContinueIsAuthoritative() throws {
        // The server folds the recurring-appointments kill switch into this
        // flag. A device that recomputed it from status + counts would promise
        // new dates while the operator was switched off
        // ([[verifiable-rail-still-needs-an-operator]]). An ACTIVE series with
        // work left and `willContinue: false` must stay SILENT.
        let json = """
        {
          "seriesId": "ser_1",
          "status": "ACTIVE",
          "occurrenceCount": 12,
          "nextOccurrenceIndex": 4,
          "rollForward": { "willContinue": false, "pendingCount": 8, "leadDays": 90 }
        }
        """
        let series = try JSONDecoder().decode(
            ProBookingSeriesDetail.self, from: Data(json.utf8)
        )
        #expect(series.statusDisplay == .active)
        #expect(series.rollForward?.pendingCount == 8)
        #expect(series.rollForward?.sentence == nil)
    }
}
