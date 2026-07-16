// Per-source export guidance for the pro migration wizard's entry screen — a
// 1:1 port of the web `app/pro/migrate/_exportInstructions.ts` + the SOURCE_APPS
// list from `_constants.ts`. When a pro picks the app they're coming from, we
// show exactly how to get the three files this flow needs (service menu, client
// list, calendar) out of that app. Data-only + brand-neutral (every step is
// about the SOURCE app, never ours), so it lives beside the view — matching the
// web split (this data sits in the UI layer, not lib/).
//
// Every guide was fact-checked against the source app's official help docs on
// 2026-07-15 (sources in tovis-app PR #639); several apps have NO self-serve
// export for a given stage, and the guide then leads with the build-a-CSV
// fallback instead of pointing at a screen that doesn't exist. Keep this file
// in lockstep with the web `EXPORT_GUIDES` — re-verify before editing a path.
import Foundation

/// One source app's export guidance. `calendarFeed` is true when the app can
/// hand you a live iCal feed URL (webcal/https) — a later calendar increment then
/// supports "keep synced" instead of a one-off .ics upload.
struct MigrationExportGuide {
    let menu: String
    let clients: String
    let calendar: String
    let calendarFeed: Bool
}

/// The booking apps a pro is most likely migrating from (web `SOURCE_APPS`),
/// order-preserved. "Other" falls back to the generic guide.
let migrationSourceApps: [String] = [
    "Vagaro",
    "GlossGenius",
    "Booksy",
    "Square",
    "StyleSeat",
    "Fresha",
    "Acuity",
    "Other",
]

private let genericExportGuide = MigrationExportGuide(
    menu: "Open your service or price list and export/download it as a CSV. No export? A simple spreadsheet with a name and price column works too.",
    clients: "Open your client or customer list and export/download it as a CSV or Excel file — both upload fine. Look under Settings, Reports, or the list’s ••• / Export menu.",
    calendar: "Turn on calendar sync to get an iCal (.ics) link, or export your appointments as an .ics file.",
    calendarFeed: false
)

private let migrationExportGuides: [String: MigrationExportGuide] = [
    "Vagaro": MigrationExportGuide(
        menu: "Vagaro’s service list downloads per stylist: Settings → Employees → Employee Profiles → pick the stylist → Services → the download icon (choose Excel — it uploads as-is, and you can pick several files at once). Or just build a quick name-and-price CSV for the whole menu.",
        clients: "In Vagaro (owner login), go to Reports → Customers → Customers, run the report, then Export → Excel. The Excel file uploads as-is.",
        calendar: "In Vagaro on the web, open Calendar and choose Export to iCal to download an .ics of the view on screen. Already had Apple/Outlook calendar sync connected? That subscribe link still works — paste it in later.",
        calendarFeed: false
    ),
    "GlossGenius": MigrationExportGuide(
        menu: "GlossGenius has no service-list export — build a quick CSV with a service name and price column and upload that (we match each name to the catalog as you go).",
        clients: "Log in to GlossGenius in a web browser (the mobile app can’t export; owner account only) and open Clients → Export Clients to download a CSV.",
        calendar: "In GlossGenius, open calendar sync (Settings → Preferences → Two-Way Calendar Sync) and Copy Calendar Link — paste that link in later. It’s the only GlossGenius export that includes upcoming appointments.",
        calendarFeed: true
    ),
    "Booksy": MigrationExportGuide(
        menu: "Booksy has no service-list export — build a quick CSV with a service name and price column and upload that.",
        clients: "In Booksy Biz on desktop, open Clients → More Options → Export to download a CSV. Don’t see it? Ask Booksy support (in-app chat or info.us@booksy.com) for your client list as a CSV.",
        calendar: "Booksy can’t export a calendar or iCal file (its calendar tools only import INTO Booksy). Ask Booksy support for a list of your upcoming appointments, or add them here by hand.",
        calendarFeed: false
    ),
    "Square": MigrationExportGuide(
        menu: "Square can’t export Appointments services (the Item library export covers retail items only) — build a quick CSV with a service name and price column and upload that.",
        clients: "In Square Dashboard, go to Customers → Customer directory → Import/Export → Export customers to download a CSV.",
        calendar: "Square has no iCal feed of its own. In Appointments → Settings → Calendar & booking, link Google Calendar (export only), then paste your Google Calendar’s private iCal address in later to bring bookings in.",
        calendarFeed: false
    ),
    "StyleSeat": MigrationExportGuide(
        menu: "StyleSeat has no service export — build a quick CSV with a service name and price column and upload that.",
        clients: "In StyleSeat, open your Clients tab and tap ••• → Export Client List. StyleSeat emails the CSV to your verified email address — check your inbox (and spam) rather than waiting for a download.",
        calendar: "StyleSeat can’t export appointments (its calendar sync only pulls your personal calendar in). Ask StyleSeat support for an appointments list, or add upcoming bookings here by hand.",
        calendarFeed: false
    ),
    "Fresha": MigrationExportGuide(
        menu: "In Fresha, open Catalog → Service menu and use Options → Export to download your service list as a CSV.",
        clients: "In Fresha, open Clients → Options → Export to download your client list as a CSV (on team accounts this needs the “Can download clients” permission).",
        calendar: "In Fresha, open Calendar sync (profile picture → Manage workspace → Calendar sync), choose Other Calendars → Export your Fresha Calendar, and paste the link in later. Fresha hides client and service details in that feed, so bookings arrive as held time slots.",
        calendarFeed: true
    ),
    "Acuity": MigrationExportGuide(
        menu: "Acuity has no appointment-type export — build a quick CSV with a service name and price column and upload that.",
        clients: "In Acuity, open Clients → Import/export → Export client list to download a CSV.",
        calendar: "In Acuity, open Sync with Other Calendars → 1-way Calendar Sync and copy the link at the bottom of the page — paste it in later to keep bookings in sync (clicking the link instead downloads a one-time .ics).",
        calendarFeed: true
    ),
]

/// The export guide for a source app (web `exportGuideFor`). "Other" / unknown
/// → the generic guide.
func migrationExportGuide(for source: String) -> MigrationExportGuide {
    migrationExportGuides[source] ?? genericExportGuide
}
