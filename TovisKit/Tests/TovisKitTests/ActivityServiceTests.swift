import Foundation
import Testing

@testable import TovisKit

// Covers the client activity feed: the wire decode (pinned to a VERBATIM capture
// of a real `GET /api/v1/client/activity` response, not a hand-written mock — a
// mock written from the same assumption as the reader proves nothing about the
// wire), the follow-back rule, and the relative-time port of web's
// `formatRelativeTimeAgo`.

private final class ActivityURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// The service serves `Fixtures/clientActivity.json` — a VERBATIM capture of a real
// `GET /api/v1/client/activity` response (pnpm dev, 2026-07-17). It is the single
// source of wire truth: decoded here AND schema-validated by
// scripts/contract/validate-fixtures.mjs, so a backend DTO change fails loudly in
// one of the two rather than silently at runtime. Re-capture it; never hand-edit a
// shape into it — a mock written from the same assumption as the reader agrees with
// itself and with nothing else.

@Suite(.serialized)
struct ActivityServiceTests {
    private func makeAPI() async -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityURLProtocol.self]
        let tokenStore = TokenStore(service: "me.tovis.app.session.activity.tests")
        await tokenStore.save("session.token.value")
        return APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: URLSession(configuration: configuration),
            tokenStore: tokenStore
        )
    }

    private func loadFeed() async throws -> ClientActivityFeed {
        ActivityURLProtocol.body = try fixture("clientActivity")
        ActivityURLProtocol.status = 200
        return try await ActivityService(api: await makeAPI()).feed()
    }

    /// Address rows by id, not index — the server's ordering is its own business.
    private func row(_ id: String, in feed: ClientActivityFeed) throws -> ClientActivityItem {
        try #require(feed.items.first { $0.id == id })
    }

    @Test("decodes a verbatim /client/activity capture")
    func decodesCapture() async throws {
        let feed = try await loadFeed()

        #expect(ActivityURLProtocol.capturedPath == "/api/v1/client/activity")
        #expect(ActivityURLProtocol.capturedMethod == "GET")
        #expect(feed.items.count == 8)
        #expect(feed.unreadCount == 4)
        // The allowlist is server-owned — the app must not hard-code it.
        #expect(feed.markReadEventKeys.count == 7)
        #expect(feed.markReadEventKeys.contains("LOOK_MILESTONE_REACHED"))
        // Every kind the fixture carries resolves — no row fell back to .unknown.
        #expect(feed.items.allSatisfy { $0.iconKind != .unknown })
    }

    @Test("models a publicly-addressable follower's follow-back")
    func decodesFollowBack() async throws {
        let feed = try await loadFeed()
        let publicFollow = try row("seed_act_1", in: feed)

        #expect(publicFollow.iconKind == .follow)
        #expect(publicFollow.who == "@ava")
        #expect(publicFollow.followBack == ActivityFollowBack(handle: "ava", alreadyFollowing: false))
        #expect(publicFollow.offersFollowBack)
        #expect(publicFollow.destination == .publicClient(handle: "ava"))
    }

    @Test("a private follower carries no follow-back and no link")
    func decodesPrivateFollower() async throws {
        let feed = try await loadFeed()
        let privateFollow = try row("seed_act_2", in: feed)

        // The server renders a non-public follower generically; there is nobody
        // to follow back and nowhere to go.
        #expect(privateFollow.who == "Someone")
        #expect(privateFollow.followBack == nil)
        #expect(privateFollow.href == nil)
        #expect(privateFollow.offersFollowBack == false)
        #expect(privateFollow.destination == nil)
    }

    @Test("server-composed copy rides the wire verbatim")
    func decodesComposedCopy() async throws {
        let feed = try await loadFeed()

        // Batched engagement counts people/saves server-side — the client must
        // not recompute the plural.
        let batchedLikes = try row("seed_act_5", in: feed)
        #expect(batchedLikes.who == "4 people")
        #expect(batchedLikes.action == "liked your look")

        let batchedSaves = try row("seed_act_6", in: feed)
        #expect(batchedSaves.who == "3 saves")
        #expect(batchedSaves.action == "on your look")

        let milestone = try row("seed_act_8", in: feed)
        #expect(milestone.iconKind == .milestone)
        #expect(milestone.who == "Your look")
        #expect(milestone.action == "hit 50 likes")

        // The comment snippet arrives already quoted.
        let comment = try row("seed_act_3", in: feed)
        #expect(comment.highlight == "\u{201C}Obsessed with this colour!\u{201D}")
        #expect(comment.destination == .look(id: "cmrbry49q005zpo0dfdcsrjy2"))
    }
}

