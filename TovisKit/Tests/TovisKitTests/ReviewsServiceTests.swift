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

    // MARK: - Photos (§5 A3-rev 4b)

    @Test func submitWithPhotosCarriesAttachmentsAndFreshUploads() async throws {
        reset(Self.reviewOk)

        _ = try await makeService().submitReview(
            bookingId: "bkg_1", rating: 5, headline: "Loved it", body: "",
            attachedMediaIds: ["sess_2", "sess_1"],
            uploadSessionIds: ["us_9"])
        let keyWithPhotos = ReviewsURLProtocol.capturedIdempotencyKey

        let body = try #require(ReviewsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["attachedMediaIds"] as? [String] == ["sess_2", "sess_1"])
        let media = try #require(json["media"] as? [[String: Any]])
        #expect(media.count == 1)
        #expect(media.first?["uploadSessionId"] as? String == "us_9")

        // A text-only submit of the same rating/text omits the photo keys, so it
        // mints a DIFFERENT idempotency key (the nonce folds the photos in).
        reset(Self.reviewOk)
        _ = try await makeService().submitReview(
            bookingId: "bkg_1", rating: 5, headline: "Loved it", body: "")
        let textOnlyBody = try #require(ReviewsURLProtocol.capturedBody)
        let textJson = try #require(try JSONSerialization.jsonObject(with: textOnlyBody) as? [String: Any])
        #expect(textJson["attachedMediaIds"] == nil)
        #expect(textJson["media"] == nil)
        #expect(keyWithPhotos != ReviewsURLProtocol.capturedIdempotencyKey)
    }

    @Test func reviewMediaOptionsFetchesAndDecodes() async throws {
        reset("""
        {"ok":true,"items":[
          {"id":"m_1","url":"https://cdn/b.jpg","thumbUrl":"https://cdn/b-t.jpg","mediaType":"IMAGE","createdAt":"2026-07-03T10:00:00.000Z","phase":"BEFORE"},
          {"id":"m_2","url":"https://cdn/a.mp4","thumbUrl":null,"mediaType":"VIDEO","createdAt":"2026-07-03T09:00:00.000Z","phase":"AFTER"}
        ]}
        """)

        let items = try await makeService().reviewMediaOptions(bookingId: "bkg_1")

        #expect(ReviewsURLProtocol.capturedPath == "/api/v1/client/bookings/bkg_1/review-media-options")
        #expect(ReviewsURLProtocol.capturedMethod == "GET")
        #expect(items.count == 2)
        #expect(items.first?.id == "m_1")
        #expect(items.first?.isVideo == false)
        #expect(items.first?.phase == .before)
        // A video option with no thumb falls back to the full URL for the tile.
        #expect(items.last?.isVideo == true)
        #expect(items.last?.displayThumbUrl == "https://cdn/a.mp4")
    }

    @Test func attachReviewMediaPostsUploadSessionIds() async throws {
        reset("""
        {"ok":true,"createdCount":1,"created":[],"review":null}
        """)

        try await makeService().attachReviewMedia(reviewId: "rev_1", uploadSessionIds: ["us_1", "us_2"])

        #expect(ReviewsURLProtocol.capturedPath == "/api/v1/client/reviews/rev_1/media")
        #expect(ReviewsURLProtocol.capturedMethod == "POST")
        let body = try #require(ReviewsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let media = try #require(json["media"] as? [[String: Any]])
        #expect(media.map { $0["uploadSessionId"] as? String } == ["us_1", "us_2"])
    }

    @Test func attachReviewMediaSkipsEmpty() async throws {
        reset("{\"ok\":true}")

        try await makeService().attachReviewMedia(reviewId: "rev_1", uploadSessionIds: [])

        // No request issued for an empty attach.
        #expect(ReviewsURLProtocol.capturedPath == nil)
    }

    @Test func removeReviewMediaSendsDelete() async throws {
        reset("{\"ok\":true}")

        try await makeService().removeReviewMedia(reviewId: "rev_1", mediaId: "media_9")

        #expect(ReviewsURLProtocol.capturedPath == "/api/v1/client/reviews/rev_1/media/media_9")
        #expect(ReviewsURLProtocol.capturedMethod == "DELETE")
    }

    @Test func uploadReviewPhotoPresignsWithReviewPublicKind() async throws {
        // The presign is captured on the api session; the signed PUT then runs on
        // the service's internal (unmocked) session and fails on missing creds —
        // which is enough to assert the presign request shape.
        reset("""
        {"ok":true,"bucket":"media-public","path":"p/x.jpg","token":"tok","signedUrl":null,"publicUrl":null,"isPublic":true,"uploadSessionId":"us_new"}
        """)

        var threw = false
        do {
            _ = try await makeService().uploadReviewPhoto(imageData: Data([0x1, 0x2, 0x3]))
        } catch {
            threw = true
        }
        #expect(threw)

        #expect(ReviewsURLProtocol.capturedPath == "/api/v1/client/uploads")
        #expect(ReviewsURLProtocol.capturedMethod == "POST")
        let body = try #require(ReviewsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["kind"] as? String == "REVIEW_PUBLIC")
        #expect(json["contentType"] as? String == "image/jpeg")
        #expect(json["size"] as? Int == 3)
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
