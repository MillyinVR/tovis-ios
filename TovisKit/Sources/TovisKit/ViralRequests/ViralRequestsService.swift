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
    /// Supabase project URL + publishable key — the same public creds every other
    /// native uploader signs with. Nil disables attaching; submitting still works.
    private let supabaseURL: URL?
    private let supabaseKey: String?
    /// Ephemeral (no cookie jar) so the RLS-critical signed PUT stays clean.
    /// Injectable for tests — the PUT is the leg most worth asserting on, and a
    /// session built in here can only ever reach the real network.
    private let uploadSession: URLSession

    public init(
        api: APIClient,
        uploadSession: URLSession? = nil,
        supabaseURL: URL? = nil,
        supabaseKey: String? = nil
    ) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.uploadSession = uploadSession ?? URLSession(configuration: .ephemeral)
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

    /// Sends the photo or video the submitter picked, in the only order the
    /// server allows: **sign → PUT → record**.
    ///
    /// The signing route is keyed on the request id, so the file can only go up
    /// after the request exists — which is why this is a second call rather than
    /// a field on `submit`. The final PATCH is what actually puts the file in
    /// front of a reviewer: bytes in the bucket that nothing points at are
    /// invisible, which is exactly the state the route shipped in.
    ///
    /// 🔴 Attaching does NOT publish anything. The file is evidence in
    /// `/admin/viral-requests`; only an admin promotes one to the picture a look
    /// is shown by.
    ///
    /// Each call mints a fresh object name, so a retry after a failed PUT cannot
    /// collide with a half-written object (the signed token is `upsert: false`).
    /// The cost is an unreferenced object per failed attempt, which is cheaper
    /// than a retry that can never succeed.
    @discardableResult
    public func attach(
        requestId: String,
        attachment: ViralLookAttachment
    ) async throws -> ViralRequestSubmission {
        guard supabaseURL != nil, supabaseKey != nil else {
            throw APIError.transport("Storage configuration missing.")
        }

        let initPayload = try JSONEncoder.canonical.encode(
            ViralRequestUploadInitRequest(
                requestId: requestId,
                fileName: Self.uploadFileName(fileExtension: attachment.fileExtension),
                contentType: attachment.contentType,
                size: attachment.data.count))

        let target: ViralRequestUploadInit = try await api.request(
            "/viral-service-requests/upload",
            method: .post,
            body: initPayload)

        try await SupabaseSignedUpload.put(
            session: uploadSession,
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            data: attachment.data,
            bucket: target.bucket,
            path: target.path,
            token: target.token,
            contentType: attachment.contentType,
            // Must match what the route signed with, or storage refuses the PUT.
            upsert: false)

        let attachPayload = try JSONEncoder.canonical.encode(
            ViralRequestAttachMediaRequest(mediaUrl: target.publicUrl))

        let response: ViralRequestCreateResponse = try await api.request(
            "/viral-service-requests/\(requestId)",
            method: .patch,
            body: attachPayload)

        return response.request
    }

    /// The object name each attach mints: `attachment-<8 hex>.<ext>`.
    ///
    /// The server sanitizes it again (lowercased, directories stripped), so this
    /// only has to be unique and extension-bearing — the extension is what makes
    /// the admin queue draw a video as a player rather than a broken image.
    static func uploadFileName(
        fileExtension: String,
        nonce: String = UUID().uuidString
    ) -> String {
        let ext = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let stem = nonce
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()

        return ext.isEmpty ? "attachment-\(stem)" : "attachment-\(stem).\(ext)"
    }
}