@Suite
struct ActivityIconKindTests {
    @Test("decodes every published kind, including the not-yet-emitted ones")
    func decodesPublishedKinds() throws {
        // remix/featured are in the wire union but no backend event produces them
        // yet — they must still decode, so shipping the events needs no release.
        let pairs: [(String, ActivityIconKind)] = [
            ("follow", .follow), ("comment", .comment), ("like", .like),
            ("save", .save), ("new-look", .newLook), ("remix", .remix),
            ("featured", .featured), ("milestone", .milestone),
        ]
        for (raw, expected) in pairs {
            let decoded = try JSONDecoder().decode(
                ActivityIconKind.self, from: Data("\"\(raw)\"".utf8)
            )
            #expect(decoded == expected)
        }
    }

    @Test("an unknown kind degrades instead of failing the row")
    func decodesUnknownKind() throws {
        // A future server kind must not fail the whole row's decode — the rest of
        // the row (who/action/timestamp) is still perfectly renderable.
        let decoded = try JSONDecoder().decode(
            ActivityIconKind.self, from: Data("\"supernova\"".utf8)
        )
        #expect(decoded == .unknown)
    }

    @Test("a row with an unknown kind still decodes whole")
    func decodesRowWithUnknownKind() throws {
        let json = """
        {"id":"n1","iconKind":"supernova","who":"@ava","action":"did something new",
         "highlight":null,"timestamp":"2026-07-17T07:46:07.279Z","unread":true,
         "href":null,"followBack":null}
        """
        let item = try JSONDecoder().decode(ClientActivityItem.self, from: Data(json.utf8))
        #expect(item.iconKind == .unknown)
        #expect(item.who == "@ava")
        #expect(item.action == "did something new")
    }
}

@Suite
struct ActivityRowPatchTests {
    private func followRow(alreadyFollowing: Bool = false, unread: Bool = true) -> ClientActivityItem {
        ClientActivityItem(
            id: "n1", iconKind: .follow, who: "@ava", action: "started following you",
            timestamp: "2026-07-17T07:46:07.279Z", unread: unread, href: "/u/ava",
            followBack: ActivityFollowBack(handle: "ava", alreadyFollowing: alreadyFollowing)
        )
    }

    @Test("marking read clears only the unread flag")
    func markingReadKeepsEverythingElse() {
        let read = followRow().markingRead()
        #expect(read.unread == false)
        // A read row keeps its follow-back and its link — web only drops the dot.
        #expect(read.offersFollowBack)
        #expect(read.href == "/u/ava")
        #expect(read.who == "@ava")
    }

    @Test("a follower the viewer already follows is offered View, not Follow")
    func alreadyFollowingOffersNoButton() {
        // `offersFollowBack` governs only the INITIAL render. Once shown, the
        // button owns its state and stays a toggle (as web's does), so a mis-tap
        // stays undoable; a reopened feed re-reads this from the server.
        let row = followRow(alreadyFollowing: true)
        #expect(row.offersFollowBack == false)
        #expect(row.destination == .publicClient(handle: "ava"))
    }
}

@Suite
struct ActivityDestinationTests {
    private func item(href: String?) -> ClientActivityItem {
        ClientActivityItem(
            id: "n1", iconKind: .like, who: "@ava", action: "liked your look",
            timestamp: "2026-07-17T07:46:07.279Z", unread: false, href: href
        )
    }

