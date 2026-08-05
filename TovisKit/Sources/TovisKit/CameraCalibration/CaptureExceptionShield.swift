// The Swift face of `TovisObjCException` — every AVFoundation write in the app
// goes through here, and none of them can kill the process any more.
//
// `DeviceParameterGuard` (#275) validates the VALUE. This validates nothing: it
// accepts that a device write can raise for reasons the caller could not have
// checked — a bound that changed between the check and the write, a mode the
// active lens stopped supporting, a constraint a future iOS adds — and makes
// the raise a returned outcome instead of an `abort()`.
//
// The two are complements, not alternatives. The guard means the app rarely
// writes something invalid; the shield means it survives when it does anyway.
import Foundation
import TovisObjC

/// What happened to one attempted device write.
public enum CaptureWriteOutcome: Equatable, Sendable {
    case ok
    /// AVFoundation raised. `reason` is its own message — the constraint it
    /// actually enforced, which is the only thing that identifies which
    /// precondition was violated.
    case threw(name: String, reason: String)

    public var didThrow: Bool {
        if case .threw = self { return true }
        return false
    }

    /// The exception's message, or nil if the write succeeded.
    public var reason: String? {
        if case let .threw(_, reason) = self { return reason }
        return nil
    }
}

public enum CaptureExceptionShield {

    /// Sink for caught exceptions. A caught throw is a bug worth seeing even
    /// though it is no longer fatal — set this once at camera start-up so the
    /// next one shows up in the log with its AVFoundation reason attached,
    /// instead of silently degrading colour and never being diagnosed.
    nonisolated(unsafe) public static var onCaughtException: (@Sendable (String, CaptureWriteOutcome) -> Void)?

    /// Runs `body` with Objective-C exceptions caught.
    ///
    /// ⚠️ `body` must be a SINGLE AVFoundation call and must not use `defer`
    /// — the unwind passes through this Swift frame and Swift runs no cleanup
    /// on that path. Locks are released by the caller AFTER this returns, on
    /// both paths. See the header of `TovisObjCException.h`.
    ///
    /// `label` names the write for the log ("setWhiteBalanceModeLocked"), so a
    /// caught exception says which one it was.
    @discardableResult
    public static func perform(_ label: String, _ body: () -> Void) -> CaptureWriteOutcome {
        do {
            try TovisObjCException.catching(body)
            return .ok
        } catch let error as NSError {
            let outcome = CaptureWriteOutcome.threw(
                name: error.userInfo[TovisObjCExceptionNameKey] as? String ?? "NSException",
                reason: error.localizedDescription)
            onCaughtException?(label, outcome)
            return outcome
        }
    }
}
