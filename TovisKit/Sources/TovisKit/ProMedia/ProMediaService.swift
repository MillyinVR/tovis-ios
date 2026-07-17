import Foundation

/// PRO media — uploads photos and lists/edits the pro's library. Authenticated;
/// PRO-only. Two upload pipelines, both presign → signed PUT → record, differing
/// only in what they anchor to:
///
///   • SESSION media (before/after for a booking), ported from the web
///     `MediaUploader.tsx` + `lib/media/uploadWithProgress.ts`:
///       1. `presign`  — POST /api/v1/pro/uploads (booking-scoped, media-private)
///       2. `putBytes` — PUT the bytes straight to Supabase's signed-upload endpoint
///       3. `confirm`  — POST /api/v1/pro/bookings/{id}/media (records the MediaAsset)
///
///   • A NEW POST from scratch (no booking), the counterpart of web's
///     `/pro/media/new` — see `createPost`, which presigns by `kind`, PUTs, then
///     POSTs /api/v1/pro/media.
///
/// The PUT goes directly to Supabase (NOT through APIClient): it carries the
/// signed token + the public `apikey`, and intentionally NO tovis bearer/cookie.
public final class ProMediaService: Sendable {
    private let api: APIClient
    /// Supabase project URL + publishable key — same public creds live-sync uses.
    private let supabaseURL: URL?
    private let supabaseKey: String?
    private let uploadSession: URLSession

