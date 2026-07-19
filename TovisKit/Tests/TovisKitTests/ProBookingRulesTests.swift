import Foundation
import Testing
@testable import TovisKit

// Round-3 queue item 15 (d): business rules that were living in SwiftUI views,
// where `swift test` could not reach them. Moving them onto the models is only
// worth doing if they are then actually pinned — that is what this file is.
//
// Two of these gate what a pro is ALLOWED to do, so each is diffed against the
// web rule it mirrors rather than assumed to agree with it.

@Suite("Pro booking display rules")
struct ProBookingStatusLabelTests {
    private func detail(status: String) throws -> ProBookingDetail {
        var raw = try JSONSerialization.jsonObject(
            with: fixture("proBookingDetail")) as! [String: Any]
        var booking = raw["booking"] as! [String: Any]
        booking["status"] = status
        raw["booking"] = booking
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(ProBookingDetailResponse.self, from: data).booking
    }

    @Test("ACCEPTED reads as Confirmed, not as the wire word")
    func acceptedReadsConfirmed() throws {
        // The one arm that is a translation rather than capitalization: the wire
        // says ACCEPTED, a pro reads "Confirmed".
        #expect(try detail(status: "ACCEPTED").statusLabel == "Confirmed")
    }

    @Test("NO_SHOW reads as No-show, not the raw enum")
    func noShowReadsHyphenated() throws {
        // Without this arm the default renders "No_show" — which is exactly what
        // this screen did until "Mark no-show" (#175) first made the state
        // reachable here.
        #expect(try detail(status: "NO_SHOW").statusLabel == "No-show")
        #expect(try detail(status: "NO_SHOW").statusLabel != "No_show")
    }

    @Test("The remaining statuses read as their plain labels")
    func plainLabels() throws {
        #expect(try detail(status: "PENDING").statusLabel == "Pending")
        #expect(try detail(status: "IN_PROGRESS").statusLabel == "In progress")
        #expect(try detail(status: "COMPLETED").statusLabel == "Completed")
        #expect(try detail(status: "CANCELLED").statusLabel == "Cancelled")
    }

    @Test("An unknown status degrades to capitalized rather than throwing it away")
    func unknownStatusDegrades() throws {
        // The wire enum can grow. A future member should still render as
        // something a human can read, not blank.
        #expect(try detail(status: "RESCHEDULED").statusLabel == "Rescheduled")
    }
}

@Suite("Consultation line-item prefill")
struct InitialConsultationItemsTests {
    private func detail(serviceItems: [[String: Any]]) throws -> ProBookingDetail {
        var raw = try JSONSerialization.jsonObject(
            with: fixture("proBookingDetail")) as! [String: Any]
        var booking = raw["booking"] as! [String: Any]
        booking["serviceItems"] = serviceItems
        raw["booking"] = booking
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(ProBookingDetailResponse.self, from: data).booking
    }

    private func item(
        id: String, type: String, name: String, price: String? = "10.00",
        minutes: Int = 30, sortOrder: Int = 0
    ) -> [String: Any] {
        [
            "id": id, "serviceId": "svc_\(id)", "offeringId": NSNull(),
            "itemType": type, "serviceName": name,
            "priceSnapshot": price ?? NSNull(),
            "durationMinutesSnapshot": minutes, "sortOrder": sortOrder,
        ]
    }

    @Test("The wire's own itemType is carried through, at any position")
    func itemTypePassthrough() throws {
        // The view's expression LOOKED index-sensitive:
        //   isAddOn ? "ADD_ON" : (index == 0 ? "BASE" : (isAddOn ? "ADD_ON" : "BASE"))
        // but its inner ternary re-tested a condition already known false, so
        // both index branches returned "BASE" and `index` never mattered. This
        // pins the behaviour that expression actually had — an ADD_ON in FIRST
        // position stays ADD_ON, and a BASE in second position stays BASE.
        let d = try detail(serviceItems: [
            item(id: "a", type: "ADD_ON", name: "Gloss", sortOrder: 0),
            item(id: "b", type: "BASE", name: "Balayage", sortOrder: 1),
        ])
        let items = d.initialConsultationItems
        #expect(items.map(\.itemType) == ["ADD_ON", "BASE"])
    }

