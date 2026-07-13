import Foundation

// Pure resolution of WHICH location's week the pro working-hours editor edits.
// The editor must never assume a fixed location type: a mobile-only pro has an
// archived (non-bookable) salon, so `locationType=SALON` finds no bookable salon
// and the POST 409s ("No bookable salon/suite location exists yet") — the save
// silently fails. Instead we resolve the pro's primary bookable location (any
// type) and edit that, mirroring the web (`useCalendarLocations` picks the
// primary bookable location and saves via its id).

public enum ProWorkingHours {
    /// Pick which bookable location's week to edit:
    /// 1. the caller's `preferredLocationId`, when it's still bookable
    ///    (a location switcher's selection), else
    /// 2. the primary bookable location, else
    /// 3. the first bookable location.
    ///
    /// Returns nil when the pro has NO bookable location — the working-hours API
    /// would 409 on save, so the caller should prompt to publish a location
    /// rather than load default hours against a phantom salon.
    public static func locationToEdit(
        from locations: [ProLocationSummary],
        preferredLocationId: String? = nil
    ) -> ProLocationSummary? {
        let bookable = locations.filter(\.isBookable)

        if let preferredLocationId,
           let match = bookable.first(where: { $0.id == preferredLocationId }) {
            return match
        }

        return bookable.first(where: \.isPrimary) ?? bookable.first
    }

    /// The working-hours API `locationType` query param for a location —
    /// "MOBILE" for a ZIP-anchored travel base, else "SALON" (salon/suite).
    public static func mode(for location: ProLocationSummary) -> String {
        location.isMobileBase ? "MOBILE" : "SALON"
    }
}
