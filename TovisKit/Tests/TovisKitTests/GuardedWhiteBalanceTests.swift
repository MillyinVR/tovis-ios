// Red-proof for the build 38 camera crash — the ROOT CAUSE, and the fallback.
//
// The diagnosis (see GuardedWhiteBalance.swift): the preconditions were checked
// against the device at one instant and the write happened at another. On the
// crashing phone the two instants straddled a virtual-device constituent switch
// AND a preview-layer attach that re-negotiated the active format, so the wide
// lens's `maxWhiteBalanceGain` was validated against and the ultra-wide's was
// enforced. `lockForConfiguration()` does not close that window.
//
// `FakeWBDevice` is a device that can be made to change under the caller
// exactly that way, which no real `AVCaptureDevice` can be made to do on cue.
import Foundation
import Testing
import TovisKit

/// A `WhiteBalanceLockable` that records the order it was used in, and can
/// switch its own limits the moment the caller commits to a write.
private final class FakeWBDevice: WhiteBalanceLockable {
    var supportsLockedWhiteBalance = true
    var supportsAutoWhiteBalance = true

    /// The value handed out by the NEXT read. A constituent switch swaps it.
    var maxWhiteBalanceGain: Float = 4.0
    /// What the device will actually enforce at write time — the ACTIVE lens's
    /// limit, which is the one AVFoundation validates against.
    var enforcedMaxGain: Float = 4.0

    var lockGranted = true
    private(set) var isLocked = false
    private(set) var lockCount = 0
    private(set) var unlockCount = 0
    private(set) var trace: [String] = []

    /// Set to run just before `setLockedWhiteBalance` — the seam that models
    /// "the session re-negotiated while we held the lock".
    var beforeWrite: (() -> Void)?

    /// Nil until a lock is written; `.continuousAuto` after a fallback.
    private(set) var mode: Mode = .continuousAuto
    enum Mode: Equatable { case continuousAuto, locked(r: Float, g: Float, b: Float) }

    func lockConfiguration() -> Bool {
        trace.append("lock")
        guard lockGranted else { return false }
        lockCount += 1
        isLocked = true
        return true
    }

    func unlockConfiguration() {
        trace.append("unlock")
        unlockCount += 1
        isLocked = false
    }

    func setLockedWhiteBalance(r: Float, g: Float, b: Float) -> CaptureWriteOutcome {
        trace.append("setLocked")
        beforeWrite?()
        // Exactly what AVFoundation does, through the real shim: a raise, not a
        // Swift error. If the shield ever stops catching, this aborts the run.
        return CaptureExceptionShield.perform("setWhiteBalanceModeLocked") {
            guard self.isLocked else {
                NSException(name: .genericException,
                            reason: "-[AVCaptureDevice setWhiteBalanceModeLocked…] called without lockForConfiguration",
                            userInfo: nil).raise()
                return
            }
            guard r >= 1, g >= 1, b >= 1,
                  r <= self.enforcedMaxGain, g <= self.enforcedMaxGain, b <= self.enforcedMaxGain else {
                NSException(name: .genericException,
                            reason: "Gains must be within the range of 1 and -[AVCaptureDevice maxWhiteBalanceGain]",
                            userInfo: nil).raise()
                return
            }
            self.mode = .locked(r: r, g: g, b: b)
        }
    }

    func setContinuousAutoWhiteBalance() -> CaptureWriteOutcome {
        trace.append("setAuto")
        return CaptureExceptionShield.perform("continuousAutoWhiteBalance") {
            self.mode = .continuousAuto
        }
    }
}

struct GuardedWhiteBalanceTests {

    // MARK: - The build 38 crash, reproduced and survived

    @Test func aConstituentSwitchMidWriteFallsBackToAutoInsteadOfAborting() {
        // The crash, staged: gains are valid for the lens that was active when
        // the calibration was stored (max 4.0), the device switches to a lens
        // that only allows 2.0 while we hold the lock, and the write is
        // rejected by AVFoundation — the exact shape of the build 38 abort.
        let device = FakeWBDevice()
        device.maxWhiteBalanceGain = 4.0
        device.enforcedMaxGain = 4.0
        device.beforeWrite = { device.enforcedMaxGain = 2.0 }   // the switch

        let outcome = GuardedWhiteBalance.apply(r: 3.5, g: 1.0, b: 3.0, to: device)

        // Build 38 does not reach this line: the process is gone.
        guard case let .fellBackToAuto(reason) = outcome else {
            Issue.record("expected a caught throw, got \(outcome)")
            return
        }
        #expect(reason.contains("Gains must be within the range"))
        #expect(device.mode == .continuousAuto)   // camera keeps running, on auto
        #expect(!outcome.isCalibrated)            // and does NOT claim CALIBRATED
    }