    @Test("A blank service name falls back to Service — including whitespace-only")
    func blankNameFallsBack() throws {
        // Web uses `item.service?.name?.trim() || 'Service'`. The view checked
        // `.isEmpty` WITHOUT trimming, so a whitespace-only name rendered as
        // blank on iOS and "Service" on web. This is the discriminating case.
        let d = try detail(serviceItems: [
            item(id: "a", type: "BASE", name: "", sortOrder: 0),
            item(id: "b", type: "BASE", name: "   ", sortOrder: 1),
            item(id: "c", type: "BASE", name: "  Balayage  ", sortOrder: 2),
        ])
        let items = d.initialConsultationItems
        #expect(items[0].label == "Service")
        #expect(items[1].label == "Service") // ← the view rendered "   " here
        #expect(items[2].label == "Balayage")
    }

    @Test("Duration renders only when positive, price passes through")
    func durationAndPrice() throws {
        let d = try detail(serviceItems: [
            item(id: "a", type: "BASE", name: "X", price: "180.00", minutes: 120),
            item(id: "b", type: "BASE", name: "Y", price: nil, minutes: 0, sortOrder: 1),
        ])
        let items = d.initialConsultationItems
        #expect(items[0].durationMinutes == "120")
        #expect(items[0].price == "180.00")
        #expect(items[1].durationMinutes == "")
        #expect(items[1].price == "")
    }

    @Test("An empty booking prefills nothing rather than a placeholder row")
    func emptyBooking() throws {
        #expect(try detail(serviceItems: []).initialConsultationItems.isEmpty)
    }
}

@Suite("Session consultation rules")
struct ProSessionStateRulesTests {
    private func state(status: String?, consultation: String?) throws -> ProSessionState {
        var raw = try JSONSerialization.jsonObject(
            with: fixture("proSessionState")) as! [String: Any]
        var s = raw["state"] as! [String: Any]
        s["status"] = status ?? NSNull()
        if let consultation {
            s["consultation"] = ["status": consultation, "approvedAt": NSNull(),
                                 "rejectedAt": NSNull(), "proof": NSNull()]
        } else {
            s["consultation"] = NSNull()
        }
        raw["state"] = s
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(ProSessionStateResponse.self, from: data).state
    }

    @Test("Consultation status labels, and None when there is no consultation")
    func consultationLabels() throws {
        #expect(try state(status: "ACCEPTED", consultation: "PENDING")
            .consultationStatusLabel == "Pending")
        #expect(try state(status: "ACCEPTED", consultation: "APPROVED")
            .consultationStatusLabel == "Approved")
        #expect(try state(status: "ACCEPTED", consultation: "REJECTED")
            .consultationStatusLabel == "Rejected")
        #expect(try state(status: "ACCEPTED", consultation: nil)
            .consultationStatusLabel == "None")
        // An unrecognized status reads as "no consultation" rather than leaking
        // the raw wire value onto the pill.
        #expect(try state(status: "ACCEPTED", consultation: "WITHDRAWN")
            .consultationStatusLabel == "None")
    }

    // ⚠️ The gate below decides whether a pro may start work. Mirrors web's
    // `canProceedToBefore` (app/pro/bookings/[id]/session/page.tsx:743).

    @Test("Proceeding needs BOTH an approved consultation and a workable status")
    func proceedNeedsBothHalves() throws {
        #expect(try state(status: "ACCEPTED", consultation: "APPROVED")
            .canProceedToBeforePhotos)
        #expect(try state(status: "IN_PROGRESS", consultation: "APPROVED")
            .canProceedToBeforePhotos)
    }

    @Test("Approval alone does NOT unlock a booking that is still pending")
    func approvalAloneIsNotEnough() throws {
        // The half most likely to be dropped by a careless consolidation: an
        // approved consultation on a PENDING booking must stay blocked, because
        // the pro has not accepted the booking yet.
        #expect(try !state(status: "PENDING", consultation: "APPROVED")
            .canProceedToBeforePhotos)
        #expect(try !state(status: "CANCELLED", consultation: "APPROVED")
            .canProceedToBeforePhotos)
        #expect(try !state(status: nil, consultation: "APPROVED")
            .canProceedToBeforePhotos)
    }

    @Test("A workable status alone does NOT unlock it either")
    func statusAloneIsNotEnough() throws {
        #expect(try !state(status: "ACCEPTED", consultation: "PENDING")
            .canProceedToBeforePhotos)
        #expect(try !state(status: "ACCEPTED", consultation: "REJECTED")
            .canProceedToBeforePhotos)
        #expect(try !state(status: "IN_PROGRESS", consultation: nil)
            .canProceedToBeforePhotos)
    }
}
