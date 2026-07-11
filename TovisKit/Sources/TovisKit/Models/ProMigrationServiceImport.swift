import Foundation

// Wire models for the pro migration wizard's **services import** step (increment 3)
// — the native counterpart of the web `/pro/migrate/services` flow
// (app/pro/migrate/services/MigrateServicesClient.tsx): pick a CSV → parse it
// on-device into {name, price, durationMinutes} rows → match against the
// license-gated catalog (POST /preview) → review/map + tune below-minimum raises →
// commit (POST /commit). Both surfaces POST to existing routes with no DTO/zod on
// the web side (the contract lives as plain types in
// `tovis-app/lib/migration/serviceImportServer.ts`), so these Swift shapes
// hand-mirror those types:
//   • POST /api/v1/pro/migrate/services/preview  { rows } → { catalog, rows }
//   • POST /api/v1/pro/migrate/services/commit   { decisions } → { rows, summary }
// Both 404 while ENABLE_PRO_MIGRATION is off (same build-dark gate as the other
// steps). Commit is silent (import-mode writes never message a client), idempotent
// on the [professionalId, serviceId] unique. Money is whole-dollar numbers (not
// cents) — the server echoes/persists what the client sends.

// MARK: - Ramp config

/// How the price-grace ramp steps up toward the catalog minimum — a percentage of
/// the current price or a flat dollar amount. Mirrors the web `RaiseStepMode`.
/// Encodes to its raw `"PCT"` / `"USD"` string (what the commit route reads).
public enum ServiceRampStepMode: String, Encodable, Sendable, Equatable {
    case pct = "PCT"
    case usd = "USD"
}

/// The per-decision ramp config sent to commit (the web `ramp` object). Values are
/// integers by construction — the raise editor clamps + rounds them, and the
/// canonical policy floor is 10% every 10 weeks (`ServicePriceRamp`). The server
/// re-clamps at commit, so a gentler value can never slip through.
public struct ServiceRampConfig: Encodable, Sendable, Equatable {
    public let stepMode: ServiceRampStepMode
    public let stepValue: Int
    public let cadenceWeeks: Int

    public init(stepMode: ServiceRampStepMode, stepValue: Int, cadenceWeeks: Int) {
        self.stepMode = stepMode
        self.stepValue = stepValue
        self.cadenceWeeks = cadenceWeeks
    }

    /// The web `DEFAULT_RAMP` — 10% every 10 weeks (the policy floor).
    public static let `default` = ServiceRampConfig(stepMode: .pct, stepValue: 10, cadenceWeeks: 10)
}

// MARK: - Request bodies

/// One CSV menu row after on-device parsing, POSTed to /preview (`ServiceMenuInputRow`).
/// `price` / `durationMinutes` are `encodeIfPresent` (nil → omitted); the server
/// coerces missing to null just like the web sends explicit null, so the two are
/// equivalent on the wire.
public struct ServiceMenuInputRow: Encodable, Sendable, Equatable {
    public let name: String
    public let price: Double?
    public let durationMinutes: Double?

    public init(name: String, price: Double?, durationMinutes: Double?) {
        self.name = name
        self.price = price
        self.durationMinutes = durationMinutes
    }
}

struct ServiceImportPreviewRequestBody: Encodable {
    let rows: [ServiceMenuInputRow]
}

/// One committed row's mapping decision (`ServiceImportDecision`). The web wizard
/// only ever imports salon offerings (`offersMobile` hardcoded false), but the
/// shape carries mobile fields for parity with the route. Optional price/duration
/// fields are `encodeIfPresent` (nil → omitted; server coerces to null).
public struct ServiceImportDecision: Encodable, Sendable, Equatable {
    public let serviceId: String
    public let offersInSalon: Bool
    public let offersMobile: Bool
    public let salonPrice: Double?
    public let salonDurationMinutes: Double?
    public let mobilePrice: Double?
    public let mobileDurationMinutes: Double?
    public let ramp: ServiceRampConfig

    public init(
        serviceId: String,
        offersInSalon: Bool,
        offersMobile: Bool,
        salonPrice: Double?,
        salonDurationMinutes: Double?,
        mobilePrice: Double?,
        mobileDurationMinutes: Double?,
        ramp: ServiceRampConfig
    ) {
        self.serviceId = serviceId
        self.offersInSalon = offersInSalon
        self.offersMobile = offersMobile
        self.salonPrice = salonPrice
        self.salonDurationMinutes = salonDurationMinutes
        self.mobilePrice = mobilePrice
        self.mobileDurationMinutes = mobileDurationMinutes
        self.ramp = ramp
    }
}

struct ServiceImportCommitRequestBody: Encodable {
    let decisions: [ServiceImportDecision]
}

// MARK: - Preview response

