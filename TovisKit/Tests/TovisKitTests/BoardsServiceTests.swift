import Foundation
import Testing
@testable import TovisKit

// Proves the client Boards surface hits the right routes with the right bodies:
//   • detail(id:)                    → GET   /boards/{id}   → { board }
//   • create(name:visibility:type:…) → POST  /boards        → { board } (201)
//   • updateVisibility(id:isShared:) → PATCH /boards/{id}    → { board }
// Plus the BoardCatalog port (board-type values/labels/event-date) stays in step
// with lib/boards/context.ts.

/// Records the outgoing request and serves a canned envelope.
final class BoardsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedContentType: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
        Self.capturedBody = request.httpBody ?? request.boardsBodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func boardsBodyStreamData() -> Data? {
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

@Suite(.serialized) struct BoardsServiceTests {
    private func makeService() async -> BoardsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoardsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.boards.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return BoardsService(api: api)
    }

    private func reset() {
        BoardsURLProtocol.capturedPath = nil
        BoardsURLProtocol.capturedMethod = nil
        BoardsURLProtocol.capturedContentType = nil
        BoardsURLProtocol.capturedBody = nil
        BoardsURLProtocol.status = 200
        BoardsURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let data = try #require(BoardsURLProtocol.capturedBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: - detail(id:)

    @Test func detailGetsAndDecodes() async throws {
        reset()
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_1","clientId":"cl_1","name":"Spring hair","slug":"spring-hair","visibility":"SHARED","type":"BRIDAL","eventDate":"2026-09-01","itemCount":2,"items":[
          {"id":"bi_1","createdAt":"2026-07-01T00:00:00.000Z","lookPostId":"lp_1","lookPost":{"id":"lp_1","caption":"Balayage","status":"PUBLISHED","visibility":"PUBLIC","moderationStatus":"APPROVED","publishedAt":"2026-06-01T00:00:00.000Z","primaryMedia":{"id":"m_1","url":"https://cdn/full.jpg","thumbUrl":"https://cdn/thumb.jpg","mediaType":"IMAGE"}}},
          {"id":"bi_2","createdAt":"2026-07-02T00:00:00.000Z","lookPostId":"lp_2","lookPost":null}
        ]}}
        """.utf8)

        let board = try await makeService().detail(id: "bd_1")

        #expect(BoardsURLProtocol.capturedPath == "/api/v1/boards/bd_1")
        #expect(BoardsURLProtocol.capturedMethod == "GET")

        #expect(board.id == "bd_1")
        #expect(board.name == "Spring hair")
        #expect(board.slug == "spring-hair")
        #expect(board.visibility == "SHARED")
        #expect(board.isShared == true)
        #expect(board.type == "BRIDAL")
        #expect(board.eventDate == "2026-09-01")
        #expect(board.itemCount == 2)
        #expect(board.items.count == 2)
        // Thumb is preferred over the full URL for the grid tile.
        #expect(board.items.first?.imageUrl == "https://cdn/thumb.jpg")
        #expect(board.items.first?.caption == "Balayage")
        #expect(board.items.first?.lookPostId == "lp_1")
        // A missing lookPost yields no image + no caption (falls back to board name in UI).
        #expect(board.items.last?.imageUrl == nil)
        #expect(board.items.last?.caption == nil)
    }

    @Test func detailThrowsOnForbidden() async throws {
        reset()
        BoardsURLProtocol.status = 403
        BoardsURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Not allowed to manage this board.\"}".utf8)

        do {
            _ = try await makeService().detail(id: "bd_other")
            Issue.record("expected detail(id:) to throw on a 403")
        } catch let error as APIError {
            guard case let .server(status, _, _) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 403)
        }
    }

    // MARK: - create(...)

    @Test func createPostsBodyAndDecodes() async throws {
        reset()
        BoardsURLProtocol.status = 201
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_new","clientId":"cl_1","name":"Prom 26","slug":"prom-26","visibility":"PRIVATE","type":"PROM","eventDate":"2026-05-01","itemCount":0,"items":[]}}
        """.utf8)

        let board = try await makeService().create(
            name: "Prom 26",
            visibility: "PRIVATE",
            type: "PROM",
            eventDate: "2026-05-01"
        )

        #expect(BoardsURLProtocol.capturedPath == "/api/v1/boards")
        #expect(BoardsURLProtocol.capturedMethod == "POST")
        #expect(BoardsURLProtocol.capturedContentType == "application/json")

        let body = try bodyJSON()
        #expect(body["name"] as? String == "Prom 26")
        #expect(body["visibility"] as? String == "PRIVATE")
        #expect(body["type"] as? String == "PROM")
        #expect(body["eventDate"] as? String == "2026-05-01")

        #expect(board.id == "bd_new")
        #expect(board.itemCount == 0)
        #expect(board.items.isEmpty)
    }

    @Test func createOmitsEventDateWhenNil() async throws {
        reset()
        BoardsURLProtocol.status = 201
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_gen","clientId":"cl_1","name":"Collecting","slug":"collecting","visibility":"PRIVATE","type":"GENERAL","eventDate":null,"itemCount":0,"items":[]}}
        """.utf8)

        _ = try await makeService().create(
            name: "Collecting",
            visibility: "PRIVATE",
            type: "GENERAL",
            eventDate: nil
        )

        let body = try bodyJSON()
        #expect(body["name"] as? String == "Collecting")
        #expect(body["type"] as? String == "GENERAL")
        // A nil event date must be omitted (not sent as JSON null) so an undated
        // board is created rather than the key being interpreted downstream.
        #expect(body["eventDate"] == nil)
        #expect(body.keys.contains("eventDate") == false)
        // No chip answers / no opt-in → both keys omitted (text-only body identical).
        #expect(body.keys.contains("answers") == false)
        #expect(body.keys.contains("writeThroughSelfProfile") == false)
    }

    @Test func createSendsAnswersAndWriteThrough() async throws {
        reset()
        BoardsURLProtocol.status = 201
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_sk","clientId":"cl_1","name":"Glow","slug":"glow","visibility":"PRIVATE","type":"SKINCARE","eventDate":null,"itemCount":0,"items":[]}}
        """.utf8)

        _ = try await makeService().create(
            name: "Glow",
            visibility: "PRIVATE",
            type: "SKINCARE",
            answers: ["skin_type": "oily", "main_concern": "acne"],
            writeThroughSelfProfile: true
        )

        let body = try bodyJSON()
        let answers = try #require(body["answers"] as? [String: Any])
        #expect(answers["skin_type"] as? String == "oily")
        #expect(answers["main_concern"] as? String == "acne")
        // The backend keys on `=== true`, so it must be a real JSON boolean.
        #expect(body["writeThroughSelfProfile"] as? Bool == true)
    }

    @Test func createOmitsWriteThroughWhenFalseButKeepsAnswers() async throws {
        reset()
        BoardsURLProtocol.status = 201
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_na","clientId":"cl_1","name":"Mani","slug":"mani","visibility":"PRIVATE","type":"NAILS","eventDate":null,"itemCount":0,"items":[]}}
        """.utf8)

        _ = try await makeService().create(
            name: "Mani",
            visibility: "PRIVATE",
            type: "NAILS",
            answers: ["length_preference": "short"],
            writeThroughSelfProfile: false
        )

        let body = try bodyJSON()
        #expect((body["answers"] as? [String: Any])?["length_preference"] as? String == "short")
        // Not opted in → the key is omitted (never sent as false).
        #expect(body.keys.contains("writeThroughSelfProfile") == false)
    }

    // MARK: - updateVisibility(...)

    @Test func updateVisibilityPatchesAndDecodes() async throws {
        reset()
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_1","clientId":"cl_1","name":"Spring hair","slug":"spring-hair","visibility":"SHARED","type":"GENERAL","eventDate":null,"itemCount":0,"items":[]}}
        """.utf8)

        let board = try await makeService().updateVisibility(id: "bd_1", isShared: true)

        #expect(BoardsURLProtocol.capturedPath == "/api/v1/boards/bd_1")
        #expect(BoardsURLProtocol.capturedMethod == "PATCH")
        #expect(BoardsURLProtocol.capturedContentType == "application/json")

        let body = try bodyJSON()
        #expect(body["visibility"] as? String == "SHARED")
        #expect(body.count == 1) // ONLY visibility is sent

        #expect(board.isShared == true)
    }

    @Test func updateVisibilitySendsPrivate() async throws {
        reset()
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_1","clientId":"cl_1","name":"Spring hair","slug":"spring-hair","visibility":"PRIVATE","type":"GENERAL","eventDate":null,"itemCount":0,"items":[]}}
        """.utf8)

        let board = try await makeService().updateVisibility(id: "bd_1", isShared: false)

        let body = try bodyJSON()
        #expect(body["visibility"] as? String == "PRIVATE")
        #expect(board.isShared == false)
    }

    // MARK: - BoardCatalog parity

    @Test func catalogMatchesWebTypeSetAndLabels() {
        #expect(BoardCatalog.types.count == 7)
        #expect(BoardCatalog.types.map(\.value) == [
            "GENERAL", "BRIDAL", "PROM", "SKINCARE",
            "PERMANENT_MAKEUP", "COLOR_TRANSFORMATION", "NAILS",
        ])
        #expect(BoardCatalog.label(for: "GENERAL") == "Just collecting")
        #expect(BoardCatalog.label(for: "BRIDAL") == "Wedding")
        #expect(BoardCatalog.label(for: "COLOR_TRANSFORMATION") == "Color / transformation")
        // Case-insensitive + unknown handling.
        #expect(BoardCatalog.label(for: "general") == "Just collecting")
        #expect(BoardCatalog.label(for: "NOT_A_TYPE") == nil)
    }

    @Test func catalogEventDateTypes() {
        func wants(_ value: String) -> Bool {
            BoardCatalog.types.first { $0.value == value }?.wantsEventDate ?? false
        }
        #expect(wants("BRIDAL") == true)
        #expect(wants("PROM") == true)
        #expect(wants("GENERAL") == false)
        #expect(wants("NAILS") == false)
        #expect(wants("SKINCARE") == false)
    }

    @Test func catalogQuestionSetsMatchWeb() {
        // GENERAL (and unknown types) carry no chip questions.
        #expect(BoardCatalog.questions(for: "GENERAL").isEmpty)
        #expect(BoardCatalog.questions(for: "NOT_A_TYPE").isEmpty)
        // Case-insensitive lookup.
        #expect(BoardCatalog.questions(for: "bridal").map(\.key) == ["hair_length", "trial_timeline"])

        // PROM leads with dress color; hair_length is shared with BRIDAL.
        let prom = BoardCatalog.questions(for: "PROM")
        #expect(prom.map(\.key) == ["dress_color", "hair_length"])
        #expect(prom.first?.options.map(\.value) == [
            "red", "pink", "blue", "green", "black", "white", "metallic", "undecided",
        ])

        // PERMANENT_MAKEUP has three questions; confidence_topic values must match
        // the web exactly (server validates on VALUE).
        let pmu = BoardCatalog.questions(for: "PERMANENT_MAKEUP")
        #expect(pmu.map(\.key) == ["had_it_before", "confidence_topic", "brow_situation"])
        #expect(pmu[1].options.map(\.value) == [
            "healing-process", "pain-level", "natural-look", "cost",
        ])

        // The person-describing keys that gate the self-profile write-through.
        #expect(BoardCatalog.writeThroughAnswerKeys == [
            "hair_length", "current_color", "skin_type", "main_concern",
        ])
    }
}