    @Test("routes a look href to the look detail")
    func routesLook() {
        #expect(item(href: "/looks/look_123").destination == .look(id: "look_123"))
    }

    @Test("routes a public-profile href to the client viewer")
    func routesPublicClient() {
        #expect(item(href: "/u/ava").destination == .publicClient(handle: "ava"))
    }

    @Test("does NOT resolve a tag chip as a look")
    func rejectsTagPath() {
        // The trap: a loose parser reads `/looks/tags/balayage` as
        // .look(id: "tags") and opens a detail for a look that cannot exist.
        // PushDeepLink shipped exactly this bug, invisible only because the id
        // was discarded. No affordance beats a dead tap.
        #expect(item(href: "/looks/tags/balayage").destination == nil)
    }

    @Test("no href, or a path native cannot route, offers nothing")
    func rejectsUnroutable() {
        #expect(item(href: nil).destination == nil)
        #expect(item(href: "").destination == nil)
        #expect(item(href: "/").destination == nil)
        #expect(item(href: "/looks").destination == nil)
        #expect(item(href: "/u").destination == nil)
        #expect(item(href: "/client/boards/xyz").destination == nil)
    }
}

@Suite
struct ActivityTimeAgoTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func label(secondsAgo: TimeInterval) -> String {
        ActivityTimeAgo.label(
            for: now.addingTimeInterval(-secondsAgo),
            now: now,
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
    }

    @Test("matches web's formatRelativeTimeAgo buckets")
    func matchesWebBuckets() {
        #expect(label(secondsAgo: 0) == "just now")
        #expect(label(secondsAgo: 59) == "just now")
        #expect(label(secondsAgo: 60) == "1m ago")
        #expect(label(secondsAgo: 5 * 60) == "5m ago")
        #expect(label(secondsAgo: 59 * 60) == "59m ago")
        #expect(label(secondsAgo: 60 * 60) == "1h ago")
        #expect(label(secondsAgo: 3 * 3600) == "3h ago")
        #expect(label(secondsAgo: 23 * 3600) == "23h ago")
        #expect(label(secondsAgo: 24 * 3600) == "1d ago")
        #expect(label(secondsAgo: 6 * 86400) == "6d ago")
        #expect(label(secondsAgo: 7 * 86400) == "1w ago")
        #expect(label(secondsAgo: 27 * 86400) == "3w ago")
        #expect(label(secondsAgo: 34 * 86400) == "4w ago")
    }

    @Test("falls back to a short date past the 5-week cap")
    func fallsBackToDate() {
        // weekCap 5 on web: 5w+ renders month/day instead of "5w ago".
        #expect(label(secondsAgo: 35 * 86400) != "5w ago")
        #expect(label(secondsAgo: 35 * 86400).isEmpty == false)
        #expect(label(secondsAgo: 400 * 86400).contains("ago") == false)
    }

    @Test("a future timestamp clamps to just now rather than going negative")
    func clampsFuture() {
        // Web does Math.max(0, Date.now() - then); a clock skew must not render
        // "-3m ago".
        #expect(label(secondsAgo: -600) == "just now")
    }

    @Test("unparseable input renders empty, like web")
    func unparseableIsEmpty() {
        #expect(ActivityTimeAgo.label(for: "not-a-date", now: now).isEmpty)
        #expect(ActivityTimeAgo.label(for: "", now: now).isEmpty)
    }

    @Test("parses the wire's fractional-second ISO instants")
    func parsesWireTimestamps() {
        // The capture's exact format — a parser that only accepts whole seconds
        // would render every row's time as "".
        let label = ActivityTimeAgo.label(
            for: "2026-07-17T07:46:07.279Z",
            now: Date(timeIntervalSince1970: 1_784_275_567 + 3600)
        )
        #expect(label.isEmpty == false)
    }
}
