import Foundation
import Testing
@testable import TovisKit

// Parity checks for the on-device raise math (`ServicePriceRamp`) against the
// canonical web `lib/migration/priceRamp.ts` + `raiseRamp.ts::buildRampSchedule`.
// The editor previews a below-minimum imported price ramping up to the catalog
// minimum; these lock the floor/clamp/step formula and the schedule the server
// re-derives at commit.

@Suite struct ServicePriceRampTests {
    private var gregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        gregorian.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func floorStepValueByMode() {
        #expect(ServicePriceRamp.floorStepValue(mode: .pct, currentPrice: 100) == 10)
        #expect(ServicePriceRamp.floorStepValue(mode: .usd, currentPrice: 100) == 10) // 10% of 100
        #expect(ServicePriceRamp.floorStepValue(mode: .usd, currentPrice: 45) == 5) // round(4.5) = 5
        #expect(ServicePriceRamp.floorStepValue(mode: .usd, currentPrice: 3) == 1) // round(0.3)=0 → min 1
    }

    @Test func clampStepValueNeverGentlerThanFloor() {
        #expect(ServicePriceRamp.clampStepValue(mode: .pct, value: 5, currentPrice: 100) == 10)
        #expect(ServicePriceRamp.clampStepValue(mode: .pct, value: 25, currentPrice: 100) == 25) // faster ok
        #expect(ServicePriceRamp.clampStepValue(mode: .usd, value: 20, currentPrice: 100) == 20)
    }

    @Test func clampCadenceWeeksBounds() {
        #expect(ServicePriceRamp.clampCadenceWeeks(12) == 10) // never slower than the floor
        #expect(ServicePriceRamp.clampCadenceWeeks(0) == 1)
        #expect(ServicePriceRamp.clampCadenceWeeks(5) == 5)
    }

    @Test func nextStepPriceStepsAndClamps() {
        #expect(ServicePriceRamp.nextStepPrice(price: 100, mode: .pct, value: 10, target: 150) == 110)
        #expect(ServicePriceRamp.nextStepPrice(price: 100, mode: .usd, value: 10, target: 150) == 110)
        // Overshoot clamps to the target.
        #expect(ServicePriceRamp.nextStepPrice(price: 145, mode: .pct, value: 10, target: 150) == 150)
        // Already at/above the target stays put.
        #expect(ServicePriceRamp.nextStepPrice(price: 150, mode: .pct, value: 10, target: 150) == 150)
        // A no-op step still makes +1 progress.
        #expect(ServicePriceRamp.nextStepPrice(price: 100, mode: .pct, value: 0, target: 150) == 101)
    }

    @Test func needsRampBelowMinimum() {
        #expect(ServicePriceRamp.needsRamp(grandfatheredPrice: 80, minPrice: 100))
        #expect(ServicePriceRamp.needsRamp(grandfatheredPrice: 100, minPrice: 100) == false)
        #expect(ServicePriceRamp.needsRamp(grandfatheredPrice: 120, minPrice: 100) == false)
    }

    @Test func buildRampScheduleMatchesCanonicalSteps() {
        let start = date(2026, 7, 10)
        let cal = gregorian
        let steps = ServicePriceRamp.buildRampSchedule(
            grandfatheredPrice: 80, minPrice: 100,
            mode: .pct, stepValue: 10, cadenceWeeks: 10,
            start: start, calendar: cal
        )
        // 80 → 88 → 97 → 100 (clamped), 10 weeks apart.
        #expect(steps.count == 3)
        #expect(steps.map(\.from) == [80, 88, 97])
        #expect(steps.map(\.to) == [88, 97, 100])
        #expect(steps.map(\.index) == [1, 2, 3])
        #expect(steps[0].date == cal.date(byAdding: .day, value: 70, to: start))
        #expect(steps[1].date == cal.date(byAdding: .day, value: 140, to: start))
        #expect(steps[2].date == cal.date(byAdding: .day, value: 210, to: start))
    }

    @Test func buildRampScheduleEmptyWhenAtOrAboveMinimum() {
        let start = date(2026, 7, 10)
        let steps = ServicePriceRamp.buildRampSchedule(
            grandfatheredPrice: 100, minPrice: 100,
            mode: .pct, stepValue: 10, cadenceWeeks: 10,
            start: start, calendar: gregorian
        )
        #expect(steps.isEmpty)
    }
}
