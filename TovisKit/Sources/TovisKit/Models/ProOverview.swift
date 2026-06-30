import Foundation

// Wire models for the PRO Overview / dashboard — GET /api/v1/pro/overview
// (tovis-app PR #437). Mirrors `ProOverviewPageData` from
// lib/analytics/proMonthlyAnalytics.ts: a fully-formatted monthly-analytics
// view-model (all display strings), so the native screen stays presentation-only.

/// `GET /api/v1/pro/overview` → `{ ok, activeMonth, months, revenue,
/// primaryStats, secondaryStats, topServices }` (envelope's `ok` ignored).
public struct ProOverviewResponse: Decodable, Sendable {
    public let activeMonth: ActiveMonth
    public let months: [MonthNav]
    public let revenue: Revenue
    public let primaryStats: [Metric]
    public let secondaryStats: [Metric]
    public let topServices: [TopService]

    public struct ActiveMonth: Decodable, Sendable {
        public let key: String
        public let label: String
        public let timeZone: String
    }

    public struct MonthNav: Decodable, Sendable, Identifiable {
        public let key: String
        public let label: String
        /// Web URL; native re-fetches by `key` instead.
        public let href: String
        public let active: Bool
        public var id: String { key }
    }

    public struct Revenue: Decodable, Sendable {
        public let value: String
        public let trendLabel: String
        /// "positive" · "negative" · "neutral".
        public let trendTone: String
        public let sub: String
    }

    public struct Metric: Decodable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public let sub: String
        public var id: String { label }
    }

    public struct TopService: Decodable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let bookings: Int
        public let revenueLabel: String
    }
}
