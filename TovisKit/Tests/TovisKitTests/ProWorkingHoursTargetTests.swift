import Foundation
import Testing
@testable import TovisKit

// Pure resolution of which location the working-hours editor edits. The founder
// case (mobile-only pro, archived salon) is the regression this guards: the old
// editor hardcoded SALON and 409'd on save. `locationToEdit` must pick the
// bookable MOBILE base instead.
struct ProWorkingHoursTargetTests {
    /// Decode a `ProLocationSummary` from a minimal fixture (it's Decodable-only).
    private func loc(
        id: String,
        type: String,
        isPrimary: Bool,
        isBookable: Bool,
        name: String? = nil
    ) -> ProLocationSummary {
        var dict: [String: Any] = [
            "id": id, "type": type, "isPrimary": isPrimary, "isBookable": isBookable,
        ]
        if let name { dict["name"] = name }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(ProLocationSummary.self, from: data)
    }

    @Test func mobileOnlyProEditsTheBookableMobileBase() {
        // Founder case: bookable MOBILE base + an archived (non-bookable) salon.
        let locations = [
            loc(id: "mob", type: "MOBILE_BASE", isPrimary: true, isBookable: true),
            loc(id: "sal", type: "SALON", isPrimary: false, isBookable: false),
        ]
        let chosen = ProWorkingHours.locationToEdit(from: locations)
        #expect(chosen?.id == "mob")
        #expect(ProWorkingHours.mode(for: chosen!) == "MOBILE")
    }

    @Test func picksPrimaryBookableLocation() {
        let locations = [
            loc(id: "a", type: "SALON", isPrimary: false, isBookable: true),
            loc(id: "b", type: "SUITE", isPrimary: true, isBookable: true),
        ]
        #expect(ProWorkingHours.locationToEdit(from: locations)?.id == "b")
    }

    @Test func fallsBackToFirstBookableWhenNoPrimary() {
        let locations = [
            loc(id: "a", type: "SALON", isPrimary: false, isBookable: true),
            loc(id: "b", type: "SALON", isPrimary: false, isBookable: true),
        ]
        #expect(ProWorkingHours.locationToEdit(from: locations)?.id == "a")
    }

    @Test func honorsPreferredLocationWhenBookable() {
        let locations = [
            loc(id: "primary", type: "SALON", isPrimary: true, isBookable: true),
            loc(id: "other", type: "MOBILE_BASE", isPrimary: false, isBookable: true),
        ]
        let chosen = ProWorkingHours.locationToEdit(
            from: locations, preferredLocationId: "other")
        #expect(chosen?.id == "other")
    }

    @Test func ignoresPreferredWhenNotBookableAndFallsBackToPrimary() {
        let locations = [
            loc(id: "primary", type: "SALON", isPrimary: true, isBookable: true),
            loc(id: "archived", type: "SUITE", isPrimary: false, isBookable: false),
        ]
        // Preferred points at a non-bookable location → fall back to primary.
        let chosen = ProWorkingHours.locationToEdit(
            from: locations, preferredLocationId: "archived")
        #expect(chosen?.id == "primary")
    }

    @Test func noBookableLocationReturnsNil() {
        let locations = [
            loc(id: "sal", type: "SALON", isPrimary: true, isBookable: false),
        ]
        #expect(ProWorkingHours.locationToEdit(from: locations) == nil)
        #expect(ProWorkingHours.locationToEdit(from: []) == nil)
    }

    @Test func modeMapsTypesToApiParam() {
        #expect(ProWorkingHours.mode(for:
            loc(id: "1", type: "MOBILE_BASE", isPrimary: true, isBookable: true)) == "MOBILE")
        #expect(ProWorkingHours.mode(for:
            loc(id: "2", type: "SALON", isPrimary: true, isBookable: true)) == "SALON")
        #expect(ProWorkingHours.mode(for:
            loc(id: "3", type: "SUITE", isPrimary: true, isBookable: true)) == "SALON")
    }
}
