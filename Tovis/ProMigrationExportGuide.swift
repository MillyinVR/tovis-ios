// Per-source export guidance for the pro migration wizard's entry screen — a
// 1:1 port of the web `app/pro/migrate/_exportInstructions.ts` + the SOURCE_APPS
// list from `_constants.ts`. When a pro picks the app they're coming from, we
// show exactly how to get the three files this flow needs (service menu, client
// list, calendar) out of that app. Data-only + brand-neutral (every step is
// about the SOURCE app, never ours), so it lives beside the view — matching the
// web split (this data sits in the UI layer, not lib/).
//
// Steps are intentionally version-agnostic: point the pro at the right screen +
// format, don't assert exact menu paths that shift between app releases.
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
    clients: "Open your client or customer list and export/download it as a CSV. Look under Settings, Reports, or the list’s ••• / Export menu.",
    calendar: "Turn on calendar sync to get an iCal (.ics) link, or export your appointments as an .ics file.",
    calendarFeed: false
)

private let migrationExportGuides: [String: MigrationExportGuide] = [
    "Vagaro": MigrationExportGuide(
        menu: "In Vagaro, open your service menu (Business → Services) and export the list as a CSV.",
        clients: "In Vagaro, go to Customers and choose Export to download your client list as a CSV.",
        calendar: "In Vagaro, turn on Calendar Sync to get an iCal feed link you can paste in later, or export your appointments as .ics.",
        calendarFeed: true
    ),
    "GlossGenius": MigrationExportGuide(
        menu: "GlossGenius has no service-list export — build a quick CSV with a service name and price column and upload that (we match each name to the catalog as you go).",
        clients: "In GlossGenius, open Clients and use Export clients to download a CSV.",
        calendar: "In GlossGenius, connect your calendar (Google/Apple) to get an iCal link, or export upcoming appointments as .ics.",
        calendarFeed: false
    ),
    "Booksy": MigrationExportGuide(
        menu: "In Booksy, open your services list and export it as a CSV, or build a simple name-and-price CSV to upload.",
        clients: "In Booksy, open Customers and export your client list as a CSV (via Settings or Booksy support if needed).",
        calendar: "In Booksy, enable calendar sync to get an iCal link, or export your appointments as .ics.",
        calendarFeed: false
    ),
    "Square": MigrationExportGuide(
        menu: "In Square Dashboard, open Items & Services → Actions → Export to download your services as a CSV.",
        clients: "In Square Dashboard, open Customer Directory → Export customers to download a CSV.",
        calendar: "In Square Appointments, enable the calendar subscription to get an iCal feed link you can paste in later.",
        calendarFeed: true
    ),
    "StyleSeat": MigrationExportGuide(
        menu: "StyleSeat has no service export — build a quick CSV with a service name and price column and upload that.",
        clients: "In StyleSeat, open your Clients list and export it as a CSV (Settings → Clients, or via StyleSeat support).",
        calendar: "In StyleSeat, sync your calendar to get an iCal link, or export your appointments as .ics.",
        calendarFeed: false
    ),
    "Fresha": MigrationExportGuide(
        menu: "In Fresha, open Catalog → Services and export your service list as a CSV.",
        clients: "In Fresha, open Clients and use Export to download your client list as a CSV.",
        calendar: "In Fresha, turn on calendar sync to get an iCal link, or export your appointments as .ics.",
        calendarFeed: false
    ),
    "Acuity": MigrationExportGuide(
        menu: "In Acuity, open your Appointment Types and export them, or build a quick name-and-price CSV.",
        clients: "In Acuity, open Client List → Import/Export and export your clients as a CSV.",
        calendar: "In Acuity, copy your calendar Subscribe (iCal) feed URL and paste it in later to keep bookings in sync.",
        calendarFeed: true
    ),
]

/// The export guide for a source app (web `exportGuideFor`). "Other" / unknown
/// → the generic guide.
func migrationExportGuide(for source: String) -> MigrationExportGuide {
    migrationExportGuides[source] ?? genericExportGuide
}
