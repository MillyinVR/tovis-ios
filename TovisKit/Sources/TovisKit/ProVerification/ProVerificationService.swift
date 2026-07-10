import Foundation

/// PRO workspace — license / document verification. The native counterpart to the
/// web /pro/verification page. Authenticated; PRO-only (a CLIENT token 403s).
///
/// Reads the verification snapshot (GET /pro/verification) and drives the three
/// mutations the page offers, each reusing an existing endpoint:
///   - `saveLicense`    → PATCH /pro/license          (self-edit; flags re-review)
///   - `uploadDocument` → POST /pro/uploads → signed PUT → POST /pro/verification-docs
///   - `deleteDocument` → DELETE /pro/verification-docs/{id}  (pending docs only)
///
/// The signed PUT to Supabase reuses `ProMediaService.putBytes` so the RLS-critical
/// PUT-not-POST + apikey + x-upsert semantics live in exactly one place.
public final class ProVerificationService: Sendable {
    private let api: APIClient
    private let media: ProMediaService

    public init(api: APIClient, media: ProMediaService) {
        self.api = api
        self.media = media
    }

    /// GET /api/v1/pro/verification → status + license + accepted methods + docs.
    public func verification() async throws -> ProVerification {
        let response: ProVerificationResponse = try await api.request("/pro/verification")
        return response.verification
    }

    /// PATCH /api/v1/pro/license — self-edit license state / number / expiry.
    /// Sends the profile back for admin re-review; it does NOT change verification
    /// status or cut access. `expiry` is "YYYY-MM-DD" (or "" to clear).
    public func saveLicense(state: String, number: String, expiry: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            VerificationLicenseSaveRequest(
                licenseState: state,
                licenseNumber: number,
                licenseExpiry: expiry
            )
        )
        try await api.requestVoid("/pro/license", method: .patch, body: payload)
    }

    /// Upload one verification document: presign (`VERIFY_PRIVATE`, media-private)
    /// → signed PUT to Supabase → record the `VerificationDocument`. Mirrors the
    /// web `VerificationUploadClient` 3-step flow. `type` is a method's raw type
    /// (server SSOT, echoed back); `title` labels the row. `imageData` is JPEG bytes.
    public func uploadDocument(
        type: String,
        title: String,
        imageData: Data,
        contentType: String = "image/jpeg"
    ) async throws {
        // 1) presign — VERIFY_PRIVATE lands in media-private with no UploadSession.
        let presignBody = try JSONEncoder.canonical.encode(
            VerificationUploadInitRequest(
                kind: "VERIFY_PRIVATE",
                contentType: contentType,
                size: imageData.count
            )
        )
        let initData: VerificationUploadInit = try await api.request(
            "/pro/uploads", method: .post, body: presignBody
        )

        // 2) signed PUT straight to Supabase (upsert:false — verification docs are
        // unique paths, never overwritten).
        try await media.putBytes(
            imageData,
            bucket: initData.bucket,
            path: initData.path,
            token: initData.token,
            contentType: contentType,
            upsert: false
        )

        // 3) record the VerificationDocument row (the pointer the presign returned).
        let createBody = try JSONEncoder.canonical.encode(
            VerificationDocCreateRequest(
                type: type,
                label: "\(title) (pro upload)",
                url: "supabase://\(initData.bucket)/\(initData.path)"
            )
        )
        try await api.requestVoid("/pro/verification-docs", method: .post, body: createBody)
    }

    /// DELETE /api/v1/pro/verification-docs/{id} — remove a still-pending doc (e.g.
    /// a blurry photo to replace). Reviewed docs are the admin audit trail (409).
    public func deleteDocument(id: String) async throws {
        try await api.requestVoid("/pro/verification-docs/\(id)", method: .delete)
    }
}
