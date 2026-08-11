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
enum SupabaseSignedUpload {
    /// Consult capture intentionally never receives a bucket or storage path.
    /// Upload only to the exact short-lived URL minted by the server, after
    /// proving it belongs to this build's configured Supabase origin and carries
    /// the token returned in the same response.
    static func putSignedURL(
        session: URLSession,
        supabaseURL: URL?,
        supabaseKey: String?,
        signedURL: URL,
        expectedToken: String,
        data: Data,
        contentType: String
    ) async throws {
        guard let supabaseURL, let supabaseKey,
              signedURL.scheme == supabaseURL.scheme,
              signedURL.host == supabaseURL.host,
              signedURL.port == supabaseURL.port,
              signedURL.path.hasPrefix("/storage/v1/object/upload/sign/"),
              URLComponents(url: signedURL, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" && $0.value == expectedToken }) == true else {
            throw ConsultClientFailure.contractMismatch
        }

        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
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
        guard let supabaseURL, let supabaseKey else {
            throw APIError.transport("Storage configuration missing.")
        }
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent(
                "storage/v1/object/upload/sign/\(bucket)/\(path)"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else {
            throw APIError.transport("Bad upload URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(upsert ? "true" : "false", forHTTPHeaderField: "x-upsert")
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
}
