import Foundation

/// PRO session media — uploads before/after photos for a booking and lists them.
/// Authenticated; PRO-only. Three-step pipeline, ported from the web
/// `MediaUploader.tsx` + `lib/media/uploadWithProgress.ts`:
///
///   1. `presign`  — POST /api/v1/pro/uploads (booking-scoped, media-private)
///   2. `putBytes` — PUT the bytes straight to Supabase's signed-upload endpoint
///   3. `confirm`  — POST /api/v1/pro/bookings/{id}/media (records the MediaAsset)
///
/// The PUT goes directly to Supabase (NOT through APIClient): it carries the
/// signed token + the public `apikey`, and intentionally NO tovis bearer/cookie.
public final class ProMediaService: Sendable {
    private let api: APIClient
    /// Supabase project URL + publishable key — same public creds live-sync uses.
    private let supabaseURL: URL?
    private let supabaseKey: String?
    private let uploadSession: URLSession

    public init(api: APIClient, supabaseURL: URL?, supabaseKey: String?) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        // Ephemeral (no cookie jar) so the storage PUT stays clean.
        self.uploadSession = URLSession(configuration: .ephemeral)
    }

    /// One-shot: presign → upload bytes → confirm. Returns the created media row.
    /// `imageData` is JPEG bytes from the camera; `mediaType` defaults to image.
    @discardableResult
    public func uploadSessionPhoto(
        bookingId: String,
        phase: MediaPhase,
        imageData: Data,
        contentType: String = "image/jpeg",
        caption: String? = nil
    ) async throws -> ProBookingMediaItem {
        let initData = try await presign(
            bookingId: bookingId,
            phase: phase,
            contentType: contentType,
            size: imageData.count
        )
        try await putBytes(imageData, to: initData, contentType: contentType)
        return try await confirm(
            bookingId: bookingId,
            uploadSessionId: initData.uploadSessionId,
            phase: phase,
            mediaType: .image,
            caption: caption
        )
    }

    /// GET /api/v1/pro/bookings/{id}/media (optionally filtered by phase).
    public func list(bookingId: String, phase: MediaPhase? = nil) async throws -> [ProBookingMediaItem] {
        let query = phase.map { [URLQueryItem(name: "phase", value: $0.rawValue)] }
        let response: ProBookingMediaListResponse = try await api.request(
            "/pro/bookings/\(bookingId)/media",
            query: query
        )
        return response.items
    }

    // MARK: - Steps

    /// Step 1 — get a presigned, booking-scoped upload target (media-private).
    public func presign(
        bookingId: String,
        phase: MediaPhase,
        contentType: String,
        size: Int
    ) async throws -> MediaUploadInit {
        let payload = try JSONEncoder().encode(
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
        guard let supabaseURL, let supabaseKey else {
            throw APIError.transport("Storage configuration missing.")
        }
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent(
                "storage/v1/object/upload/sign/\(initData.bucket)/\(initData.path)"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "token", value: initData.token)]
        guard let url = components?.url else {
            throw APIError.transport("Bad upload URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = data

        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await uploadSession.data(for: request)
        } catch {
            throw APIError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: respData, encoding: .utf8)
            throw APIError.server(status: http.statusCode, message: message, code: nil)
        }
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
        idempotencyKey: String = UUID().uuidString
    ) async throws -> ProBookingMediaItem {
        let payload = try JSONEncoder().encode(
            MediaConfirmRequest(
                uploadSessionId: uploadSessionId,
                phase: phase.rawValue,
                mediaType: mediaType.rawValue,
                caption: caption
            )
        )
        let response: ProBookingMediaCreateResponse = try await api.request(
            "/pro/bookings/\(bookingId)/media",
            method: .post,
            body: payload,
            headers: ["Idempotency-Key": idempotencyKey, "x-idempotency-key": idempotencyKey]
        )
        return response.item
    }
}
