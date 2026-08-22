@testable import Tovis
import AVFoundation
import Testing

// The recording delegate's outcome classification — the pure half of the
// max-duration fix.
//
// 🔴 The bug it pins: `didFinishRecordingTo` treated ANY error as failure
// (`let failed = error != nil`). But when a clip reaches `maxRecordedDuration`
// (the controller's 60s cap), AVFoundation delivers the callback WITH an error
// AND a complete, playable file on disk. Apple's own contract (AVCam sample)
// is to consult `AVErrorRecordingSuccessfullyFinishedKey` before treating the
// error as fatal. The old line threw away exactly 60 seconds of finished take,
// showed "Couldn't finish that recording", and never vaulted the file.
@Suite struct RecordingOutcomeTests {

    private func avError(_ code: AVError.Code, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: AVError.errorDomain, code: code.rawValue, userInfo: userInfo)
    }

    @Test func nilErrorMeansSuccess() {
        #expect(CameraController.recordingSucceeded(despite: nil))
    }

    @Test func theMaxDurationCapIsSuccess() {
        // What the device actually delivers when `maxRecordedDuration` fires.
        let err = avError(.maximumDurationReached, userInfo: [
            AVErrorRecordingSuccessfullyFinishedKey: true,
        ])
        #expect(CameraController.recordingSucceeded(despite: err))
    }

    /// Some OS versions have delivered the cap WITHOUT the successfully-finished
    /// flag; the code check is the backstop. A completed file must survive both.
    @Test func maximumDurationCodeAloneIsStillSuccess() {
        let err = avError(.maximumDurationReached)
        #expect(CameraController.recordingSucceeded(despite: err))
    }

    /// The cap is OUR OWN limit (`maxClipSeconds = 60`): reaching it means the
    /// file was closed at a boundary we set, so it is a kept take by
    /// construction. The system's successfully-finished flag has been observed
    /// both ways alongside `maximumDurationReached` depending on OS version, so
    /// the flag does NOT get the final say there — the code does.
    @Test func theDurationCapIsSuccessWhateverTheFlagSays() {
        let flaggedFalse = avError(.maximumDurationReached, userInfo: [
            AVErrorRecordingSuccessfullyFinishedKey: false,
        ])
        #expect(CameraController.recordingSucceeded(despite: flaggedFalse))
    }

    /// An explicit system verdict still wins for OTHER errors: a "finished OK"
    /// flag attached to an unexpected error code is trusted.
    @Test func anExplicitSuccessFlagWinsOverOtherErrorCodes() {
        let err = avError(.mediaServicesWereReset, userInfo: [
            AVErrorRecordingSuccessfullyFinishedKey: true,
        ])
        #expect(CameraController.recordingSucceeded(despite: err))
    }

    @Test func anyOtherErrorIsFailure() {
        #expect(!CameraController.recordingSucceeded(despite: avError(.mediaServicesWereReset)))
        #expect(!CameraController.recordingSucceeded(despite:
            NSError(domain: NSURLErrorDomain, code: -1)))
        #expect(!CameraController.recordingSucceeded(despite: CameraError.noData))
    }
}

// The still-size ceiling and wide-angle parking already had suites; these pin
// the NEW pure surface the recording fix added. (The delegate itself, the
// watchdog timing and the torch write are device-path code — covered by the
// §1 live-verification pass, not unit-testable without hardware.)
