import Foundation
import Testing
@testable import TovisKit

// The aftercare save's scheduling-override fields (allowOutsideWorkingHours /
// allowShortNotice / allowFarFuture / overrideReason) must be OMITTED unless
// the pro explicitly confirmed an override: the idempotency key is a
// payload-hash nonce, so a silently-added `false` would change every existing
// payload's hash, and the server treats a missing key as false anyway.
@Suite struct AftercareOverrideEncodingTests {
    private func encode(_ request: ProAftercareSaveRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private func makeRequest(
        allowOutsideWorkingHours: Bool? = nil,
        overrideReason: String? = nil
    ) -> ProAftercareSaveRequest {
        ProAftercareSaveRequest(
            notes: "Notes",
            recommendedProducts: [],
            rebookMode: "BOOKED_NEXT_APPOINTMENT",
            rebookedFor: "2026-08-08T21:00:00.000Z",
            rebookSlot: .init(
                offeringId: "off_1", locationId: "loc_1", locationType: "SALON",
                startsAt: "2026-08-08T21:00:00.000Z",
                endsAt: "2026-08-08T22:00:00.000Z",
            ),
            rebookWindowStart: nil,
            rebookWindowEnd: nil,
            createRebookReminder: false,
            rebookReminderDaysBefore: 2,
            createProductReminder: false,
            productReminderDaysAfter: 7,
            featuredBeforeAssetId: nil,
            featuredAfterAssetId: nil,
            sendToClient: false,
            timeZone: "America/Los_Angeles",
            version: 1,
            allowOutsideWorkingHours: allowOutsideWorkingHours,
            overrideReason: overrideReason,
        )
    }

    @Test func omitsOverrideKeysWhenNotConfirmed() throws {
        let json = try encode(makeRequest())
        #expect(json["allowOutsideWorkingHours"] == nil)
        #expect(json["allowShortNotice"] == nil)
        #expect(json["allowFarFuture"] == nil)
        #expect(json["overrideReason"] == nil)
    }

    @Test func sendsConfirmedOverrideFlagAndReason() throws {
        let json = try encode(makeRequest(
            allowOutsideWorkingHours: true,
            overrideReason: "Saturday regular — off-book standing appointment.",
        ))
        #expect(json["allowOutsideWorkingHours"] as? Bool == true)
        #expect(
            json["overrideReason"] as? String
                == "Saturday regular — off-book standing appointment.")
        // Unconfirmed flags stay omitted even when one is set.
        #expect(json["allowShortNotice"] == nil)
        #expect(json["allowFarFuture"] == nil)
    }
}
