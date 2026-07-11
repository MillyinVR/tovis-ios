import Foundation

/// Canonical price-grace ramp math — a Swift port of `lib/migration/priceRamp.ts`
/// plus the web UI's `buildRampSchedule` (app/pro/migrate/_utils/raiseRamp.ts).
/// Pure and whole-dollar, so the on-device raise editor previews exactly what the
/// server persists at commit.
///
/// Policy floor (contract, not a per-pro setting): a below-minimum imported price
/// is grandfathered, then ramped toward the catalog minimum by at least 10% every
/// 10 weeks. A pro may go faster (bigger step / shorter cadence) but never gentler
/// — the clamps below enforce that, mirroring the server.
public enum ServicePriceRamp {
    /// The floor step (10%) and cadence (10 weeks).
    public static let floorPct = 10
    public static let floorWeeks = 10

    /// Smallest step allowed by the floor for the given mode + current price
    /// (PCT → 10; USD → 10% of the current price, at least $1).
    public static func floorStepValue(mode: ServiceRampStepMode, currentPrice: Int) -> Int {
        switch mode {
        case .pct:
            return floorPct
        case .usd:
            return max(1, roundHalfUp(Double(currentPrice) * Double(floorPct) / 100))
        }
    }

    /// Clamp a chosen step so it's never gentler than the floor (faster is fine).
    public static func clampStepValue(mode: ServiceRampStepMode, value: Int, currentPrice: Int) -> Int {
        max(floorStepValue(mode: mode, currentPrice: currentPrice), value)
    }

    /// Clamp cadence to 1…10 weeks (fewer weeks = faster = allowed).
    public static func clampCadenceWeeks(_ weeks: Int) -> Int {
        min(floorWeeks, max(1, weeks))
    }

    /// THE canonical single step: one increase from `price` toward `target`,
    /// clamped so it always makes progress and never overshoots the minimum.
    public static func nextStepPrice(price: Int, mode: ServiceRampStepMode, value: Int, target: Int) -> Int {
        if price >= target { return target }
        var next: Int
        switch mode {
        case .pct:
            next = roundHalfUp(Double(price) * (1 + Double(value) / 100))
        case .usd:
            next = price + value
        }
        if next <= price { next = price + 1 } // guarantee progress (e.g. value 0)
        if next >= target { next = target }
        return next
    }

    /// Whether a grandfathered price is below the catalog minimum (both rounded).
    public static func needsRamp(grandfatheredPrice: Int, minPrice: Int) -> Bool {
        grandfatheredPrice < minPrice
    }

    /// One display step in the ramp schedule (`RampStep`). `index` is 1-based.
    public struct RampStep: Sendable, Equatable, Identifiable {
        public let index: Int
        public let date: Date
        public let from: Int
        public let to: Int

        public var id: Int { index }

        public init(index: Int, date: Date, from: Int, to: Int) {
            self.index = index
            self.date = date
            self.from = from
            self.to = to
        }
    }

    /// Step-by-step schedule from the grandfathered price up to the minimum, using
    /// the canonical per-step formula so the preview matches what the server
    /// applies. Empty when the price is already at/above the minimum. `calendar` is
    /// injectable for deterministic tests (day-of-month addition, like the web).
    public static func buildRampSchedule(
        grandfatheredPrice: Int,
        minPrice: Int,
        mode: ServiceRampStepMode,
        stepValue: Int,
        cadenceWeeks: Int,
        start: Date,
        calendar: Calendar = .current
    ) -> [RampStep] {
        var price = grandfatheredPrice
        if price >= minPrice { return [] }

        var steps: [RampStep] = []
        var weeks = 0
        var i = 0
        while price < minPrice && i < 120 {
            i += 1
            weeks += cadenceWeeks
            let next = nextStepPrice(price: price, mode: mode, value: stepValue, target: minPrice)
            let date = calendar.date(byAdding: .day, value: weeks * 7, to: start) ?? start
            steps.append(RampStep(index: i, date: date, from: price, to: next))
            price = next
        }
        return steps
    }

    /// JS `Math.round` for the non-negative money math here: round half away from
    /// zero (equivalently, half up for positive values).
    private static func roundHalfUp(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrAwayFromZero))
    }
}
