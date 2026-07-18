import Foundation

/// Client-submitted viral look requests — the native counterpart of the web
/// `SubmitViralLookForm` (app/client/(gated)/_components/SubmitViralLookForm.tsx),
/// backed by `POST /api/v1/viral-service-requests`. Authenticated (bearer token);
/// the caller must be signed in as a CLIENT or the backend returns 401/403.
///
/// The submitted row lands as `REQUESTED` and surfaces on the next
/// `GET /client/home` under `viralPending` (server-side that query is scoped to
/// the submitting client and to `REQUESTED`/`IN_REVIEW`), which is what the Viral
/// Looks band's "Your request" pipeline already renders — so callers refresh home
/// after a successful submit instead of splicing the row in locally.
///
/// ⚠️ The route runs **no idempotency wrapper and no rate limit** — driven
/// 2026-07-18: posting the same body twice with an identical `Idempotency-Key`
/// created two distinct rows, and eight rapid POSTs all returned 201. A
/// double-tap therefore creates a duplicate request a human admin has to moderate
/// twice, so **the caller owns the debounce** (same shape as `reportComment`).
public final class ViralRequestsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// POST /api/v1/viral-service-requests → the created request (201).
    ///
    /// Mirrors the web form's payload exactly: `name` (required, ≤160 characters
    /// after trimming) plus an optional `sourceUrl`, which is omitted entirely
    /// when blank.
    ///
    /// Server-side validation copy is already user-readable and reaches callers
    /// unchanged through `APIError.userMessage` — "Viral request name is
    /// required.", "sourceUrl must be a valid URL.", "sourceUrl must use http or
    /// https.", "Viral request name must be 160 characters or fewer." — so show
    /// that message rather than inventing a second vocabulary for the same rule.
    public func submit(
        name: String,
        sourceUrl: String? = nil
    ) async throws -> ViralRequestSubmission {
        let body = try JSONEncoder.canonical.encode(
            ViralRequestCreateRequest(name: name, sourceUrl: sourceUrl)
        )
        let response: ViralRequestCreateResponse = try await api.request(
            "/viral-service-requests",
            method: .post,
            body: body
        )
        return response.request
    }

    /// Convenience over ``submit(name:sourceUrl:)`` taking the form's draft, so
    /// the trimming rules live with the draft instead of at each call site.
    /// Returns nil without touching the network when the draft can't be submitted
    /// (blank name) — the caller should be gating on `draft.canSubmit` anyway.
    public func submit(draft: ViralLookDraft) async throws -> ViralRequestSubmission? {
        guard let name = draft.trimmedName else { return nil }
        return try await submit(name: name, sourceUrl: draft.trimmedSourceUrl)
    }
}
