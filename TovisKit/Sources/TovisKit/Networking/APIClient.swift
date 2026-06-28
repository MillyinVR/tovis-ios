import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Thin async HTTP client over the backend's `/api/v1` surface.
///
/// - Injects `Authorization: Bearer <token>` when `authenticated` is true and a
///   token is present (native has no cookie jar — see the auth docs).
/// - On a 401 it attempts a single token refresh via the injected `refresh`
///   closure, then retries the request once.
/// - Decodes success bodies straight into the response DTO (the envelope's
///   `ok: true` field is simply ignored — `Decodable` skips unknown keys).
/// - Maps `{ ok:false, error, code }` bodies into `APIError.server`.
public final class APIClient: Sendable {
    private let config: TovisConfig
    private let session: URLSession
    private let tokenStore: TokenStore
    private let refresh: @Sendable () async -> Bool

    public init(
        config: TovisConfig,
        session: URLSession = .shared,
        tokenStore: TokenStore,
        refresh: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.config = config
        self.session = session
        self.tokenStore = tokenStore
        self.refresh = refresh
    }

    /// Perform a request and decode the JSON response.
    public func request<Response: Decodable>(
        _ path: String,
        method: HTTPMethod = .get,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String: String]? = nil,
        authenticated: Bool = true,
        retryOn401: Bool = true
    ) async throws -> Response {
        let data = try await perform(
            path,
            method: method,
            query: query,
            body: body,
            headers: headers,
            authenticated: authenticated,
            retryOn401: retryOn401
        )
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Perform a request where the body is irrelevant; throws on non-2xx.
    @discardableResult
    public func requestVoid(
        _ path: String,
        method: HTTPMethod = .get,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String: String]? = nil,
        authenticated: Bool = true,
        retryOn401: Bool = true
    ) async throws -> Data {
        try await perform(
            path,
            method: method,
            query: query,
            body: body,
            headers: headers,
            authenticated: authenticated,
            retryOn401: retryOn401
        )
    }

    // MARK: - Core

    private func perform(
        _ path: String,
        method: HTTPMethod,
        query: [URLQueryItem]? = nil,
        body: Data?,
        headers: [String: String]? = nil,
        authenticated: Bool,
        retryOn401: Bool
    ) async throws -> Data {
        let request = await buildRequest(path, method: method, query: query, body: body, headers: headers, authenticated: authenticated)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if (200..<300).contains(http.statusCode) {
            return data
        }

        // 401: try a single refresh + retry.
        if http.statusCode == 401, authenticated, retryOn401 {
            if await refresh() {
                return try await perform(
                    path,
                    method: method,
                    query: query,
                    body: body,
                    headers: headers,
                    authenticated: authenticated,
                    retryOn401: false
                )
            }
            throw APIError.unauthorized
        }

        let parsed = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        throw APIError.server(status: http.statusCode, message: parsed?.error, code: parsed?.code)
    }

    private func buildRequest(
        _ path: String,
        method: HTTPMethod,
        query: [URLQueryItem]? = nil,
        body: Data?,
        headers: [String: String]? = nil,
        authenticated: Bool
    ) async -> URLRequest {
        let base = config.baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var url = base
        if let query, !query.isEmpty,
           var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            url = comps.url ?? base
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if authenticated, let token = await tokenStore.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let headers {
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        }

        return request
    }
}