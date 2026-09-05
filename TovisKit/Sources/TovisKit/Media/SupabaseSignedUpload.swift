import Foundation

/// The RLS-critical Supabase signed-upload PUT, shared by every native uploader
/// (PRO session/verification media and message attachments).
///
/// ⚠️ MUST be PUT: the signed `token` authorizes the write and bypasses RLS only
/// on PUT; a POST runs as anon and fails the media-private INSERT policy (see the
/// web `lib/media/uploadWithProgress.ts`). `apikey` routes the storage gateway;
/// there is deliberately NO Authorization bearer/cookie — the token is the sole
/// authorizer. The upload session should be ephemeral (no cookie jar) so the PUT
/// stays clean.
public enum SupabaseSignedUpload {
    /// Consult capture intentionally never receives a bucket or storage path.
    /// Upload only to the exact short-lived URL minted by the server, after
    /// proving it belongs to this build's configured Supabase origin and carries
    /// the token returned in the same response.
    ///
    /// The RLS contract is shaped ONCE, here, and both the foreground
    /// `putSignedURL` below and the durable queue's BACKGROUND upload task go
    /// through it — so "must be PUT, apikey only, no bearer, no upsert" is
    /// stated in one place rather than copied into the queue.
    ///
    /// ⚠️ The returned request deliberately carries NO `httpBody`. A background
    /// `URLSession` rejects a request with an in-memory body and must be given
    /// `fromFile:`; the foreground caller attaches its own body.
    public static func signedURLUploadRequest(
        supabaseURL: URL?,
        supabaseKey: String?,
        signedURL: URL,
        expectedToken: String,
        contentType: String
    ) throws -> URLRequest {
        guard let supabaseURL, let supabaseKey,
              signedURL.scheme == supabaseURL.scheme,
              signedURL.host == supabaseURL.host,
              signedURL.port == supabaseURL.port,
              signedURL.path.hasPrefix("/" + uploadSignPrefix),
              URLComponents(url: signedURL, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" && $0.value == expectedToken }) == true else {
            throw ConsultClientFailure.contractMismatch
        }

        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        return request
    }

    static func putSignedURL(
        session: URLSession,
        supabaseURL: URL?,
        supabaseKey: String?,
        signedURL: URL,
        expectedToken: String,
        data: Data,
        contentType: String
    ) async throws {
        var request = try signedURLUploadRequest(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            signedURL: signedURL,
            expectedToken: expectedToken,
            contentType: contentType
        )
        request.httpBody = data

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw ConsultClientFailure.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConsultClientFailure.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            // Never lift a storage response body into an error: it can contain a
            // private object path or provider detail.
            throw ConsultClientFailure.unavailable
        }
    }

    static func put(
        session: URLSession,
        supabaseURL: URL?,
        supabaseKey: String?,
        data: Data,
        bucket: String,
        path: String,
        token: String,
        contentType: String,
        upsert: Bool
    ) async throws {
        guard let supabaseKey else {
            throw APIError.transport("Storage configuration missing.")
        }
        guard var request = signedUploadRequest(
            supabaseURL: supabaseURL, supabaseKey: supabaseKey, bucket: bucket,
            path: path, token: token, contentType: contentType, upsert: upsert
        ) else {
            throw APIError.transport("Bad upload URL.")
        }
        request.httpBody = data

        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: respData, encoding: .utf8)
            throw APIError.server(status: http.statusCode, message: message, code: nil)
        }
    }

    // MARK: - Request building

    /// The one place the signed-upload PUT is shaped. Both the foreground `put`
    /// above and the background-session variant below go through it, so the
    /// RLS-critical contract (PUT, `apikey`, no Authorization bearer, `x-upsert`)
    /// is stated once rather than copied.
    static func signedUploadRequest(
        supabaseURL: URL?,
        supabaseKey: String,
        bucket: String,
        path: String,
        token: String,
        contentType: String,
        upsert: Bool
    ) -> URLRequest? {
        guard let supabaseURL else { return nil }
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("\(uploadSignPrefix)\(bucket)/\(path)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(upsert ? "true" : "false", forHTTPHeaderField: "x-upsert")
        return request
    }

    /// A request for a BACKGROUND `URLSession` upload task.
    ///
    /// ⚠️ Deliberately carries NO `httpBody`: a background session rejects a
    /// request with an in-memory body and must be given `fromFile:` instead —
    /// which is also why the byte vault's file, rather than a `Data` in RAM, is
    /// what gets uploaded. Everything else is byte-identical to the foreground
    /// PUT, and `upsert` is false for the same reason it is there: these paths
    /// are minted unique per upload and must never overwrite.
    public static func backgroundUploadRequest(
        supabaseURL: URL?,
        supabaseKey: String?,
        bucket: String,
        path: String,
        token: String,
        contentType: String
    ) -> URLRequest? {
        guard let supabaseKey else { return nil }
        return signedUploadRequest(
            supabaseURL: supabaseURL, supabaseKey: supabaseKey, bucket: bucket,
            path: path, token: token, contentType: contentType, upsert: false
        )
    }

    private static let uploadSignPrefix = "storage/v1/object/upload/sign/"

    /// Recover the storage path from a signed-upload URL.
    ///
    /// This is how a background task that outlived its process is matched back
    /// to the photo it belongs to: after the app is killed and relaunched, the
    /// only thing guaranteed to come back with the task is its request. Returns
    /// nil for any URL that isn't a signed upload.
    public static func storagePath(fromSignedUploadURL url: URL) -> String? {
        let marker = "/" + uploadSignPrefix
        guard let range = url.path.range(of: marker) else { return nil }
        let remainder = String(url.path[range.upperBound...])
        // Drop the bucket segment; what's left is the object path.
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        let path = String(remainder[remainder.index(after: slash)...])
        return path.isEmpty ? nil : path
    }
}
