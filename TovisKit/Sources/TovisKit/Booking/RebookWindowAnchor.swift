import Foundation

/// Where the booking flow should OPEN when a client taps "Rebook now" on their
/// care plan.
///
/// Tori, 2026-08-14: *"when a client chooses rebook now it should open to the
/// time frame the pro gave them so they can just choose a date and time from
/// there. not having to look for the date."*
///
/// The pro's `AftercareSummary.rebookWindowStart` is usually weeks out, and the
/// day scroller only carries a 7-day window from wherever it starts — so a flow
/// that opens on today doesn't merely start in the wrong place, it doesn't
/// contain the pro's window at all. `GET /api/v1/availability/bootstrap` takes a
/// `startDate` for exactly this; the web `AftercareRebookButton` has passed one
/// since it shipped. This is the native half of the same rule.
///
/// Pure + timezone-explicit so it can be tested without a server or a view.
public enum RebookWindowAnchor {
    /// The "yyyy-MM-dd" (in the appointment's zone) the rebook flow should open
    /// on, or nil to let the server pick its usual first available day.
    ///
    /// Nil is returned when:
    /// * there is no window (the pro left the rebook mode NONE);
    /// * the ISO instant or the zone can't be parsed;
    /// * the window has **already started**. That last one is not a nicety —
    ///   `resolveSummaryWindowStart` REFUSES a past `startDate` outright
    ///   ("startDate cannot be in the past"), so anchoring to a window the
    ///   client is already inside would turn "Rebook now" into an error screen
    ///   instead of a picker. Mirrors the web button's `startYmd > todayYmd`
    ///   guard.
    public static func openingDay(
        windowStartISO: String?,
        timeZone: String?,
        now: Date = Date()
    ) -> String? {
        guard
            let windowStartISO,
            !windowStartISO.isEmpty,
            let start = Wire.date(windowStartISO),
            let zone = timeZone.flatMap(TimeZone.init(identifier:))
        else { return nil }

        let startYmd = ProCalendarGrid.ymd(start, zone)
        let todayYmd = ProCalendarGrid.ymd(now, zone)
        // Lexicographic compare is a real date compare for "yyyy-MM-dd".
        return startYmd > todayYmd ? startYmd : nil
    }
}