    /// `uploadSession` defaults to a fresh ephemeral session (no cookie jar, so the
    /// storage PUT stays clean). It's injectable only so tests can drive the full
    /// presign → PUT → create pipeline through a `URLProtocol`; production always
    /// takes the default.
    public init(
        api: APIClient,
        supabaseURL: URL?,
        supabaseKey: String?,
        uploadSession: URLSession? = nil
    ) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.uploadSession = uploadSession ?? URLSession(configuration: .ephemeral)
    }

    /// One-shot photo upload: presign → PUT → confirm. `imageData` is JPEG bytes.
    /// `focal` is the normalized subject focal point (camera C6) computed on the
    /// captured still — nil (no face / not computed) → the server stores no focal
    /// → the feed cover-crop stays centered (byte-identical to pre-C6).
    @discardableResult
    public func uploadSessionPhoto(
        bookingId: String,
        phase: MediaPhase,
        imageData: Data,
        contentType: String = "image/jpeg",
        caption: String? = nil,
        focal: MediaFocalPoint? = nil
    ) async throws -> ProBookingMediaItem {
        try await upload(
            bookingId: bookingId, phase: phase, data: imageData,
            contentType: contentType, mediaType: .image, caption: caption, focal: focal
        )
    }

    /// One-shot video upload from a recorded clip file (silent .mov → VIDEO).
    /// Lands in the same session media as before/after photos. `posterData` is
    /// an optional JPEG poster frame uploaded alongside the clip so the row gets
    /// a real thumbnail (galleries can't decode a frame from a signed .mov URL);
    /// a failed poster upload never fails the clip — the clip simply confirms
    /// without a thumb.
    @discardableResult
    public func uploadSessionVideo(
        bookingId: String,
        phase: MediaPhase,
        fileURL: URL,
        posterData: Data? = nil,
        contentType: String = "video/quicktime",
        caption: String? = nil
    ) async throws -> ProBookingMediaItem {
        let data = try Data(contentsOf: fileURL)
        let initData = try await presign(
            bookingId: bookingId, phase: phase, contentType: contentType, size: data.count
        )
        try await putBytes(data, to: initData, contentType: contentType)

        var thumbUploadSessionId: String?
        if let posterData {
            do {
                let posterInit = try await presign(
                    bookingId: bookingId, phase: phase,
                    contentType: "image/jpeg", size: posterData.count
                )
                try await putBytes(posterData, to: posterInit, contentType: "image/jpeg")
                thumbUploadSessionId = posterInit.uploadSessionId
            } catch {
                thumbUploadSessionId = nil   // clip beats poster — confirm without it
            }
        }

        return try await confirm(
            bookingId: bookingId,
            uploadSessionId: initData.uploadSessionId,
            phase: phase,
            mediaType: .video,
            caption: caption,
            thumbUploadSessionId: thumbUploadSessionId
        )
    }

    /// Shared 3-step pipeline: presign → PUT bytes → confirm.
    @discardableResult
    private func upload(
        bookingId: String,
        phase: MediaPhase,
        data: Data,
        contentType: String,
        mediaType: MediaType,
        caption: String?,
        focal: MediaFocalPoint? = nil
    ) async throws -> ProBookingMediaItem {
        let initData = try await presign(
            bookingId: bookingId,
            phase: phase,
            contentType: contentType,
            size: data.count
        )
        try await putBytes(data, to: initData, contentType: contentType)
        return try await confirm(
            bookingId: bookingId,
            uploadSessionId: initData.uploadSessionId,
            phase: phase,
            mediaType: mediaType,
            caption: caption,
            focal: focal
        )
    }

    /// GET /api/v1/pro/bookings/{id}/media (optionally filtered by phase) → the
    /// full envelope, including the booking-scoped `clientUseConsent` flag the
    /// session hub reads to show whether the client approved public sharing.
    public func listWithConsent(
        bookingId: String,
        phase: MediaPhase? = nil
    ) async throws -> ProBookingMediaListResponse {
        let query = phase.map { [URLQueryItem(name: "phase", value: $0.rawValue)] }
        return try await api.request("/pro/bookings/\(bookingId)/media", query: query)
    }

    /// GET /api/v1/pro/bookings/{id}/media (optionally filtered by phase) — just
    /// the items (callers that don't need the consent flag).
    public func list(bookingId: String, phase: MediaPhase? = nil) async throws -> [ProBookingMediaItem] {
        try await listWithConsent(bookingId: bookingId, phase: phase).items
    }

    // MARK: - Media manager (web `/pro/media` grid + OwnerMediaMenu editor)

    /// GET /api/v1/pro/media → the pro's own media library (all visibilities) +
    /// the taggable service options. The native read side of the RSC-only web
    /// media manager; there is no web JSON list route, so this endpoint exists for
    /// native. Owner-scoped server-side.
    public func listManagedMedia() async throws -> ProManagedMediaListResponse {
        try await api.request("/pro/media")
    }

    /// PATCH /api/v1/pro/media/{id} — edit a library asset's caption, its Looks /
    /// portfolio flags, its service tags (full-replacement set), and (optionally)
    /// its before/after pairing. Mirrors the web `OwnerMediaMenu` editor's PATCH:
    /// visibility is recomputed server-side from the two flags (never sent), and
    /// `pairing` defaults to `.untouched` so a core edit never clobbers the
    /// server's before/after auto-pairing; pass `.set(id)` / `.set(nil)` only once
    /// the pro touches the pairing picker. No idempotency key — replacing state is
    /// naturally idempotent (matches web + the portfolio toggle). Throws
    /// `APIError.server(...)` on the consent gate (403, unpromoted private media
    /// going public) or an invalid/empty `serviceIds`.
    public func updateMedia(
        mediaId: String,
        caption: String?,
        isEligibleForLooks: Bool,
        isFeaturedInPortfolio: Bool,
        serviceIds: [String],
        pairing: ProMediaPairingEdit = .untouched
    ) async throws {
        let payload = try JSONEncoder.canonical.encode(
            ProMediaUpdateRequest(
                caption: caption,
                isEligibleForLooks: isEligibleForLooks,
                isFeaturedInPortfolio: isFeaturedInPortfolio,
                serviceIds: serviceIds,
                pairing: pairing
            )
        )
        try await api.requestVoid("/pro/media/\(mediaId)", method: .patch, body: payload)
    }

    /// GET /api/v1/pro/media/{id}/before-options — the candidate "before" photos a
    /// pro can pair with this featured "after" (the other images from the after's
    /// booking, phase-ranked). Empty for a video, an after with no booking, or a
    /// booking with no other photos. Feeds the edit sheet's pairing picker.
    public func beforeOptions(mediaId: String) async throws -> [ProMediaBeforeOption] {
        let response: ProMediaBeforeOptionsResponse = try await api.request(
            "/pro/media/\(mediaId)/before-options"
        )
        return response.options
    }

    /// DELETE /api/v1/pro/media/{id} — hard-delete a library asset (owner-only, no
    /// soft-delete). Mirrors the web editor's Delete.
    public func deleteMedia(mediaId: String) async throws {
        try await api.requestVoid("/pro/media/\(mediaId)", method: .delete)
    }

    /// Upload a new avatar (or service image) to its stable public path and return
    /// the cache-busted public URL to store on the profile/offering. Two steps —
    /// presign (`AVATAR_PUBLIC`/`SERVICE_IMAGE_PUBLIC`) → signed PUT (`upsert:true`);
    /// there's no confirm step (the URL is written directly by the profile PATCH).
    public func uploadPublicImage(
        kind: String,
        imageData: Data,
        contentType: String = "image/jpeg",
        serviceId: String? = nil
    ) async throws -> String {
        let payload = try JSONEncoder.canonical.encode(
            KindUploadInitRequest(
                kind: kind, contentType: contentType, size: imageData.count, serviceId: serviceId
            )
        )
        let initData: PublicUploadInit = try await api.request("/pro/uploads", method: .post, body: payload)
        try await putBytes(
            imageData, bucket: initData.bucket, path: initData.path,
            token: initData.token, contentType: contentType, upsert: true
        )
        guard let publicUrl = initData.publicUrl else {
            throw APIError.transport("Upload returned no public URL.")
        }
        // Cache-bust so the stable path's CDN copy refreshes (mirrors web withCacheBuster).
        guard let cb = initData.cacheBuster else { return publicUrl }
        let separator = publicUrl.contains("?") ? "&" : "?"
        return "\(publicUrl)\(separator)v=\(cb)"
    }

    /// Convenience: upload a profile avatar (`AVATAR_PUBLIC`).
    public func uploadAvatar(imageData: Data, contentType: String = "image/jpeg") async throws -> String {
        try await uploadPublicImage(kind: "AVATAR_PUBLIC", imageData: imageData, contentType: contentType)
    }

    /// Convenience: upload a service offering image (`SERVICE_IMAGE_PUBLIC`).
    public func uploadServiceImage(serviceId: String, imageData: Data, contentType: String = "image/jpeg") async throws -> String {
        try await uploadPublicImage(kind: "SERVICE_IMAGE_PUBLIC", imageData: imageData, contentType: contentType, serviceId: serviceId)
    }

    // MARK: - New media post (from scratch)

    /// Create a portfolio/Looks post from a picked photo — the native counterpart
    /// of web's `/pro/media/new` submit. Three steps, in the same order web runs
    /// them (upload first, then create):
    ///   1. `presignPost` — POST /pro/uploads with the draft's `kind`
    ///   2. signed PUT of the JPEG bytes
    ///   3. POST /pro/media, which mints the MediaAsset (+ a LookPost, per §19b)
    ///
    /// The bytes land in the bucket BEFORE the create runs, so a create failure
    /// leaves an orphaned object with an unconsumed UploadSession — the same
    /// trade web makes, and the reason the draft's rules are validated up front
    /// rather than discovered by a 400.
    ///
    /// `focal` is the subject's normalized center (from the same face detection
    /// the camera uses). Pass nil for a photo with no detectable face: the server
    /// stores no focal and cover-crops from the center, exactly as it always has.
    @discardableResult
    public func createPost(
        draft: NewMediaPostDraft,
        imageData: Data,
        focal: MediaFocalPoint?,
        contentType: String = "image/jpeg",
        idempotencyKey: String? = nil
    ) async throws -> ProMediaCreated {
        let initData = try await presignPost(
            kind: draft.uploadKind,
            contentType: contentType,
            size: imageData.count
        )

        try await putBytes(imageData, to: initData, contentType: contentType)

        let payload = try JSONEncoder.canonical.encode(
            draft.createRequest(uploadSessionId: initData.uploadSessionId, focal: focal)
        )

        // Key off the upload session like the booking-media confirm does — it's the
        // server's own dedup anchor, so a retried create collapses onto one asset
        // instead of double-attaching (which the route rolls back anyway).
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-media", entityId: initData.uploadSessionId, action: "create",
            nonce: idempotencyNonce(payload))

        let response: ProMediaCreateResponse = try await api.request(
            "/pro/media",
            method: .post,
            body: payload,
            headers: ["Idempotency-Key": key, "x-idempotency-key": key]
        )
        return response.media
    }

    /// Presign a bookingless portfolio/Looks upload. Unlike the stable-path public
    /// kinds, these mint a dated unique path AND an UploadSession — which is the
    /// handle `POST /pro/media` resolves the storage pointer from, so the client
    /// never sends a bucket/path.
    func presignPost(kind: String, contentType: String, size: Int) async throws -> MediaUploadInit {
        let payload = try JSONEncoder.canonical.encode(
            KindUploadInitRequest(kind: kind, contentType: contentType, size: size, serviceId: nil)
        )
        return try await api.request("/pro/uploads", method: .post, body: payload)
    }

    // MARK: - Steps

    /// Step 1 — get a presigned, booking-scoped upload target (media-private).
    public func presign(
        bookingId: String,
        phase: MediaPhase,
        contentType: String,
        size: Int
    ) async throws -> MediaUploadInit {
        let payload = try JSONEncoder.canonical.encode(
            MediaUploadInitRequest(
                kind: "CONSULT_PRIVATE",   // booking-scoped → bookings/<id>/<phase>/…
                bookingId: bookingId,
                phase: phase.rawValue,
                contentType: contentType,
                size: size
            )
        )
        return try await api.request("/pro/uploads", method: .post, body: payload)
    }

    /// Step 2 — PUT the bytes to Supabase's signed-upload endpoint.
    /// ⚠️ MUST be PUT: the signed `token` authorizes the write and bypasses RLS
    /// only on PUT; a POST runs as anon and fails the media-private INSERT policy
    /// (see lib/media/uploadWithProgress.ts). `apikey` routes the gateway; no
    /// Authorization bearer (the token is the sole authorizer).
    public func putBytes(_ data: Data, to initData: MediaUploadInit, contentType: String) async throws {
        try await putBytes(data, bucket: initData.bucket, path: initData.path,
                           token: initData.token, contentType: contentType, upsert: false)
    }

    /// Lower-level signed PUT used by both the booking-media pipeline (`upsert:false`,
    /// unique paths) and the stable public uploads (`upsert:true` — avatar/service
    /// image paths are intentionally overwritten, mirroring the web's `upsert:true`).
    public func putBytes(
        _ data: Data, bucket: String, path: String, token: String,
        contentType: String, upsert: Bool
    ) async throws {
        try await SupabaseSignedUpload.put(
            session: uploadSession,
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            data: data,
            bucket: bucket,
            path: path,
            token: token,
            contentType: contentType,
            upsert: upsert
        )
    }

    /// Step 3 — record the MediaAsset against the booking + phase. Idempotent on
    /// the upload session (a retry of the same confirm dedupes server-side).
    @discardableResult
    public func confirm(
        bookingId: String,
        uploadSessionId: String,
        phase: MediaPhase,
        mediaType: MediaType,
        caption: String? = nil,
        thumbUploadSessionId: String? = nil,
        focal: MediaFocalPoint? = nil,
        idempotencyKey: String? = nil
    ) async throws -> ProBookingMediaItem {
        let payload = try JSONEncoder.canonical.encode(
            MediaConfirmRequest(
                uploadSessionId: uploadSessionId,
                thumbUploadSessionId: thumbUploadSessionId,
                phase: phase.rawValue,
                mediaType: mediaType.rawValue,
                caption: caption,
                focalX: focal?.x,
                focalY: focal?.y
            )
        )
        // Key off the upload session (the server's own dedup anchor) so a retry of
        // the same confirm collapses to one MediaAsset.
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "pro-media", entityId: uploadSessionId, action: "confirm",
            nonce: idempotencyNonce(payload))
        let response: ProBookingMediaCreateResponse = try await api.request(
            "/pro/bookings/\(bookingId)/media",
            method: .post,
            body: payload,
            headers: ["Idempotency-Key": key, "x-idempotency-key": key]
        )
        return response.item
    }
}
