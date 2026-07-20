import Foundation
import Testing

@testable import TovisKit

// Wire coverage for the aftercare rebook slot's pro-picked mobile address —
// the save request must carry the address the availability was computed for,
// and the prefill decode must round it back so re-editing keeps the pick.
struct AftercareRebookSlotWireTests {
    @Test func saveRequestEncodesMobileSlotClientAddress() throws {
        let request = ProAftercareSaveRequest(
            notes: "x", recommendedProducts: [],
            rebookMode: "BOOKED_NEXT_APPOINTMENT",
            rebookedFor: "2026-08-10T18:00:00.000Z",
            rebookSlot: .init(
                offeringId: "offering_1", locationId: "location_1",
                locationType: "MOBILE", clientAddressId: "addr_1",
                startsAt: "2026-08-10T18:00:00.000Z",
                endsAt: "2026-08-10T19:30:00.000Z"),
            rebookWindowStart: nil, rebookWindowEnd: nil,
            createRebookReminder: false, rebookReminderDaysBefore: 2,
            createProductReminder: false, productReminderDaysAfter: 7,
            featuredBeforeAssetId: nil, featuredAfterAssetId: nil,
            sendToClient: true, timeZone: "America/Los_Angeles", version: 1)

        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let slot = try #require(object["rebookSlot"] as? [String: Any])
        #expect(slot["clientAddressId"] as? String == "addr_1")
        #expect(slot["locationType"] as? String == "MOBILE")
    }

    @Test func saveRequestOmitsClientAddressWhenNil() throws {
        // Salon slots (and older flows) carry no address; the field is omitted
        // and the server treats absent as null.
        let request = ProAftercareSaveRequest(
            notes: "x", recommendedProducts: [],
            rebookMode: "BOOKED_NEXT_APPOINTMENT",
            rebookedFor: "2026-08-10T18:00:00.000Z",
            rebookSlot: .init(
                offeringId: "offering_1", locationId: "location_1",
                locationType: "SALON",
                startsAt: "2026-08-10T18:00:00.000Z",
                endsAt: "2026-08-10T19:00:00.000Z"),
            rebookWindowStart: nil, rebookWindowEnd: nil,
            createRebookReminder: false, rebookReminderDaysBefore: 2,
            createProductReminder: false, productReminderDaysAfter: 7,
            featuredBeforeAssetId: nil, featuredAfterAssetId: nil,
            sendToClient: true, timeZone: nil, version: nil)

        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let slot = try #require(object["rebookSlot"] as? [String: Any])
        #expect(slot["clientAddressId"] == nil)
    }

    @Test func prefillSlotDecodesClientAddress() throws {
        let json = Data("""
        {
          "id": "slot_1",
          "offeringId": "offering_1",
          "locationId": "location_1",
          "locationType": "MOBILE",
          "clientAddressId": "addr_1",
          "startsAt": "2026-08-10T18:00:00.000Z",
          "endsAt": "2026-08-10T19:30:00.000Z"
        }
        """.utf8)

        let slot = try JSONDecoder().decode(ProAftercareRebookSlot.self, from: json)
        #expect(slot.clientAddressId == "addr_1")
    }

    @Test func prefillSlotDecodesWithoutClientAddress() throws {
        // Older backends (before the address-pick pass) omit the field.
        let json = Data("""
        {
          "id": "slot_1",
          "offeringId": "offering_1",
          "locationId": "location_1",
          "locationType": "SALON",
          "startsAt": "2026-08-10T18:00:00.000Z",
          "endsAt": "2026-08-10T19:00:00.000Z"
        }
        """.utf8)

        let slot = try JSONDecoder().decode(ProAftercareRebookSlot.self, from: json)
        #expect(slot.clientAddressId == nil)
    }

    @Test func proBookingClientDecodesProfileId() throws {
        let json = Data("""
        {"id": "client_1", "fullName": "Test Client", "email": null, "phone": null}
        """.utf8)

        let client = try JSONDecoder().decode(ProBookingClient.self, from: json)
        #expect(client.id == "client_1")
    }

    @Test func proBookingClientDecodesWithoutProfileId() throws {
        // Pre-field backends omit `id`; the picker then simply doesn't load.
        let json = Data("""
        {"fullName": "Test Client", "email": null, "phone": null}
        """.utf8)

        let client = try JSONDecoder().decode(ProBookingClient.self, from: json)
        #expect(client.id == nil)
    }
}
