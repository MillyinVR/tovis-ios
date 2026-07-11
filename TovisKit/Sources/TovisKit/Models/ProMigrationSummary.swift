import Foundation

// Wire models for the PRO migration wizard's read surface — the native
// counterpart of the web migrate flow's two RSC-only "bookend" screens: the
// entry/landing progress cards and the review/go-live summary. Those web pages
// (app/pro/migrate/page.tsx + review/page.tsx) query Prisma directly via
// loadMigrationReviewSummary and have no JSON route, so there is a dedicated
// native read API. Mirrors `tovis-app/lib/dto/proMigration.ts`
// (ProMigrationSummaryDTO / ProMigrationRaiseDTO / ProMigrationSummaryResponseDTO)
// + `GET /api/v1/pro/migrate/summary`. Dark unless ENABLE_PRO_MIGRATION — the
// route 404s while the flag is off, so the screen shows a "not available yet"
// state (same build-dark pattern as ProNoShowSettings).

/// One in-flight price-grace raise (`ProMigrationRaiseDTO`): a below-minimum
/// imported price that was grandfathered, then ramped up to the platform
/// minimum. `stepMode` is the ramp's unit ("PCT" or "USD"); `from`/`to` are the
/// current and target prices; `cadenceWeeks` is how often a step applies.
public struct ProMigrationRaise: Decodable, Sendable, Identifiable {
    public let serviceName: String
    public let from: Double
    public let to: Double
    public let stepMode: String
    public let stepValue: Double
    public let cadenceWeeks: Int

    public var id: String { serviceName }

    /// Whole-dollar "from → to" money labels (matches web `formatMoney`, which
    /// rounds to whole dollars for these catalog prices).
    public var fromLabel: String { Self.money(from) }
    public var toLabel: String { Self.money(to) }

    /// The ramp-step label, e.g. "10% / 10 wks" or "$10 / 8 wks" — mirrors web
    /// buildReviewViewModel's `cadenceLabel`.
    public var cadenceLabel: String {
        let step = stepMode.uppercased() == "PCT"
            ? "\(Self.trimmed(stepValue))%"
            : "$\(Self.trimmed(stepValue))"
        return "\(step) / \(cadenceWeeks) wks"
    }

    private static func money(_ value: Double) -> String {
        "$\(Int(value.rounded()))"
    }

    /// Drops a trailing ".0" so an integer step reads "10" not "10.0".
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// The migration summary (`ProMigrationSummaryDTO`) — the real counts the pro
/// sees post-import. `clients` uses the same booking-gated visibility the pro
/// clients list applies, so the wizard and the roster never disagree.
public struct ProMigrationSummary: Decodable, Sendable {
    public let offerings: Int
    public let clients: Int
    public let importedBookings: Int
    public let importedBlocks: Int
    public let raises: [ProMigrationRaise]

    /// The entry screen's three "what you'll bring over" progress counts, derived
    /// exactly as web does (services = offerings, clients = clients, calendar =
    /// importedBookings + importedBlocks).
    public var servicesCount: Int { offerings }
    public var clientsCount: Int { clients }
    public var calendarCount: Int { importedBookings + importedBlocks }

    /// True once any stage has data — the entry cards flip from "Not started" to a
    /// count, and the review checklist ticks the corresponding row.
    public var hasAnyImport: Bool {
        offerings > 0 || clients > 0 || calendarCount > 0
    }
}

/// `GET /api/v1/pro/migrate/summary` envelope (`ProMigrationSummaryResponseDTO`).
public struct ProMigrationSummaryResponse: Decodable, Sendable {
    public let summary: ProMigrationSummary
}
