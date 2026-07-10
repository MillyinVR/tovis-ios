import Foundation
import Testing
@testable import TovisKit

// Covers the client review authoring service (§5 A3-rev 4a): create (POST) with a
// body-derived idempotency key, edit (PATCH), and delete (DELETE) — the native
// mirror of the web review routes. Text only; media attachments are 4b.

/// A capturing URLProtocol with its OWN static storage so it never races the
/// checkout suites' mocks when @Suites run in parallel.
final class ReviewsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        Self.capturedBody = request.httpBody ?? request.bodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ReviewsServiceTests {
    private func makeService() async -> ReviewsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.reviews.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ReviewsService(api: api)
    }

    private func reset(_ body: String) {
        ReviewsURLProtocol.capturedPath = nil
        ReviewsURLProtocol.capturedMethod = nil
        ReviewsURLProtocol.capturedIdempotencyKey = nil
        ReviewsURLProtocol.capturedBody = nil
        ReviewsURLProtocol.responseBody = Data(body.utf8)
    }

    private static let reviewOk = """
    {"ok":true,"review":{"id":"rev_1","rating":5,"headline":"Loved it","body":"Best color of my life.","mediaAssets":[]}}
    """

    @Test func submitPostsReviewWithIdempotencyKeyAndDecodes() async throws {
        reset(Self.reviewOk)

        let review = try await makeService().submitReview(
            bookingId: "bkg_1", rating: 5, headline: "Loved it", body: "Best color of my life.")

        #expect(ReviewsURLProtocol.capturedPath == "/api/v1/client/bookings/bkg_1/review")
        #expect(ReviewsURLProtocol.capturedMethod == "POST")
        // The create route requires an idempotency key.
        #expect((ReviewsURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(ReviewsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["rating"] as? Int == 5)
        #expect(json["headline"] as? String == "Loved it")
        #expect(json["body"] as? String == "Best color of my life.")

        #expect(review.id == "rev_1")
        #expect(review.rating == 5)
        #expect(review.headline == "Loved it")
    }

    @Test func submitTrimsTextAndClearsEmptyToBlank() async throws {
        reset(Self.reviewOk)

        _ = try await makeService().submitReview(
            bookingId: "bkg_1", rating: 4, headline: "  spaced  ", body: nil)

        let body = try #require(ReviewsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Headline is trimmed; a nil body serializes as "" (cleared server-side).
        #expect(json["headline"] as? String == "spaced")
        #expect(json["body"] as? String == "")
    }

    @Test func submitIdempotencyKeyTracksContent() async throws {
        // Same content within the bucket → same key (dedupe a double-tap); a
        // changed rating/text → fresh key. Mirrors the web nonce contract.
        reset(Self.reviewOk)
        _ = try await makeService().submitReview(bookingId: "bkg_1", rating: 5, headline: "A", body: "B")
        let key1 = ReviewsURLProtocol.capturedIdempotencyKey

        reset(Self.reviewOk)
        _ = try await makeService().submitReview(bookingId: "bkg_1", rating: 5, headline: "A", body: "B")
        let key1Again = ReviewsURLProtocol.capturedIdempotencyKey

        reset(Self.reviewOk)
        _ = try await makeService().submitReview(bookingId: "bkg_1", rating: 4, headline: "A", body: "B")
        let key2 = ReviewsURLProtocol.capturedIdempotencyKey

        #expect(key1 == key1Again)
        #expect(key1 != key2)
    }

    @Test func updatePatchesExistingReview() async throws {
        reset("""
        {"ok":true,"review":{"id":"rev_1","rating":3,"headline":"Updated","body":null,"mediaAssets":[]}}
        """)

        let review = try await makeService().updateReview(
            reviewId: "rev_1", rating: 3, headline: "Updated", body: "")

        #expect(ReviewsURLProtocol.capturedPath == "/api/v1/client/reviews/rev_1")
        #expect(ReviewsURLProtocol.capturedMethod == "PATCH")

        let body = try #require(ReviewsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["rating"] as? Int == 3)
        #expect(json["headline"] as? String == "Updated")
        // Empty body → "" so the server clears it (empty → null).
        #expect(json["body"] as? String == "")

        #expect(review.rating == 3)
        #expect(review.body == nil)
    }

    @Test func deleteSendsDeleteToReviewId() async throws {
        reset("{\"ok\":true}")

        try await makeService().deleteReview(reviewId: "rev_1")

        #expect(ReviewsURLProtocol.capturedPath == "/api/v1/client/reviews/rev_1")
        #expect(ReviewsURLProtocol.capturedMethod == "DELETE")
    }
}

private extension URLRequest {
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
