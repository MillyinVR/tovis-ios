import Foundation
import Testing
@testable import TovisKit

// Decode of a HOLD row from `GET /api/v1/pro/calendar` (B5).
//
// The pro calendar feed used to carry BOOKING + BLOCK only, so a client's live
// checkout reservation was invisible on the calendar AND in both overlap
// warnings, while the write path authorized a pro booking straight over it and
// the client was refused at their own confirm.
//
// The JSON below is a VERBATIM capture of an `events[]` entry from a live
// `GET /api/v1/pro/calendar`, driven against the local dev stack as the seeded
// pro — not a hand-built mock of the shape this model hopes for. A mock of the
// assumed shape passes while the real wire rots.
// [[wire-shape-vs-mock-drift]]
//
// What the capture shows that a mock would not have: a HOLD carries NO
// `details`, NO `timeZone`, NO `clientProfileId` and NO `blockId` — every one of
// which a BOOKING sends. `ProCalendarEvent` has to decode it anyway, because a
// single throw here fails the WHOLE `events` array and would blank the pro's
// calendar rather than hide one tile.
struct ProCalendarHoldEventTests {
    private func decode(_ json: String) throws -> ProCalendarEvent {
        try JSONDecoder().decode(ProCalendarEvent.self, from: Data(json.utf8))
    }

    private var liveHoldRow: String {
        """
        {
          "id": "hold:cms0kcrko0001poq22z5v5h60",
          "holdId": "cms0kcrko0001poq22z5v5h60",
          "kind": "HOLD",
          "startsAt": "2026-07-26T22:00:00.000Z",
          "endsAt": "2026-07-27T01:15:00.000Z",
          "title": "Booking in progress",
          "clientName": "Held",
          "status": "HELD",
          "locationType": "SALON",
          "locationId": "cmrbry47t000fpo0dz0kdy80z",
          "durationMinutes": 195,
          "localDateKey": "2026-07-26",
          "expiresAt": "2026-07-25T22:08:23.437Z"
        }
        """
    }

    @Test("a hold row decodes even though it carries none of a booking's fields")
    func decodesHoldRow() throws {
        let event = try decode(liveHoldRow)

        #expect(event.id == "hold:cms0kcrko0001poq22z5v5h60")
        #expect(event.kind == "HOLD")
        #expect(event.status == "HELD")
        #expect(event.durationMinutes == 195)
        #expect(event.localDateKey == "2026-07-26")

        // The fields a BOOKING sends and a HOLD does not.
        #expect(event.timeZone == nil)
        #expect(event.clientProfileId == nil)
        #expect(event.blockId == nil)
    }

    @Test("a hold classifies as held, and as neither a booking nor a block")
    func classifiesAsHold() throws {
        let event = try decode(liveHoldRow)

        #expect(event.isHold)
        #expect(!event.isBooking)
        // ⚠️ The load-bearing one. Every render site branches
        // `isBlock ? … : …`; if a hold read as a block it would take the block
        // tap path (which opens an editor for a block that does not exist) and
        // the muted "your own time" tone.
        #expect(!event.isBlock)
        #expect(!event.isWaitlist)
    }

    // A hold is somebody's in-flight checkout. The pro is told the slot is
    // spoken for, never who is hesitating over it — so the anonymity has to be a
    // property of the PAYLOAD, not just of the views that render it.
    @Test("a hold names nobody")
    func staysAnonymous() throws {
        let event = try decode(liveHoldRow)

        #expect(event.clientName == "Held")
        #expect(event.clientProfileId == nil)
        #expect(!event.title.isEmpty)
    }

    // Nothing acts on a hold, so no pro-facing id should be derivable from it.
    // `calendarBlockId` falls back to `id` for a non-block, which is fine only
    // because no block call site is reachable for a hold (`isBlock` is false) —
    // pinned here so a future refactor that starts trusting it gets caught.
    @Test("a hold is not mistaken for an actionable block id")
    func doesNotYieldABlockId() throws {
        let event = try decode(liveHoldRow)

        #expect(!event.isBlock)
        #expect(event.blockId == nil)
    }

    @Test("a mixed feed keeps holds alongside bookings")
    func decodesInsideAFeed() throws {
        let feed = """
        [
          \(liveHoldRow),
          {
            "id": "block:cmrr461ch0001pod6fiyvnppm",
            "blockId": "cmrr461ch0001pod6fiyvnppm",
            "kind": "BLOCK",
            "startsAt": "2026-07-26T17:00:00.000Z",
            "endsAt": "2026-07-26T18:00:00.000Z",
            "title": "Blocked time",
            "clientName": "Personal",
            "status": "BLOCKED",
            "locationType": null,
            "locationId": null,
            "durationMinutes": 60,
            "localDateKey": "2026-07-26"
          }
        ]
        """

        let events = try JSONDecoder().decode(
            [ProCalendarEvent].self, from: Data(feed.utf8))

        #expect(events.count == 2)
        #expect(events[0].isHold)
        #expect(events[1].isBlock)
        #expect(!events[1].isHold)
    }
}
