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
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedContentType: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
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
        BoardsURLProtocol.capturedQuery = nil
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

    // MARK: - updateEventDate(...)

    @Test func updateEventDatePatchesYmd() async throws {
        reset()
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_1","clientId":"cl_1","name":"Big day","slug":"big-day","visibility":"PRIVATE","type":"BRIDAL","eventDate":"2026-09-01","itemCount":0,"items":[]}}
        """.utf8)

        let board = try await makeService().updateEventDate(id: "bd_1", eventDate: "2026-09-01")

        #expect(BoardsURLProtocol.capturedPath == "/api/v1/boards/bd_1")
        #expect(BoardsURLProtocol.capturedMethod == "PATCH")
        #expect(BoardsURLProtocol.capturedContentType == "application/json")

        let body = try bodyJSON()
        #expect(body["eventDate"] as? String == "2026-09-01")
        #expect(body.count == 1) // ONLY eventDate is sent
        #expect(board.eventDate == "2026-09-01")
    }

    @Test func updateEventDateSendsExplicitNullToClear() async throws {
        reset()
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"id":"bd_1","clientId":"cl_1","name":"Big day","slug":"big-day","visibility":"PRIVATE","type":"BRIDAL","eventDate":null,"itemCount":0,"items":[]}}
        """.utf8)

        let board = try await makeService().updateEventDate(id: "bd_1", eventDate: nil)

        let body = try bodyJSON()
        // The clear MUST be an explicit JSON null. The synthesized encoder would
        // have omitted the key (`encodeIfPresent`), and PATCH /boards/{id} reads
        // an absent key as "nothing to update" → 400, silently never clearing.
        #expect(body.keys.contains("eventDate") == true)
        #expect(body["eventDate"] is NSNull)
        #expect(body.count == 1)
        #expect(board.eventDate == nil)
    }

    // MARK: - recommendations(...)

    @Test func recommendationsGetsBoardFeedAndDecodes() async throws {
        reset()
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"nextCursor":null,"viewerContext":{"isAuthenticated":true},"items":[
          {"id":"lk_1","url":"https://cdn/full.jpg","thumbUrl":"https://cdn/thumb.jpg","mediaType":"IMAGE","caption":"Soft updo","createdAt":"2026-07-01T00:00:00.000Z","_count":{"likes":3,"comments":1},"viewerLiked":false,"viewerSaved":false,"viewerFollows":false},
          {"id":"lk_2","url":"https://cdn/clip.mp4","thumbUrl":null,"mediaType":"VIDEO","caption":null,"createdAt":"2026-07-02T00:00:00.000Z","_count":{"likes":0,"comments":0},"viewerLiked":false,"viewerSaved":false,"viewerFollows":false}
        ]}
        """.utf8)

        let items = try await makeService().recommendations(id: "bd_1")

        #expect(BoardsURLProtocol.capturedPath == "/api/v1/boards/bd_1/feed")
        #expect(BoardsURLProtocol.capturedQuery == "limit=12")
        #expect(BoardsURLProtocol.capturedMethod == "GET")

        #expect(items.count == 2)
        #expect(items.first?.id == "lk_1")
        #expect(items.first?.thumbUrl == "https://cdn/thumb.jpg")
        #expect(items.first?.isVideo == false)
        // A video recommendation decodes too — the tile falls back to the full URL
        // when there's no thumb, and opens the viewer in video mode.
        #expect(items.last?.isVideo == true)
        #expect(items.last?.thumbUrl == nil)
        #expect(items.last?.caption == nil)
    }

    @Test func recommendationsDecodesEmptyFeed() async throws {
        reset()
        BoardsURLProtocol.responseBody = Data("""
        {"ok":true,"items":[],"nextCursor":null,"viewerContext":{"isAuthenticated":true}}
        """.utf8)

        #expect(try await makeService().recommendations(id: "bd_new").isEmpty)
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

    @Test func catalogEventNounsMatchWeb() {
        // BOARD_EVENT_NOUNS — what the countdown counts down TO.
        #expect(BoardCatalog.eventNoun(for: "BRIDAL") == "your wedding")
        #expect(BoardCatalog.eventNoun(for: "PROM") == "prom")
        #expect(BoardCatalog.eventNoun(for: "bridal") == "your wedding")
        #expect(BoardCatalog.eventNoun(for: "GENERAL") == nil)
        #expect(BoardCatalog.eventNoun(for: "NOT_A_TYPE") == nil)

        // boardTypeWantsEventDate — and it must agree with the noun map exactly,
        // or a dated type would render "the big day" instead of its own noun.
        #expect(BoardCatalog.wantsEventDate(for: "BRIDAL") == true)
        #expect(BoardCatalog.wantsEventDate(for: "prom") == true)
        #expect(BoardCatalog.wantsEventDate(for: "GENERAL") == false)
        #expect(BoardCatalog.wantsEventDate(for: "NOT_A_TYPE") == false)
        for type in BoardCatalog.types {
            #expect(type.wantsEventDate == (BoardCatalog.eventNoun(for: type.value) != nil))
        }
    }
}

// MARK: - Event date + countdown

/// The `BoardEventCountdown` port: the calendar math behind "42 days until your
/// wedding" and the card's three copy states. An event date is a CALENDAR date
/// with no timezone on the wire, so every case pins an explicit calendar.
@Suite struct BoardEventDateTests {
    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 8pm on 2026-06-05 in Los Angeles — i.e. already 2026-06-**06** in UTC.
    private func juneFifthEveningLA(_ la: Calendar) throws -> Date {
        try #require(la.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 20)))
    }

    @Test func ymdUsesTheViewersCalendarNotUTC() throws {
        let la = try calendar("America/Los_Angeles")
        let evening = try juneFifthEveningLA(la)

        // A DatePicker set to "June 5" hands back an instant carrying the CURRENT
        // time of day. Read in the viewer's calendar it is June 5 — which is the
        // date they picked, and the only thing `<input type="date">` would send.
        #expect(BoardEventDate.ymd(from: evening, calendar: la) == "2026-06-05")

        // Pinned deliberately: reading that same instant in UTC yields the NEXT
        // day. That was the create flow's bug — a UTC formatter silently shifted
        // every evening pick west of UTC by a day, so the board counted down to
        // the wrong date.
        #expect(BoardEventDate.ymd(from: evening, calendar: try calendar("UTC")) == "2026-06-06")
    }

    @Test func ymdRoundTripsThroughTheParser() throws {
        let la = try calendar("America/Los_Angeles")
        let parsed = try #require(BoardEventDate.date(fromYmd: "2026-06-05", calendar: la))
        #expect(BoardEventDate.ymd(from: parsed, calendar: la) == "2026-06-05")
        // Parsing lands on local midnight — the picker opens on the stored day.
        #expect(la.dateComponents([.hour, .minute], from: parsed).hour == 0)
    }

    @Test func parserRejectsMalformedAndImpossibleDates() throws {
        let la = try calendar("America/Los_Angeles")
        #expect(BoardEventDate.date(fromYmd: "", calendar: la) == nil)
        #expect(BoardEventDate.date(fromYmd: "nope", calendar: la) == nil)
        // Not zero-padded / not a bare calendar date.
        #expect(BoardEventDate.date(fromYmd: "2026-6-05", calendar: la) == nil)
        #expect(BoardEventDate.date(fromYmd: "2026-06-05T00:00:00Z", calendar: la) == nil)
        // Impossible — a Calendar would happily ROLL this to March 2, so the
        // components are read back and compared (mirrors parseBoardEventDateYmd).
        #expect(BoardEventDate.date(fromYmd: "2026-02-30", calendar: la) == nil)
        #expect(BoardEventDate.date(fromYmd: "2026-13-01", calendar: la) == nil)
        // A real leap day still parses.
        #expect(BoardEventDate.date(fromYmd: "2028-02-29", calendar: la) != nil)
    }

    @Test func daysUntilCountsWholeCalendarDays() throws {
        let la = try calendar("America/Los_Angeles")
        let now = try juneFifthEveningLA(la)

        func days(_ ymd: String) -> Int? {
            BoardEventDate.daysUntil(eventYmd: ymd, from: now, calendar: la)
        }

        #expect(days("2026-06-05") == 0)    // today, despite it being 8pm
        #expect(days("2026-06-06") == 1)
        #expect(days("2026-07-17") == 42)
        #expect(days("2026-06-04") == -1)   // passed
        #expect(days("garbage") == nil)
    }

    @Test func daysUntilIsUnskewedByDST() throws {
        let la = try calendar("America/Los_Angeles")
        // 2026-11-01 is a 25-hour day in Los Angeles (DST ends). Counting in hours
        // rather than calendar days would land 2 days off-by-one here.
        let beforeFallBack = try #require(
            la.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23))
        )
        #expect(
            BoardEventDate.daysUntil(
                eventYmd: "2026-11-02", from: beforeFallBack, calendar: la
            ) == 2
        )
    }

    @Test func countdownCopyMatchesTheWebCard() throws {
        let la = try calendar("America/Los_Angeles")
        let now = try juneFifthEveningLA(la)

        func state(_ type: String, _ eventDate: String?) -> BoardEventCountdownState? {
            BoardEventCountdownState.resolve(
                type: type, eventDate: eventDate, now: now, calendar: la
            )
        }

        #expect(state("BRIDAL", "2026-07-17") == .countdown("42 days until your wedding"))
        #expect(state("BRIDAL", "2026-06-06") == .countdown("1 day until your wedding"))
        #expect(state("BRIDAL", "2026-06-05") == .countdown("Today’s the day — it’s your wedding!"))
        #expect(state("BRIDAL", "2026-06-04") == .passed("Hope your wedding was everything you wanted."))
        #expect(state("BRIDAL", nil) == .prompt(
            "Add the date of your wedding to get a countdown and better timing."
        ))
        #expect(state("PROM", "2026-06-06") == .countdown("1 day until prom"))
        #expect(state("prom", "2026-06-05") == .countdown("Today’s the day — it’s prom!"))

        // Only the live countdown is the emphasized payoff line.
        #expect(state("BRIDAL", "2026-07-17")?.isEmphasized == true)
        #expect(state("BRIDAL", "2026-06-04")?.isEmphasized == false)
        #expect(state("BRIDAL", nil)?.isEmphasized == false)
    }

    @Test func countdownHiddenForTypesWithoutAnEventDate() throws {
        let la = try calendar("America/Los_Angeles")
        let now = try juneFifthEveningLA(la)

        func state(_ type: String, _ eventDate: String?) -> BoardEventCountdownState? {
            BoardEventCountdownState.resolve(
                type: type, eventDate: eventDate, now: now, calendar: la
            )
        }

        // nil → the card renders nothing at all, for every undated type…
        #expect(state("GENERAL", nil) == nil)
        #expect(state("NAILS", nil) == nil)
        #expect(state("NOT_A_TYPE", nil) == nil)
        // …even if a date somehow rode along on one.
        #expect(state("GENERAL", "2026-06-06") == nil)
    }

    @Test func boardExposesItsOwnCountdown() throws {
        let la = try calendar("America/Los_Angeles")
        let now = try juneFifthEveningLA(la)
        let board = try JSONDecoder().decode(Board.self, from: Data("""
        {"id":"bd_1","clientId":"cl_1","name":"Big day","slug":"big-day","visibility":"PRIVATE","type":"BRIDAL","eventDate":"2026-07-17","itemCount":0,"items":[]}
        """.utf8))

        #expect(board.eventCountdown(now: now, calendar: la)
            == .countdown("42 days until your wedding"))
    }
}
