// Where AVFoundation meets the exception shield.
//
// Three builds of this app were killed by an uncaught Objective-C exception out
// of an `AVCaptureDevice` write (#273, #275, and build 38 again). Each fix made
// the *validation* better; each time AVFoundation found another precondition to
// enforce that the validation had not, or had checked at the wrong instant.
//
// So the app stops relying on validation alone. Every AVFoundation call in the
// camera that can raise goes through `CaptureExceptionShield`, which crosses
// into Objective-C, catches, and returns an outcome. The write may fail. The
// process may not die.
//
// ⚠️ THE ONE RULE for every `shielded` block below: it contains exactly one
// AVFoundation call and no `defer`. An ObjC exception unwinding through a Swift
// frame runs no Swift cleanup, so a `defer { unlockForConfiguration() }` inside
// a shielded block would silently not run and wedge the device for the rest of
// the shoot. Unlocks are always spelled out AFTER the shielded call, on every
// path. See `TovisObjCException.h`.
import AVFoundation
import TovisKit

// MARK: - The white-balance seam

/// `AVCaptureDevice` as `GuardedWhiteBalance` needs it: every operation is one
/// AVFoundation call, and the throwing ones report instead of raising.
///
/// Note what is NOT here: nothing is cached. `supportsLockedWhiteBalance` and
/// `maxWhiteBalanceGain` are live reads, because on a virtual multi-lens device
/// both change when the active constituent changes — which is the build 38
/// crash. `GuardedWhiteBalance` reads them inside the configuration lock.
/// `nonisolated` throughout: this file compiles under the project's default
/// main-actor isolation, but every one of these runs on `tovis.camera.session`.
/// A main-actor-isolated conformance used from that queue is a warning today
/// and an error under the Swift 6 language mode — and, more to the point, would
/// be a lie about where the code actually executes.
nonisolated extension AVCaptureDevice: @retroactive WhiteBalanceLockable {

    public nonisolated var supportsLockedWhiteBalance: Bool {
        isWhiteBalanceModeSupported(.locked)
    }

    public nonisolated var supportsAutoWhiteBalance: Bool {
        isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
    }

    public nonisolated func lockConfiguration() -> Bool {
        (try? lockForConfiguration()) != nil
    }

    public nonisolated func unlockConfiguration() {
        unlockForConfiguration()
    }

    public nonisolated func setLockedWhiteBalance(r: Float, g: Float, b: Float) -> CaptureWriteOutcome {
        let gains = AVCaptureDevice.WhiteBalanceGains(redGain: r, greenGain: g, blueGain: b)
        // THE call site of all three crashes. One statement, nothing else.
        return CaptureExceptionShield.perform("setWhiteBalanceModeLocked") {
            self.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    public nonisolated func setContinuousAutoWhiteBalance() -> CaptureWriteOutcome {
        CaptureExceptionShield.perform("whiteBalanceMode = .continuousAutoWhiteBalance") {
            self.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }
}

// MARK: - Everything else that can raise

extension CaptureExceptionShield {

    /// Runs a group of device writes with exceptions caught.
    ///
    /// Prefer one call per write so a caught exception names the right one. Use
    /// this grouped form only where the writes are a single logical settings
    /// pass and losing the remainder of it on a throw is acceptable — a throw
    /// abandons the rest of the block.
    ///
    /// ⚠️ No `defer` inside `body`, and no lock/unlock pairs. See the file header.
    @discardableResult
    nonisolated static func settings(_ label: String, _ body: () -> Void) -> CaptureWriteOutcome {
        perform(label, body)
    }
}
