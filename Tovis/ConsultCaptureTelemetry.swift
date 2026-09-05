// What the consult capture chain says about itself, at every step.
//
// 🔴 Why this file exists: the prod audit of one real consult could not answer
// "where did that photo go?" from anything the app emitted, because the app
// emitted nothing. The chain was one `Task` that either finished or was
// cancelled, and cancellation was silent by construction — no line, no counter,
// no trace. A shot that vanished between the shutter and the server looked
// exactly like a shot that was never taken.
//
// So every stage transition and every failure on this path is now stated once,
// here, with a stable vocabulary a log search can pivot on:
//
//     ai_consult CAPTURE stage=<STAGE> outcome=<OUTCOME> shot=<key> …
//
// ⚠️ PRIVACY BOUNDARY, and it is the same one the server's
// `lib/observability/aiConsultEvents.ts` draws: hashed ids and bounded product
// facts ONLY. The consult id is truncated-hashed so two lines can be correlated
// without the id itself ever reaching a sysdiagnose; the shot key is
// server-defined vocabulary, not a client trait. No bytes, no storage path, no
// signed URL, no token, no quality reasoning, nothing the model observed.
import Foundation
import OSLog
import TovisKit

/// Where a breadcrumb goes in addition to os_log.
///
/// 🟡 There is no crash/telemetry SDK in this app today — `tovis-ios` has
/// exactly two SPM dependencies (stripe-ios, GoogleSignIn-iOS) and no Sentry.
/// Adding sentry-cocoa is a dependency, DSN and privacy-manifest decision that
/// is Tori's, not this change's. This protocol is the seam it plugs into: an
/// implementation that forwards to `SentrySDK.addBreadcrumb` is the only code
/// that would need writing, and every call site below already exists.
protocol ConsultCaptureBreadcrumbSink: Sendable {
    func record(category: String, message: String, level: ConsultCaptureLogLevel)
}

enum ConsultCaptureLogLevel: String, Sendable {
    case info
    case warning
    case error
}

/// The stages one photograph moves through. Named after what is TRUE when the
/// stage is entered, so a line reads as a fact rather than an intention.
enum ConsultCaptureStage: String, Sendable {
    /// Bytes are on disk and owed to the server.
    case queued = "QUEUED"
    /// An upload ticket has been issued (or replayed) for these bytes.
    case ticketed = "TICKETED"
    /// The background session has the transfer.
    case transferring = "TRANSFERRING"
    /// Storage has the bytes.
    case uploaded = "UPLOADED"
    /// A ConsultCapture row exists for them.
    case attached = "ATTACHED"
    /// The server has returned a quality verdict.
    case checked = "CHECKED"
    /// The server refused in a way retrying cannot fix.
    case blocked = "BLOCKED"
    /// Released from the vault.
    case released = "RELEASED"
    /// A leg failed transiently and the queue is backing off.
    case backoff = "BACKOFF"
    /// The camera view went away while a shot was in flight. Retained purely so
    /// the old silent-drop shows up as a line if it ever comes back.
    case viewDismissed = "VIEW_DISMISSED"
}

enum ConsultCaptureOutcome: String, Sendable {
    case ok = "OK"
    case accepted = "ACCEPTED"
    case rejected = "REJECTED"
    case retryLater = "RETRY_LATER"
    case refused = "REFUSED"
    case expired = "EXPIRED"
    case rotated = "ROTATED"
    case abandoned = "ABANDONED"
}

enum ConsultCaptureTelemetry {
    nonisolated(unsafe) static var sink: (any ConsultCaptureBreadcrumbSink)?

    private static let log = Logger(subsystem: "app.tovis", category: "consult-capture")

    /// One stage transition. `detail` is a bounded, non-identifying code — a
    /// server error code, an HTTP status, `"offline"` — never a message lifted
    /// from a response body.
    static func stage(
        _ stage: ConsultCaptureStage,
        outcome: ConsultCaptureOutcome,
        shotKey: ConsultCaptureShotKey,
        consultId: String,
        detail: String? = nil
    ) {
        let level: ConsultCaptureLogLevel
        switch outcome {
        case .ok, .accepted, .rejected: level = .info
        case .retryLater, .rotated: level = .warning
        case .refused, .expired, .abandoned: level = .error
        }
        let line = "stage=\(stage.rawValue) outcome=\(outcome.rawValue)"
            + " shot=\(shotKey.rawValue) consult=\(correlationId(consultId))"
            + (detail.map { " detail=\($0)" } ?? "")
        emit(line, level: level)
    }

    /// A queue-wide fact with no single shot behind it — configure, drain,
    /// a sweep. Same vocabulary, no shot key.
    static func queue(_ message: String, level: ConsultCaptureLogLevel = .info) {
        emit("queue \(message)", level: level)
    }

    private static func emit(_ line: String, level: ConsultCaptureLogLevel) {
        switch level {
        case .info: log.info("ai_consult CAPTURE \(line, privacy: .public)")
        case .warning: log.warning("ai_consult CAPTURE \(line, privacy: .public)")
        case .error: log.error("ai_consult CAPTURE \(line, privacy: .public)")
        }
        sink?.record(category: "consult.capture", message: line, level: level)
    }

    /// A consult id, reduced to something two log lines can be joined on and
    /// nothing else. Same shape as the server's `hashMetricId`, shorter.
    static func correlationId(_ consultId: String) -> String {
        String(MediaHash.sha256Hex(Data(consultId.utf8)).prefix(8))
    }
}
