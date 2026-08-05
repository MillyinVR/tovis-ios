// Locking white balance without betting the process on it.
//
// WHY THIS EXISTS — the build 38 crash, in one paragraph.
//
// `applyWhiteBalanceGains` did the right-looking thing: it checked
// `isWhiteBalanceModeSupported(.locked)`, read `maxWhiteBalanceGain`, ran the
// gains through `DeviceParameterGuard`, and only then wrote. It still aborted.
// Not because the value was bad — #275 made that impossible — but because
// **every one of those checks describes the device at the instant it was read,
// and the write happens at a later instant.** On a virtual multi-lens device
// (`.builtInTripleCamera`, which is every phone a pro shoots on) the session
// re-negotiates its active format when a preview connection is attached, and
// the virtual device switches its active constituent lens asynchronously after
// `startRunning`. Both were happening: the crashing thread was applying stored
// gains milliseconds after start-up while the main thread sat inside
// `-[AVCaptureVideoPreviewLayer _initWithSession:makeConnection:]`. The wide
// lens's `maxWhiteBalanceGain` is not the ultra-wide's, and `.locked` support
// is per-format. `lockForConfiguration()` does not close this window: it
// excludes other *clients* from configuring the device, not the session's own
// renegotiation.
//
// So this type does two things the old call site did not:
//
//   1. **Re-reads every precondition inside the window that holds the write.**
//      The caller opens a session configuration transaction and takes the
//      device lock; support and max gain are read INSIDE that, immediately
//      before the write, not before it was taken.
//   2. **Treats the write as fallible anyway.** Even a correctly-ordered
//      re-read can lose the race in a way no API exposes, so the write goes
//      through `CaptureExceptionShield` and a raise becomes
//      `.fellBackToAuto` — logged, WB left on automatic, camera still running.
//
// The second point is the one that matters. The coach shipped for months
// without locked white balance and worked; a shoot that is occasionally less
// colour-calibrated is a worse photo, and a dead camera is no photo at all.
import Foundation

/// The device operations locking white balance needs, minus AVFoundation — so
/// the ordering and the fallback can be tested against a device that throws on
/// demand, which a real `AVCaptureDevice` cannot be made to do in a unit test.
///
/// The app conforms `AVCaptureDevice` to this; every method here maps to one
/// AVFoundation call, and the throwing ones return their outcome rather than
/// raising.
public protocol WhiteBalanceLockable: AnyObject {
    /// Read INSIDE the locked window — `.locked` support is per active format.
    var supportsLockedWhiteBalance: Bool { get }
    var supportsAutoWhiteBalance: Bool { get }
    /// Read INSIDE the locked window — differs between constituent lenses.
    var maxWhiteBalanceGain: Float { get }

    /// `lockForConfiguration()`. False when the device refused the lock.
    func lockConfiguration() -> Bool
    /// `unlockForConfiguration()`. Must run on every path, including after a
    /// caught exception.
    func unlockConfiguration()

    /// `setWhiteBalanceModeLocked(with:)`, shielded.
    func setLockedWhiteBalance(r: Float, g: Float, b: Float) -> CaptureWriteOutcome
    /// `whiteBalanceMode = .continuousAutoWhiteBalance`, shielded.
    func setContinuousAutoWhiteBalance() -> CaptureWriteOutcome
}

/// What one white-balance attempt did. Every case leaves a running camera.
public enum WhiteBalanceOutcome: Equatable, Sendable {
    /// Locked to these gains — the calibration is live.
    case locked(r: Float, g: Float, b: Float)
    /// The gains could not survive `DeviceParameterGuard`: non-finite, or no
    /// safe value exists. Stored gains in this state never become usable, so
    /// the caller drops them instead of re-poisoning every future launch.
    case unusableGains
    /// This device (or its currently-active lens) cannot lock white balance.
    /// Nothing was written; automatic white balance stands.
    case unsupported
    /// The device refused the configuration lock. Nothing was written.
    case lockUnavailable
    /// AVFoundation raised on the write and the shield caught it. White
    /// balance was returned to automatic and the session is untouched.
    /// **This is the case that used to be `SIGABRT`.**
    case fellBackToAuto(reason: String)

    /// Whether the calibration is actually in effect (drives the CALIBRATED /
    /// AUTO badge — a fallback must not claim to be calibrated).
    public var isCalibrated: Bool {
        if case .locked = self { return true }
        return false
    }

    /// AVFoundation's own message when the write raised, else nil — the only
    /// thing that says WHICH precondition it enforced, so it belongs in the log.
    public var reason: String? {
        if case let .fellBackToAuto(reason) = self { return reason }
        return nil
    }
}

public enum GuardedWhiteBalance {

    /// Lock `device`'s white balance to `r`/`g`/`b`, or degrade.
    ///
    /// The caller must already hold the session configuration transaction that
    /// keeps the active format still — this function takes and releases only
    /// the DEVICE lock, and it re-reads support and max gain inside it.
    ///
    /// Never raises, never aborts, and always leaves the device unlocked.
    public static func apply(
        r: Double, g: Double, b: Double, to device: WhiteBalanceLockable
    ) -> WhiteBalanceOutcome {
        guard device.lockConfiguration() else { return .lockUnavailable }

        // ⚠️ Everything below is read INSIDE the lock, deliberately. Reading
        // any of it before the lock is what build 38 did, and is the bug.
        //
        // No `defer` for the unlock: the write goes through an ObjC exception
        // catcher, and a Swift frame unwound by an ObjC throw runs no cleanup.
        // The unlock is spelled out on each path instead.
        guard device.supportsLockedWhiteBalance else {
            device.unlockConfiguration()
            return .unsupported
        }
        guard let safe = DeviceParameterGuard.whiteBalanceGains(
            r: r, g: g, b: b, maxGain: device.maxWhiteBalanceGain)
        else {
            device.unlockConfiguration()
            return .unusableGains
        }

        let outcome = device.setLockedWhiteBalance(r: safe.r, g: safe.g, b: safe.b)
        guard case let .threw(_, reason) = outcome else {
            device.unlockConfiguration()
            return .locked(r: safe.r, g: safe.g, b: safe.b)
        }

        // The write raised despite passing every check we can make. The lock is
        // still held and the device's white-balance mode is now unknown — put
        // it somewhere known before letting go. `setContinuousAutoWhiteBalance`
        // is itself shielded, so a second raise here is caught too and simply
        // leaves the device on whatever mode it had.
        if device.supportsAutoWhiteBalance {
            _ = device.setContinuousAutoWhiteBalance()
        }
        device.unlockConfiguration()
        return .fellBackToAuto(reason: reason)
    }
}