    @Test func theDeviceIsUnlockedEvenWhenTheWriteRaises() {
        // The unlock cannot be a `defer`: an ObjC unwind through a Swift frame
        // runs no cleanup. A leaked device lock would wedge every later write
        // — focus, exposure, zoom — for the rest of the shoot.
        let device = FakeWBDevice()
        device.beforeWrite = { device.enforcedMaxGain = 1.0 }

        let outcome = GuardedWhiteBalance.apply(r: 3.0, g: 3.0, b: 3.0, to: device)

        #expect(outcome == .fellBackToAuto(
            reason: "Gains must be within the range of 1 and -[AVCaptureDevice maxWhiteBalanceGain]"))
        #expect(!device.isLocked)
        #expect(device.lockCount == device.unlockCount)
    }

    @Test func theFallbackHappensWhileTheLockIsStillHeld() {
        // Returning to automatic is itself a device write and needs the lock —
        // doing it after the unlock would raise a SECOND exception.
        let device = FakeWBDevice()
        device.beforeWrite = { device.enforcedMaxGain = 1.0 }

        _ = GuardedWhiteBalance.apply(r: 3.0, g: 3.0, b: 3.0, to: device)

        #expect(device.trace == ["lock", "setLocked", "setAuto", "unlock"])
    }

    // MARK: - The ordering that build 38 got wrong

    @Test func supportAndMaxGainAreReadInsideTheLockNotBeforeIt() {
        // Build 38 read `isWhiteBalanceModeSupported(.locked)` in the same
        // expression that took the lock, and `maxWhiteBalanceGain` as an
        // argument evaluated before it. Both must now be read after the lock is
        // held, so a device that only settles its limits on lock is described
        // correctly.
        let device = FakeWBDevice()
        device.maxWhiteBalanceGain = 99   // pre-lock value, deliberately absurd
        var maxReadWhileLocked: Bool?

        // Model "limits only become true after lock": the fake reports 2.0 once
        // locked, and the write enforces 2.0. If the implementation read the
        // max before locking it would pass 4.0 through and be rejected.
        device.beforeWrite = { maxReadWhileLocked = device.isLocked }
        device.maxWhiteBalanceGain = 2.0
        device.enforcedMaxGain = 2.0

        let outcome = GuardedWhiteBalance.apply(r: 4.0, g: 1.0, b: 4.0, to: device)

        #expect(maxReadWhileLocked == true)
        // 4.0 is clamped to the max read INSIDE the lock, so the write is legal.
        #expect(outcome == .locked(r: 2.0, g: 1.0, b: 2.0))
        #expect(device.mode == .locked(r: 2.0, g: 1.0, b: 2.0))
    }

    @Test func aLensThatCannotLockWhiteBalanceIsLeftAloneNotWrittenTo() {
        // `.locked` support is per active format. Writing anyway raises.
        let device = FakeWBDevice()
        device.supportsLockedWhiteBalance = false

        let outcome = GuardedWhiteBalance.apply(r: 2.0, g: 1.0, b: 2.0, to: device)

        #expect(outcome == .unsupported)
        #expect(device.trace == ["lock", "unlock"])   // no write attempted
        #expect(!device.isLocked)
    }

    @Test func aRefusedConfigurationLockWritesNothing() {
        let device = FakeWBDevice()
        device.lockGranted = false

        let outcome = GuardedWhiteBalance.apply(r: 2.0, g: 1.0, b: 2.0, to: device)

        #expect(outcome == .lockUnavailable)
        #expect(device.trace == ["lock"])
        #expect(device.unlockCount == 0)   // never locked, must not unlock
    }

    // MARK: - #275's layer still holds

    @Test func poisonedStoredGainsAreStillRefusedAndStillReported() {
        // The NaN path from #275 must keep answering `unusableGains` so the
        // view drops the stored calibration instead of retrying it forever.
        let device = FakeWBDevice()

        let outcome = GuardedWhiteBalance.apply(r: .nan, g: 1.0, b: 2.0, to: device)

        #expect(outcome == .unusableGains)
        #expect(device.trace == ["lock", "unlock"])
        #expect(device.mode == .continuousAuto)
    }

    @Test func gainsOutsideTheDevicesRangeAreClampedNotRefused() {
        let device = FakeWBDevice()
        device.maxWhiteBalanceGain = 3.0
        device.enforcedMaxGain = 3.0

        let outcome = GuardedWhiteBalance.apply(r: 9.0, g: 0.1, b: 2.0, to: device)

        #expect(outcome == .locked(r: 3.0, g: 1.0, b: 2.0))
        #expect(device.mode == .locked(r: 3.0, g: 1.0, b: 2.0))
    }

    @Test func aSecondRaiseInTheFallbackItselfIsAlsoSurvived() {
        // Belt and braces: if returning to automatic ALSO raises, the app must
        // still come back with a running camera rather than aborting.
        let device = FakeWBDevice()
        device.supportsAutoWhiteBalance = false   // fallback skipped entirely
        device.beforeWrite = { device.enforcedMaxGain = 1.0 }

        let outcome = GuardedWhiteBalance.apply(r: 3.0, g: 3.0, b: 3.0, to: device)

        #expect(outcome.reason?.contains("Gains must be within the range") == true)
        #expect(!device.isLocked)
        #expect(device.trace == ["lock", "setLocked", "unlock"])
    }
}
