import Foundation

/// Typed outcome of a failed AI-camera vision call (`look-brief` / `set-critique`).
///
/// The server sends two distinct "you can't run this right now" signals the app
/// must treat differently — both currently surface as a generic
/// "Something went wrong" without this classifier:
///
///  - **403 `CAMERA_QUOTA_EXCEEDED`** — the pro's MONTHLY image allowance is
///    spent (`lib/pro/cameraQuotaResponse.ts`, built for exactly this prompt).
///    Upgrading the membership raises the cap, so this is the only case that
///    should offer an "Upgrade" affordance. The server's message already names
///    the allowance and the upgrade path, so we render it verbatim.
///  - **429** — a per-DAY vision cap (25 look-briefs / 10 critiques,
///    `lib/rateLimit/policies.ts`). It resets on its own tomorrow, so upgrading
///    wouldn't help; we just say to try again later.
///
/// Everything else collapses to `.other`, carrying the best user-facing message.
public enum ProCameraAIError: Error, Equatable, Sendable {
    /// Monthly image allowance spent (403). `message` is the server's copy,
    /// which already points at the membership upgrade.
    case quotaExceeded(message: String)
    /// The daily per-feature vision cap was hit (429). Resets tomorrow.
    case dailyLimitReached
    /// Any other failure (offline, refusal, decode, server error).
    case other(message: String)

    /// Machine-readable code the server sets on the monthly-quota 403
    /// (`CAMERA_QUOTA_EXCEEDED_CODE` in lib/pro/cameraQuotaResponse.ts).
    public static let quotaExceededCode = "CAMERA_QUOTA_EXCEEDED"

    /// Classify any error thrown by a `ProCameraService` vision call.
    public static func from(_ error: Error) -> ProCameraAIError {
        guard let api = error as? APIError else {
            return .other(message: "Couldn’t reach the AI photographer. Please try again.")
        }

        let status: Int
        let message: String?
        let code: String?
        switch api {
        case let .server(s, m, c):
            (status, message, code) = (s, m, c)
        case let .serverDetails(s, m, c, _):
            // The extra details are claim/rate-limit hints; the daily cap below
            // keys on the status alone.
            (status, message, code) = (s, m, c)
        default:
            // .unauthorized / .transport / .decoding / .invalidResponse have no
            // status to key on — their built-in copy is already right.
            return .other(message: api.userMessage)
        }

        if status == 403, code == Self.quotaExceededCode {
            return .quotaExceeded(message: message ?? Self.defaultQuotaMessage)
        }
        if status == 429 {
            return .dailyLimitReached
        }
        return .other(message: message ?? api.userMessage)
    }

    /// A user-facing sentence for each case.
    public var userMessage: String {
        switch self {
        case let .quotaExceeded(message): return message
        case .dailyLimitReached: return "Daily AI limit reached — try again tomorrow."
        case let .other(message): return message
        }
    }

    /// Only the monthly-quota case benefits from an upgrade — the daily cap
    /// resets on its own, so we don't nudge toward membership there.
    public var offersUpgrade: Bool {
        if case .quotaExceeded = self { return true }
        return false
    }

    /// Fallback quota copy if the 403 arrives without a body message (it always
    /// carries one today; this keeps the app honest if that ever changes).
    private static let defaultQuotaMessage =
        "You’ve used all your AI photographer images for this month. Upgrade your membership for a bigger monthly allowance."
}
