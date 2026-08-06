// Red-proof for the build 38 camera crash — the SECOND layer.
//
// Build 38 shipped #275's `DeviceParameterGuard` and died at the same site:
// EXC_CRASH / SIGABRT on `tovis.camera.session`, uncaught ObjC exception out of
// `-[AVCaptureFigVideoDevice _setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:…]`.
// Symbolicated against build 38's own dSYM (slice 0AF7954C-…-11DC78E8E9AF),
// image offset 913640 is `closure #1 in CameraController.applyWhiteBalanceGains(r:g:b:)`
// — a call site that DID route through the guard. The value was not the problem.
//
// Two rounds of better validation were beaten by the same crash, so the tests
// below do not test validation. They test that the app survives a write that
// raises anyway: an exception is thrown for real, inside the real shim, and the
// assertions after it are reached — which they cannot be if the raise escapes.
//
// If the shim ever regresses, this file does not fail. It aborts the test run.
// That is the correct signal for this bug.
import Foundation
import Testing
import TovisKit

struct CaptureExceptionShieldTests {

    // MARK: - The shim itself

    @Test func aRaisedObjCExceptionIsCaughtInsteadOfKillingTheProcess() {
        let outcome = CaptureExceptionShield.perform("test") {
            NSException(
                name: .genericException,
                reason: "Gains must be within the range of 1 and -[AVCaptureDevice maxWhiteBalanceGain]",
                userInfo: nil
            ).raise()
        }

        // Reaching this line at all is the assertion that matters — under
        // build 38's code the raise above is `objc_exception_throw` →
        // `std::terminate` and there is no line after it.
        #expect(outcome.didThrow)
        #expect(outcome == .threw(
            name: NSExceptionName.genericException.rawValue,
            reason: "Gains must be within the range of 1 and -[AVCaptureDevice maxWhiteBalanceGain]"))
    }

    @Test func theExceptionsOwnReasonSurvivesSoTheNextOneCanBeDiagnosed() {
        // The crash log carried a backtrace but no reason string, which is why
        // round 3 had to infer WHICH precondition AVFoundation enforced. A
        // caught exception must not lose that again.
        let outcome = CaptureExceptionShield.perform("setWhiteBalanceModeLocked") {
            NSException(name: .internalInconsistencyException,
                        reason: "-[AVCaptureDevice setWhiteBalanceModeLocked…] not locked for configuration",
                        userInfo: nil).raise()
        }
        #expect(outcome.reason?.contains("not locked for configuration") == true)
        if case let .threw(name, _) = outcome {
            #expect(name == NSExceptionName.internalInconsistencyException.rawValue)
        } else {
            Issue.record("expected a caught exception")
        }
    }

    @Test func aWriteThatDoesNotRaisePassesStraightThrough() {
        var ran = false
        let outcome = CaptureExceptionShield.perform("noop") { ran = true }
        #expect(ran)
        #expect(outcome == .ok)
        #expect(outcome.reason == nil)
    }

    @Test func catchingIsReusableAndDoesNotLeaveTheShieldPoisoned() {
        // The session queue calls this thousands of times per shoot (face
        // metering runs per frame). One caught exception must not change the
        // behaviour of the next write.
        for i in 0..<200 {
            let outcome = CaptureExceptionShield.perform("loop") {
                if i.isMultiple(of: 2) {
                    NSException(name: .genericException, reason: "boom \(i)", userInfo: nil).raise()
                }
            }
            #expect(outcome.didThrow == i.isMultiple(of: 2))
        }
    }

    @Test func caughtExceptionsAreReportedToTheLogSink() {
        // A crash that becomes a silent degradation is a crash you never fix.
        //
        // 🔴 `onCaughtException` is a single PROCESS-WIDE slot — every
        // AVFoundation write in the app routes through it, including this
        // suite's own `catchingIsReusableAndDoesNotLeaveTheShieldPoisoned`
        // loop and every `GuardedWhiteBalanceTests` write, and swift-testing
        // runs suites concurrently by default. While this sink is installed,
        // one of those unrelated raises can fire it on another thread at the
        // same instant this test's two calls do. A plain `[T]` getting
        // `append`ed from two threads at once isn't just a wrong count, it's
        // a data race — so `Sink` serializes its own writes with a lock — and
        // the assertions below only look at entries carrying this test's own
        // two unique labels, so a stray entry from a concurrently-running
        // test can't flip `sink.seen.count == 1` into a flake either.
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [(String, CaptureWriteOutcome)] = []
            func record(_ label: String, _ outcome: CaptureWriteOutcome) {
                lock.lock(); defer { lock.unlock() }
                entries.append((label, outcome))
            }
            func entries(labeled label: String) -> [(String, CaptureWriteOutcome)] {
                lock.lock(); defer { lock.unlock() }
                return entries.filter { $0.0 == label }
            }
        }
        let sink = Sink()
        CaptureExceptionShield.onCaughtException = { label, outcome in
            sink.record(label, outcome)
        }
        defer { CaptureExceptionShield.onCaughtException = nil }

        CaptureExceptionShield.perform("videoZoomFactor") {
            NSException(name: .genericException, reason: "zoom out of range", userInfo: nil).raise()
        }
        CaptureExceptionShield.perform("fine") {}

        let mine = sink.entries(labeled: "videoZoomFactor")
        #expect(mine.count == 1)                    // only the throw reports
        #expect(mine.first?.1.reason == "zoom out of range")
        #expect(sink.entries(labeled: "fine").isEmpty) // the non-throwing call never reports
    }
}
