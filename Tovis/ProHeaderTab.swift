// The pro top-header secondary tabs — the native counterpart of the web
// `ProHeader` PRO_HEADER_TABS (app/pro/ProHeader.tsx): Overview · Reviews ·
// Aftercare · Bookings · Last Minute · Locations. (The web "Import" tab is
// migration-flag-gated and omitted natively.)
//
// On web these live in a GLOBAL header above every pro page. Natively we host
// them on a dedicated Overview home (`ProOverviewHomeView`) so the footer can
// keep the web `ProSessionFooter` 5 slots untouched.
import Foundation

enum ProHeaderTab: String, CaseIterable, Identifiable {
    case overview, reviews, aftercare, bookings, lastMinute, locations

    var id: String { rawValue }

    /// The strip label (web tab `label`).
    var label: String {
        switch self {
        case .overview:   return "Overview"
        case .reviews:    return "Reviews"
        case .aftercare:  return "Aftercare"
        case .bookings:   return "Bookings"
        case .lastMinute: return "Last Minute"
        case .locations:  return "Locations"
        }
    }

    /// The big page title (web `PRO_HEADER_ROUTE_TITLES`). Same text as the strip
    /// label today, but kept separate so a tab can show a different title later.
    var title: String { label }
}
