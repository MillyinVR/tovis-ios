import Foundation

// Wire models for the PRO Finance & Tax tab — GET /api/v1/pro/finance
// (tovis-app). Mirrors `ProFinancePageData` from lib/finance/proFinanceSummary.ts,
// which is a SUPERSET of the Overview view-model (same activeMonth/months/revenue/
// stats/topServices) plus a `finance` block. All display strings arrive
// pre-formatted, so the native screen stays presentation-only. The Overview
// nested types are reused from `ProOverviewResponse` to avoid duplicating them.

/// `GET /api/v1/pro/finance` → the Overview fields + a `finance` block
/// (envelope's `ok` ignored).
public struct ProFinanceResponse: Decodable, Sendable {
    public let activeMonth: ProOverviewResponse.ActiveMonth
    public let months: [ProOverviewResponse.MonthNav]
    public let revenue: ProOverviewResponse.Revenue
    public let primaryStats: [ProOverviewResponse.Metric]
    public let secondaryStats: [ProOverviewResponse.Metric]
    public let topServices: [ProOverviewResponse.TopService]
    public let finance: Finance

    public struct Finance: Decodable, Sendable {
        public let taxYear: Int
        public let incomeTotalCents: Int
        public let expenseTotalCents: Int
        public let netProfitCents: Int
        public let estTaxCents: Int
        public let expenseTotalLabel: String
        public let summaryCards: [SummaryCard]
        public let incomeBreakdown: [IncomeItem]
        public let quarterlyReminder: QuarterlyReminder
        public let expenses: [ExpenseItem]
        public let categories: [CategoryInfo]
        /// Current IRS standard mileage rate in cents/mile (e.g. 72.5) — lets the
        /// add-expense form preview a trip's deduction live.
        public let mileageRateCents: Double
        public let mileageRateLabel: String
        /// Captured receipts awaiting review (all-time PENDING, newest first).
        public let receiptInbox: [ReceiptInboxItem]
        /// The pro's forwarding address (<handle>@tovis.me) — premium only, else nil.
        public let receiptInboxAddress: String?
        /// False when membership enforcement is on and the pro's plan lacks
        /// tax_export. Decoded optionally so an older payload without the key
        /// still decodes; a nil value means the gate wasn't sent (treat as
        /// allowed at the call site).
        public let canExportTaxDocs: Bool?
    }

    public struct ReceiptInboxItem: Decodable, Sendable, Identifiable {
        public let id: String
        public let source: String
        public let sourceLabel: String
        public let title: String
        public let receivedAtIso: String
        public let receivedLabel: String
        public let parsedAmountCents: Int?
        public let parsedAmountLabel: String?
        public let dateHint: String?
        public let emailFrom: String?
        public let hasReceipt: Bool
        public let receiptMediaId: String?
    }

    public struct SummaryCard: Decodable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public let sub: String
        /// "positive" · "negative" · "warn" · "neutral".
        public let tone: String
        public var id: String { label }
    }

    public struct IncomeItem: Decodable, Sendable, Identifiable {
        public let label: String
        public let source: String
        public let value: String
        public let amountCents: Int
        public var id: String { label }
    }

    public struct QuarterlyReminder: Decodable, Sendable {
        public let dueDateLabel: String
        public let body: String
    }

    public struct ExpenseItem: Decodable, Sendable, Identifiable {
        public let id: String
        public let category: String
        public let categoryLabel: String
        /// "green" · "yellow" · "red".
        public let categoryRisk: String
        public let source: String
        public let amountCents: Int
        public let amountLabel: String
        /// Logged business miles for a MILEAGE expense; null otherwise.
        public let mileageMiles: Double?
        public let label: String
        public let notes: String?
        public let dateLabel: String
        public let spentAtIso: String
        public let hasReceipt: Bool
        public let receiptMediaId: String?
    }

    public struct CategoryInfo: Decodable, Sendable, Identifiable {
        public let id: String
        public let label: String
        /// "green" · "yellow" · "red".
        public let risk: String
        public let riskLabel: String
        public let tooltip: String
        public let examples: [String]
    }
}

/// Body for POST/PATCH `/pro/finance/expenses`. `amount` is a dollar string
/// (e.g. "49.99") — the server converts to cents. Sending all fields on PATCH is
/// fine (the server treats it as a full update of the edited row).
public struct ProExpenseWriteRequest: Encodable, Sendable {
    public let category: String
    /// Dollar amount for a normal expense; nil (omitted) for mileage.
    public let amount: String?
    /// Business miles for a MILEAGE expense; the server computes the deduction.
    public let miles: String?
    public let label: String
    /// "YYYY-MM-DD".
    public let date: String
    public let notes: String?

    public init(
        category: String,
        amount: String? = nil,
        miles: String? = nil,
        label: String,
        date: String,
        notes: String?
    ) {
        self.category = category
        self.amount = amount
        self.miles = miles
        self.label = label
        self.date = date
        self.notes = notes
    }
}
