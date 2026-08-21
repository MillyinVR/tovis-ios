import Foundation

/// PRO practice library — the shots taken with the standalone camera (the pro
/// footer's centre button when no session is live). Authenticated; PRO-only.
///
/// Same three-step upload pipeline the session camera uses (presign → signed PUT
/// → confirm), differing only in what it anchors to: nothing. There is no
/// booking and no phase, so nothing is owed and no session gate moves.
///
///   1. `presign` — POST /pro/uploads with `kind: PRACTICE_PRIVATE`
///   2. `putBytes` — the signed PUT, reused from `ProMediaService` (the media
///      upload is a Supabase concern, not a per-feature one)
///   3. `confirm`  — POST /pro/practice, which mints the PracticeShot
///
/// The whole surface is behind the server's `pro_practice_disabled` kill switch;
/// when it's on, every call here throws `APIError.server` carrying the 503.
public final class ProPracticeService: Sendable {
    private let api: APIClient
    /// The signed-PUT half is `ProMediaService`'s — deliberately reused rather
    /// than re-implemented, so there is one place that knows how to talk to
    /// Supabase storage.
    private let media: ProMediaService

    public init(api: APIClient, media: ProMediaService) {
        self.api = api
        self.media = media
    }

    // MARK: - Upload

    /// Upload one practice photo: presign → PUT → confirm. `focal` is the
    /// normalized subject focal point (camera C6) from the same face detection
    /// the session camera uses; nil is fine (the crop stays centered).
    @discardableResult
    public func upload(
        imageData: Data,
        contentType: String = "image/jpeg",
        caption: String? = nil,
        focal: MediaFocalPoint? = nil
    ) async throws -> ProPracticeShot {
        let initData = try await presign(contentType: contentType, size: imageData.count)
        try await media.putBytes(imageData, to: initData, contentType: contentType)
        return try await confirm(
            uploadSessionId: initData.uploadSessionId,
            mediaType: .image,
            caption: caption,
            focal: focal
        )
    }

    /// Step 1 — presign a bookingless, private practice upload.
    ///
    /// Public because the app-level upload queue drives the three steps
    /// itself (it owns the background transfer between them) rather than
    /// calling `upload(imageData:)`, which does all three inline.
    public func presign(contentType: String, size: Int) async throws -> MediaUploadInit {
        let payload = try JSONEncoder.canonical.encode(
            KindUploadInitRequest(
                kind: "PRACTICE_PRIVATE", contentType: contentType, size: size, serviceId: nil
            )
        )
        return try await api.request("/pro/uploads", method: .post, body: payload)
    }

    /// Step 3 — mint the PracticeShot. Keyed off the upload session (the
    /// server's own dedup anchor) so a retried confirm collapses onto one shot
    /// rather than two rows over the same bytes.
    @discardableResult
    public func confirm(
        uploadSessionId: String,
        mediaType: MediaType = .image,
        caption: String? = nil,
        focal: MediaFocalPoint? = nil,
        idempotencyKey: String? = nil
    ) async throws -> ProPracticeShot {
        let payload = try JSONEncoder.canonical.encode(
            ProPracticeConfirmRequest(
                uploadSessionId: uploadSessionId,
                mediaType: mediaType.rawValue,
                caption: caption,
                focalX: focal?.x,
                focalY: focal?.y
            )
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-practice", entityId: uploadSessionId, action: "confirm",
            nonce: idempotencyNonce(payload))
        let response: ProPracticeCreateResponse = try await api.request(
            "/pro/practice",
            method: .post,
            body: payload,
            headers: ["Idempotency-Key": key, "x-idempotency-key": key]
        )
        return response.shot
    }

    // MARK: - Library

    /// GET /pro/practice → the pro's practice library, newest first, each with a
    /// short-lived signed render URL.
    public func list() async throws -> [ProPracticeShot] {
        let response: ProPracticeListResponse = try await api.request("/pro/practice")
        return response.items
    }

    /// DELETE /pro/practice/{id} — drop one shot (row and bytes). Safe even when
    /// the shot was attached: attaching COPIES the bytes, so the media promoted
    /// from it keeps its own object.
    public func delete(shotId: String) async throws {
        try await api.requestVoid("/pro/practice/\(shotId)", method: .delete)
    }

    /// POST /pro/practice/{id}/attach — promote a shot into real media.
    ///
    /// Throws `APIError.server` with the server's own sentence on a refusal:
    /// 409 when the shot was already attached, and — for `.booking` — whatever
    /// the booking write boundary says (a completed or cancelled booking will
    /// not take media).
    @discardableResult
    public func attach(
        shotId: String,
        to target: ProPracticeAttachTarget,
        caption: String? = nil
    ) async throws -> ProPracticeAttachResult {
        let payload = try JSONEncoder.canonical.encode(
            ProPracticeAttachRequest(target: target, caption: caption)
        )
        let key = buildClientIdempotencyKey(
            scope: "pro-practice", entityId: shotId, action: "attach",
            nonce: idempotencyNonce(payload))
        return try await api.request(
            "/pro/practice/\(shotId)/attach",
            method: .post,
            body: payload,
            headers: ["Idempotency-Key": key, "x-idempotency-key": key]
        )
    }
}
