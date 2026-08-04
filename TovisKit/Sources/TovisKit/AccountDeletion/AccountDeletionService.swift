import Foundation

/// One reason the account cannot be deleted right now.
///
/// `message` is the SERVER's copy and is rendered verbatim — it names the exact
/// obligation ("You have 2 upcoming client appointments…"), which the client
/// cannot reconstruct without re-implementing the eligibility rules. `code` is
/// for identity and diffing only, never for building UI text.
public struct AccountDeletionBlocker: Decodable, Sendable, Equatable, Identifiable {
    public let code: String
    public let message: String

    public var id: String { code }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AccountDeletionEligibility: Decodable, Sendable, Equatable {
    public let eligible: Bool
    public let blockers: [AccountDeletionBlocker]

    public init(eligible: Bool, blockers: [AccountDeletionBlocker]) {
        self.eligible = eligible
        self.blockers = blockers
    }
}

/// An open (or just-resolved) deletion request. Instants are ISO-8601 strings,
/// matching the rest of TovisKit — format them with `Wire.dateOnly` at the
/// display layer rather than decoding to `Date` here.
public struct AccountDeletionRequestView: Decodable, Sendable, Equatable {
    public let id: String
    public let status: String
    /// ISO-8601 instant.
    public let requestedAt: String
    /// ISO-8601 instant: the earliest the deletion may actually run.
    public let scheduledFor: String

    public init(id: String, status: String, requestedAt: String, scheduledFor: String) {
        self.id = id
        self.status = status
        self.requestedAt = requestedAt
        self.scheduledFor = scheduledFor
    }
}

public struct AccountDeletionStatus: Decodable, Sendable, Equatable {
    /// How many days the user has to change their mind. Read from the server
    /// rather than hardcoded, so the window can move without shipping an app.
    public let gracePeriodDays: Int
    public let eligibility: AccountDeletionEligibility
    /// Non-nil while a deletion is scheduled and still cancellable.
    public let pendingRequest: AccountDeletionRequestView?

    public init(
        gracePeriodDays: Int,
        eligibility: AccountDeletionEligibility,
        pendingRequest: AccountDeletionRequestView?
    ) {
        self.gracePeriodDays = gracePeriodDays
        self.eligibility = eligibility
        self.pendingRequest = pendingRequest
    }
}

private struct AccountDeletionStatusResponse: Decodable {
    let accountDeletion: AccountDeletionStatus
}

private struct AccountDeletionRequestResponse: Decodable {
    let request: AccountDeletionRequestView
}

private struct RequestDeletionBody: Encodable {
    let confirmEmail: String
    let reason: String?
}

/// Self-serve account deletion — `GET/POST/DELETE /api/v1/me/account-deletion`.
///
/// Role-agnostic on the wire: the same three verbs back the client app, the pro
/// app and the web settings pages, so there is one deletion contract rather than
/// one per surface.
///
/// Nothing here deletes anything synchronously. `requestDeletion` opens a grace
/// window and a server-side sweep executes it once the window closes, which is
/// what makes a mis-tap recoverable — see `cancel`.
public final class AccountDeletionService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// The current obligations plus any scheduled deletion.
    ///
    /// Safe to call before the user commits to anything — it is how the screen
    /// shows what needs settling first.
    public func status() async throws -> AccountDeletionStatus {
        let response: AccountDeletionStatusResponse = try await api.request("/me/account-deletion")
        return response.accountDeletion
    }

    /// Open the deletion window.
    ///
    /// `confirmEmail` must match the address on the account. The server does the
    /// comparison — a typed email rather than a password, because Apple and
    /// Google sign-in accounts have a random password the user never learns, so
    /// a password gate would lock out exactly the users App Store guideline
    /// 5.1.1(v) exists for.
    ///
    /// Throws `APIError.server(status: 409, …)` when obligations block the
    /// request; re-read `status()` to show which ones.
    public func requestDeletion(
        confirmEmail: String,
        reason: String? = nil
    ) async throws -> AccountDeletionRequestView {
        let body = try JSONEncoder.canonical.encode(
            RequestDeletionBody(confirmEmail: confirmEmail, reason: reason)
        )
        let response: AccountDeletionRequestResponse = try await api.request(
            "/me/account-deletion",
            method: .post,
            body: body
        )
        return response.request
    }

    /// Call off a scheduled deletion while still inside the window.
    public func cancel() async throws {
        try await api.requestVoid("/me/account-deletion", method: .delete)
    }
}
