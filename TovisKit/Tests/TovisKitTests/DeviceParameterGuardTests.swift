// Red-proof for the build 37 camera crash.
//
// Build 37 shipped #273's fix and still died ~5s after the camera opened:
// EXC_CRASH / SIGABRT on `tovis.camera.session`, an uncaught ObjC exception out
// of `-[AVCaptureFigVideoDevice _setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:...]`.
// Symbolicated against build 37's dSYM, the app frame is
// `CameraController.swift:352` — the return address after
// `setWhiteBalanceModeLocked` inside `applyWhiteBalanceGains`.
//
// The call site was already clamping. The clamp was the bug.
import Testing
import TovisKit

struct DeviceParameterGuardTests {

    // MARK: - The exact regression

    @Test func build37sHandRolledClampLetNaNStraightThrough() {
        // Build 37, verbatim. Swift's `min`/`max` are `Comparable` — `1 >= NaN`
        // and `maxGain < NaN` are both false — so the NaN falls back out
        // unchanged while every other bad value clamps correctly. That is how a
        // NaN persisted in UserDefaults reached AVFoundation and aborted the app.
        let maxGain: Float = 4
        func build37Clamp(_ x: Double) -> Float { min(max(Float(x), 1), maxGain) }

        #expect(build37Clamp(.nan).isNaN)      // the hole, pinned
        #expect(build37Clamp(.infinity) == 4)  // …everything else was fine,
        #expect(build37Clamp(-.infinity) == 1) //    which is why it survived
        #expect(build37Clamp(99) == 4)         //    review three times.

        // The shared guard refuses the write instead of forwarding the NaN.
        #expect(DeviceParameterGuard.whiteBalanceGains(r: .nan, g: 2, b: 2, maxGain: maxGain) == nil)
    }

    // MARK: - clamped

    @Test func nonFiniteValuesSaturateOrAreRefused() {
        #expect(DeviceParameterGuard.clamped(Double.nan, lower: 1, upper: 4) == nil)
        #expect(DeviceParameterGuard.clamped(Double.infinity, lower: 1, upper: 4) == 4)
        #expect(DeviceParameterGuard.clamped(-Double.infinity, lower: 1, upper: 4) == 1)
    }

    @Test func inRangeValuesPassThroughUntouched() {
        #expect(DeviceParameterGuard.clamped(2.5, lower: 1, upper: 4) == 2.5)
        #expect(DeviceParameterGuard.clamped(1.0, lower: 1, upper: 4) == 1.0)
        #expect(DeviceParameterGuard.clamped(4.0, lower: 1, upper: 4) == 4.0)
    }

    @Test func aDeviceReportingAnUntrustworthyRangeGetsNoWrite() {
        // Bounds come off the device too, and a format can answer nonsense.
        #expect(DeviceParameterGuard.clamped(2.0, lower: 1, upper: .nan) == nil)
        #expect(DeviceParameterGuard.clamped(2.0, lower: .nan, upper: 4) == nil)
        #expect(DeviceParameterGuard.clamped(2.0, lower: 1, upper: .infinity) == nil)
        #expect(DeviceParameterGuard.clamped(2.0, lower: 4, upper: 1) == nil)   // inverted
    }

    // MARK: - White-balance gains

    @Test func everyChannelIsCheckedNotJustTheFirst() {
        #expect(DeviceParameterGuard.whiteBalanceGains(r: 2, g: .nan, b: 2, maxGain: 4) == nil)
        #expect(DeviceParameterGuard.whiteBalanceGains(r: 2, g: 2, b: .nan, maxGain: 4) == nil)
    }

    @Test func outOfRangeGainsClampIntoTheDevicesWindow() throws {
        let low = try #require(DeviceParameterGuard.whiteBalanceGains(r: 0.2, g: -5, b: 0, maxGain: 4))
        #expect(low.r == 1 && low.g == 1 && low.b == 1)

        let high = try #require(DeviceParameterGuard.whiteBalanceGains(r: 9, g: 1e300, b: 4.5, maxGain: 4))
        #expect(high.r == 4 && high.g == 4 && high.b == 4)
    }

    @Test func goodGainsSurvive() throws {
        let g = try #require(DeviceParameterGuard.whiteBalanceGains(r: 1.8, g: 1.0, b: 2.4, maxGain: 4))
        #expect(abs(g.r - 1.8) < 1e-6)
        #expect(abs(g.g - 1.0) < 1e-6)
        #expect(abs(g.b - 2.4) < 1e-6)
    }

    @Test func aDeviceWhoseMaxGainIsBelowTheFloorGetsNoWrite() {
        #expect(DeviceParameterGuard.whiteBalanceGains(r: 1, g: 1, b: 1, maxGain: 0.5) == nil)
        #expect(DeviceParameterGuard.whiteBalanceGains(r: 1, g: 1, b: 1, maxGain: .nan) == nil)
    }

    // MARK: - Points of interest

    @Test func aNaNTapIsRefusedAndAnOffscreenOneIsClamped() {
        #expect(DeviceParameterGuard.unitPoint(x: .nan, y: 0.5) == nil)
        #expect(DeviceParameterGuard.unitPoint(x: 0.5, y: .nan) == nil)

        let p = DeviceParameterGuard.unitPoint(x: -3, y: 42)
        #expect(p?.x == 0)
        #expect(p?.y == 1)
    }
}
