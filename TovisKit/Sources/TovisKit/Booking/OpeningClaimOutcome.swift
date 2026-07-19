import Foundation

/// How the claim sheet should report a failed claim.
///
/// The rule lives here, not in the view, because it is genuinely subtle and
/// `swift test` can reach it here: **the HTTP status alone cannot tell you
/// whether the opening is gone.** Both of these are 409 on the live API —
///
///   - `OPENING_NOT_AVAILABLE` → someone else consumed the opening (or the time
///     no longer matches it). The opening is gone.
///   - `PRO_NOT_READY` → the professional is not currently accepting bookings.
///     Nobody grabbed anything.
///
/// — so branching on `409` the way the web claim page does would tell a client
/// "Someone just grabbed it" about a pro who simply has an unfinished profile.
/// We branch on the **code** instead and fall back to the server's own copy,
/// which every booking error already carries in human-readable form.
///
/// Policy refusals (off-step start, outside working hours, too soon) come back
/// as **400** with their own readable copy and must never be dressed up as a
/// race — the client did nothing wrong and re-trying is pointless.
public enum OpeningClaimOutcome: Equatable, Sendable {
    /// The opening is gone. Show the "Someone just grabbed it" state.
    case taken
    /// Anything else — show `message`, which is the server's own user-facing copy
    /// whenever it sent one.
    case failed(message: String)
}

/// Booking error codes that mean "this opening (or this exact time) is no longer
/// yours to take".
///
/// `OPENING_NOT_AVAILABLE` is raised from five distinct places in the server's
/// write boundary — wrong pro, wrong service, time mismatch, already consumed,
/// and the update race — all carrying this one code with no discriminator. On the
/// claim path every one of them means the same thing to the client, because the
/// sheet never lets them pick a time: it always sends the opening's own instant,
/// so a mismatch can only mean the opening changed underneath them.
private let openingGoneCodes: Set<String> = [
    "OPENING_NOT_AVAILABLE",
    "TIME_BOOKED",
    "TIME_HELD",
    "TIME_BLOCKED",
]

public enum OpeningClaimFailure {
    /// Classify a failed hold/finalize into what the sheet should say.
    ///
    /// - Parameters:
    ///   - status: HTTP status from the failed call.
    ///   - code: the `code` field off the error body, when present.
    ///   - message: the `error` field off the error body — already user-facing
    ///     copy for every booking error.
    public static func classify(
        status: Int,
        code: String?,
        message: String?
    ) -> OpeningClaimOutcome {
        if let code = code?.trimmedOrNil?.uppercased(), openingGoneCodes.contains(code) {
            return .taken
        }

        let trimmed = message?.trimmedOrNil
        if let trimmed { return .failed(message: trimmed) }

        // No code we recognise AND no copy: a bare 409 is still most likely a
        // race on this path, so say the honest generic thing rather than
        // inventing a cause.
        return .failed(
            message: status == 409
                ? "That time is no longer available. Please try another opening."
                : "Couldn’t claim this opening. Please try again."
        )
    }

    /// Convenience over ``APIError`` for the call sites.
    public static func classify(_ error: APIError) -> OpeningClaimOutcome {
        switch error {
        case let .server(status, message, code),
             let .serverDetails(status, message, code, _):
            return classify(status: status, code: code, message: message)
        case .unauthorized, .invalidResponse, .decoding, .transport:
            return .failed(message: error.userMessage)
        }
    }
}
