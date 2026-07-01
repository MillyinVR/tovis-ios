import Foundation

// Native port of web `lib/booking/overridePrompts.ts`: the mapping from an
// override-gated booking error `code` to the `allow*` flag that authorizes a
// retry, plus the confirm-dialog copy. A pro placing a booking outside their
// advance-notice window / booking window / working hours gets a rejection with
// one of these codes; the UI offers "book it anyway?" and re-submits with the
// matching flag instead of dead-ending. Shared across the create / accept /
// edit (reschedule) flows — only the copy differs by intent.

/// The `allow*` flag on `POST /pro/bookings` (and the booking PATCH routes)
/// that force-creates past a scheduling guard.
public enum BookingOverrideFlag: String, Sendable, Hashable {
    case allowShortNotice
    case allowFarFuture
    case allowOutsideWorkingHours
}

/// Which action tripped the override-gated rule; only the dialog copy differs.
public enum BookingOverridePromptIntent: Sendable {
    case accept  // approving a pending request
    case edit    // rescheduling/resizing an existing booking
    case create  // placing a brand-new booking
}

/// The confirm prompt to show for an override-gated failure: the flag a retry
/// must set, the question to ask the pro, and the placeholder for the optional
/// reason captured for the audit log.
public struct BookingOverridePrompt: Sendable, Equatable {
    public let code: String
    public let flag: BookingOverrideFlag
    public let question: String
    public let reasonPlaceholder: String
}

/// Maps an override-gated error `code` (from `APIError.server(code:)`) to its
/// prompt, or nil when the failure isn't one the pro can override. Mirrors the
/// `BOOKING_OVERRIDE_PROMPTS` table in web `overridePrompts.ts`.
public func bookingOverridePrompt(
    forErrorCode code: String?,
    intent: BookingOverridePromptIntent
) -> BookingOverridePrompt? {
    guard let code else { return nil }
    switch code {
    case "ADVANCE_NOTICE_REQUIRED":
        let question: String
        switch intent {
        case .accept: question = "This booking is inside your advance-notice window. Accept anyway?"
        case .edit: question = "This new time is inside your advance-notice window. Save it anyway?"
        case .create: question = "This time is inside your advance-notice window. Book it anyway?"
        }
        return BookingOverridePrompt(
            code: code,
            flag: .allowShortNotice,
            question: question,
            reasonPlaceholder: intent == .accept
                ? "Explain why this booking can be accepted on short notice."
                : intent == .edit
                    ? "Explain why this change can happen on short notice."
                    : "Explain why this booking can happen on short notice."
        )
    case "MAX_DAYS_AHEAD_EXCEEDED":
        let question: String
        switch intent {
        case .accept: question = "This booking is further out than your booking window allows. Accept anyway?"
        case .edit: question = "This new time is further out than your booking window allows. Save it anyway?"
        case .create: question = "This time is further out than your booking window allows. Book it anyway?"
        }
        return BookingOverridePrompt(
            code: code,
            flag: .allowFarFuture,
            question: question,
            reasonPlaceholder: intent == .accept
                ? "Explain why this booking can be accepted this far in advance."
                : "Explain why this booking can be scheduled this far in advance."
        )
    case "OUTSIDE_WORKING_HOURS":
        let question: String
        switch intent {
        case .accept: question = "This booking is outside your working hours. Accept anyway?"
        case .edit: question = "This new time is outside your working hours. Save it anyway?"
        case .create: question = "This time is outside your working hours. Book it anyway?"
        }
        return BookingOverridePrompt(
            code: code,
            flag: .allowOutsideWorkingHours,
            question: question,
            reasonPlaceholder: "Explain why this booking can happen outside working hours."
        )
    default:
        return nil
    }
}

public extension APIError {
    /// Pulls the override prompt straight from a failed request, if the failure
    /// was an override-gated scheduling rejection.
    func bookingOverridePrompt(
        intent: BookingOverridePromptIntent
    ) -> BookingOverridePrompt? {
        guard case let .server(_, _, code) = self else { return nil }
        return TovisKit.bookingOverridePrompt(forErrorCode: code, intent: intent)
    }
}
