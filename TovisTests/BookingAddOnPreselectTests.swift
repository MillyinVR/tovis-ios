import Foundation
import Testing
import TovisKit

@testable import Tovis

/// Which add-ons arrive ticked in the booking sheet.
///
/// The pro has TWO independent pills in web's offering manager: "Recommend"
/// (a badge) and "Pre-select" (starts ticked). Tori, 2026-08-14: a recommended
/// add-on does NOT auto pre-select. Web reads `isPreselected` for the initial
/// selection (`booking/add-ons/page.tsx`, `AddOnsClient.tsx`); iOS read
/// `isRecommended` until this was fixed, so a pro who recommended an add-on
/// without pre-selecting it got the behaviour they asked for on web and the old
/// behaviour here — a paid upgrade silently pre-ticked on one client only.
///
/// Built by DECODING the wire rather than by hand, so the model's decode and the
/// selection rule are pinned together.
struct BookingAddOnPreselectTests {
    private func addOns(_ json: String) throws -> [BookingAddOn] {
        struct Envelope: Decodable { let addOns: [BookingAddOn] }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).addOns
    }

    /// The two flags CROSSED — the combination that made the old code wrong.
    @Test func ticksPreselectedOnlyNotRecommended() throws {
        let rows = try addOns("""
        { "addOns": [
          { "id": "a_badge", "serviceId": "svc_1", "title": "Gloss", "group": null,
            "price": "35.00", "minutes": 30, "sortOrder": 0,
            "isRecommended": true, "isPreselected": false },
          { "id": "a_tick", "serviceId": "svc_2", "title": "Bond mask", "group": null,
            "price": "25.00", "minutes": 20, "sortOrder": 1,
            "isRecommended": false, "isPreselected": true }
        ] }
        """)

        #expect(BookingAddOnsView.preselectedIds(from: rows) == ["a_tick"])
    }

    /// Both flags on is the one case where old and new agree; pinned so a later
    /// "simplification" back to `isRecommended` cannot hide behind it.
    @Test func ticksAnAddOnThatIsBothRecommendedAndPreselected() throws {
        let rows = try addOns("""
        { "addOns": [
          { "id": "a_both", "serviceId": "svc_1", "title": "Gloss", "group": null,
            "price": "35.00", "minutes": 30, "sortOrder": 0,
            "isRecommended": true, "isPreselected": true }
        ] }
        """)

        #expect(BookingAddOnsView.preselectedIds(from: rows) == ["a_both"])
    }

    /// A server predating `isPreselected` omits the key. Nothing may arrive
    /// ticked — the old code would have ticked every recommended row.
    @Test func ticksNothingWhenTheServerOmitsTheField() throws {
        let rows = try addOns("""
        { "addOns": [
          { "id": "a_old", "serviceId": "svc_1", "title": "Gloss", "group": null,
            "price": "35.00", "minutes": 30, "sortOrder": 0,
            "isRecommended": true }
        ] }
        """)

        #expect(BookingAddOnsView.preselectedIds(from: rows).isEmpty)
    }
}