/// One catalog service the pro is licensed for (`CatalogOption`). `minPrice` is the
/// platform floor in whole dollars (0 when the DB value is null). The catalog is
/// already license-filtered server-side, so every option is selectable.
public struct ServiceCatalogOption: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let categoryName: String?
    public let minPrice: Double
    public let defaultDurationMinutes: Double
    public let allowMobile: Bool
}

/// One fuzzy-match suggestion for a CSV row (`ServiceSuggestionDto`). `score` is
/// 0–100; the server marks the top one as `bestServiceId` only when it's confident
/// (score ≥ 70).
public struct ServiceSuggestion: Decodable, Sendable, Identifiable, Equatable {
    public let serviceId: String
    public let name: String
    public let categoryName: String?
    public let score: Double

    public var id: String { serviceId }
}

/// One evaluated CSV row (`ServicePreviewRow`). `index` is the row's zero-based
/// position in the submitted `rows` array. `bestServiceId` is the confident match
/// (or nil → the pro must pick from `suggestions`/the catalog).
public struct ServicePreviewRow: Decodable, Sendable, Identifiable, Equatable {
    public let index: Int
    public let sourceName: String
    public let sourcePrice: Double?
    public let sourceDurationMinutes: Double?
    public let suggestions: [ServiceSuggestion]
    public let bestServiceId: String?

    public var id: Int { index }
}

/// `POST /pro/migrate/services/preview` envelope (the `ok:true` field is ignored by
/// `Decodable`). The server runs the matcher, so iOS consumes matches rather than
/// re-implementing them.
public struct ServiceImportPreviewResponse: Decodable, Sendable {
    public let catalog: [ServiceCatalogOption]
    public let rows: [ServicePreviewRow]
}

// MARK: - Commit response

/// One committed decision's outcome (`ServiceCommitRowResult`) — a discriminated
/// union on `ok` on the wire, flattened here with optional success/failure fields.
/// Success: `offeringId` + `ramps` (0/1/2 price ramps created). Failure `code` ∈
/// { NOT_ALLOWED, NO_MODE, ALREADY_ADDED } (all counted as skipped).
public struct ServiceCommitRow: Decodable, Sendable, Identifiable, Equatable {
    public let serviceId: String
    public let ok: Bool
    public let offeringId: String?
    public let ramps: Int?
    public let code: String?
    public let error: String?

    public var id: String { serviceId }
}

/// Commit tally (`ServiceImportCommitResult.summary`): decisions tried
/// (`attempted`) split into `created` / `skipped`, plus `rampsCreated` (the total
/// below-minimum raises unlocked).
public struct ServiceImportCommitSummary: Decodable, Sendable, Equatable {
    public let attempted: Int
    public let created: Int
    public let skipped: Int
    public let rampsCreated: Int
}

/// `POST /pro/migrate/services/commit` envelope.
public struct ServiceImportCommitResponse: Decodable, Sendable {
    public let rows: [ServiceCommitRow]
    public let summary: ServiceImportCommitSummary
}

// MARK: - CSV parsing (on-device, web parity)

/// Extract the first number from a price/duration cell — a 1:1 port of the web
/// `parseNum` (MigrateServicesClient.tsx): strip commas, then match the first
/// `\d+(\.\d+)?` run (so `"$45.00"` → 45, `"1,250"` → 1250, `"90 min"` → 90).
/// Returns nil when there's no digit.
public func parseMenuNumber(_ value: String?) -> Double? {
    guard let value else { return nil }
    let cleaned = value.replacingOccurrences(of: ",", with: "")
    guard let range = cleaned.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
    return Double(cleaned[range])
}

/// Turn a parsed CSV table into the typed `{ name, price, durationMinutes }` rows
/// the /preview route accepts — a 1:1 port of the web `handleFile` column
/// heuristic. Columns are detected by case-insensitive header substring (name:
/// service/name/item, falling back to the first column; price: price/cost/rate/
/// amount; duration: duration/time/min/length). Rows with a blank name drop out.
public func parseServiceMenuRows(headers: [String], rows: [[String: String]]) -> [ServiceMenuInputRow] {
    func find(_ substrings: [String]) -> String? {
        headers.first { header in
            let lower = header.lowercased()
            return substrings.contains { lower.contains($0) }
        }
    }
    let nameCol = find(["service", "name", "item"]) ?? headers.first
    let priceCol = find(["price", "cost", "rate", "amount"])
    let durationCol = find(["duration", "time", "min", "length"])

    return rows.compactMap { row -> ServiceMenuInputRow? in
        let name = (nameCol.flatMap { row[$0] } ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return ServiceMenuInputRow(
            name: name,
            price: priceCol.flatMap { parseMenuNumber(row[$0]) },
            durationMinutes: durationCol.flatMap { parseMenuNumber(row[$0]) }
        )
    }
}
