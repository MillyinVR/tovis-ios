import Foundation
import Testing
@testable import TovisKit

// W5 chart consent, CLIENT side:
//   • list    → GET   /client/chart-shares
//   • update  → PATCH /client/chart-shares  { professionalId, action }
//
// This is the surface the whole feature exists for: who can read my chart, and
// how do I take it back. Until it existed on iOS a client could be ASKED (the
// request ships as a push) with nowhere in the app to answer.
//
// 🔴 The timestamp cases below are not padding. Every fixture in
// ProClientChartShareTests omits `requestedAt`, which is exactly why the model
// could type it as `Date?` — against a plain `JSONDecoder()`, whose default
// strategy expects a NUMBER — and still look fine. The field is null until a pro
// asks, so the break only appeared in the one state anybody cares about.

/// Own statics, so this suite can't collide with a sibling suite's mock.
final class ClientChartShareURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }

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

@Suite(.serialized) struct ClientChartSharesServiceTests {
    private func makeService() async -> ClientChartSharesService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientChartShareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.clientchartshare.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ClientChartSharesService(api: api)
    }

    private func reset(status: Int = 200, body: String) {
        ClientChartShareURLProtocol.capturedPath = nil
        ClientChartShareURLProtocol.capturedMethod = nil
        ClientChartShareURLProtocol.capturedBody = nil
        ClientChartShareURLProtocol.status = status
        ClientChartShareURLProtocol.responseBody = Data(body.utf8)
    }

    // MARK: - list

    @Test func listGetsTheSharesRoute() async throws {
        reset(body: #"""
        {"ok":true,"shares":[
          {"professionalId":"pro_1","professionalName":"Ada Studio",
           "avatarUrl":"https://example.test/a.jpg","status":"GRANTED",
           "requestedAt":"2026-08-01T10:00:00.000Z",
           "respondedAt":"2026-08-02T10:00:00.000Z","revokedAt":null}
        ]}
        """#)

        let shares = try await makeService().list()

        #expect(ClientChartShareURLProtocol.capturedPath == "/api/v1/client/chart-shares")
        #expect(ClientChartShareURLProtocol.capturedMethod == "GET")
        #expect(shares.count == 1)
        #expect(shares[0].professionalId == "pro_1")
        #expect(shares[0].professionalName == "Ada Studio")
        #expect(shares[0].status == .granted)
        #expect(shares[0].grantsAccess)
    }

    /// 🔴 The regression case. An ISO-8601 timestamp used to throw and take the
    /// whole list with it — a client with one pending ask saw an error instead
    /// of the ask.
    @Test func anIsoTimestampDoesNotBreakTheList() async throws {
        reset(body: #"""
        {"ok":true,"shares":[
          {"professionalId":"pro_2","professionalName":"Bea Hair","avatarUrl":null,
           "status":"REQUESTED","requestedAt":"2026-08-10T18:30:00.000Z",
           "respondedAt":null,"revokedAt":null}
        ]}
        """#)

        let shares = try await makeService().list()

        #expect(shares.count == 1)
        #expect(shares[0].requestedAt == "2026-08-10T18:30:00.000Z")
        #expect(shares[0].status == .requested)
        // Asked is not allowed.
        #expect(shares[0].grantsAccess == false)
    }

    /// A state this build doesn't know must cost ONE row's label, never the
    /// list. A privacy screen that fails to "blank" reads as "nobody has access".
    @Test func anUnknownStatusKeepsTheRestOfTheList() async throws {
        reset(body: #"""
        {"ok":true,"shares":[
          {"professionalId":"pro_1","professionalName":"Ada","avatarUrl":null,
           "status":"SOMETHING_NEW","requestedAt":null,"respondedAt":null,"revokedAt":null},
          {"professionalId":"pro_2","professionalName":"Bea","avatarUrl":null,
           "status":"GRANTED","requestedAt":null,"respondedAt":null,"revokedAt":null}
        ]}
        """#)

        let shares = try await makeService().list()

        #expect(shares.count == 2)
        #expect(shares[0].status == nil)
        #expect(shares[0].grantsAccess == false)
        #expect(shares[0].statusCopy == "Sharing state unavailable")
        #expect(shares[1].status == .granted)
    }

    @Test func anEmptyListIsNotAnError() async throws {
        reset(body: #"{"ok":true,"shares":[]}"#)
        #expect(try await makeService().list().isEmpty)
    }

    // MARK: - update

    @Test func revokePatchesTheSharesRouteWithTheAction() async throws {
        reset(body: #"{"ok":true,"chartShare":{"professionalId":"pro_1","status":"REVOKED"}}"#)

        let result = try await makeService().update(professionalId: "pro_1", action: .revoke)

        #expect(ClientChartShareURLProtocol.capturedPath == "/api/v1/client/chart-shares")
        #expect(ClientChartShareURLProtocol.capturedMethod == "PATCH")
        #expect(result.status == .revoked)

        let body = String(data: ClientChartShareURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"professionalId\":\"pro_1\""))
        #expect(body.contains("\"action\":\"REVOKE\""))
    }

    @Test func grantAndDeclineSendTheirOwnActions() async throws {
        reset(body: #"{"ok":true,"chartShare":{"professionalId":"pro_1","status":"GRANTED"}}"#)
        _ = try await makeService().update(professionalId: "pro_1", action: .grant)
        var body = String(data: ClientChartShareURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"action\":\"GRANT\""))

        reset(body: #"{"ok":true,"chartShare":{"professionalId":"pro_1","status":"DECLINED"}}"#)
        _ = try await makeService().update(professionalId: "pro_1", action: .decline)
        body = String(data: ClientChartShareURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"action\":\"DECLINE\""))
    }

    @Test func aRefusalSurfacesAsAnError() async throws {
        reset(status: 500, body: #"{"ok":false,"error":"Failed to update chart sharing."}"#)

        await #expect(throws: (any Error).self) {
            _ = try await makeService().update(professionalId: "pro_1", action: .grant)
        }
    }
}

@Suite struct ChartShareStatusTests {
    /// Only GRANTED means someone can read the chart right now.
    @Test func onlyGrantedIsAccess() {
        #expect(ChartShareStatus.granted.grantsAccess)
        for status in [ChartShareStatus.requested, .declined, .revoked] {
            #expect(status.grantsAccess == false)
        }
    }

    /// The client-facing line for each state, mirroring the web settings card's
    /// STATUS_COPY so the two clients describe the same row the same way.
    @Test func namesEveryState() {
        #expect(ChartShareStatus.granted.clientCopy == "Can see your chart")
        #expect(ChartShareStatus.requested.clientCopy == "Asked to see your chart")
        #expect(ChartShareStatus.declined.clientCopy == "You said no")
        #expect(ChartShareStatus.revoked.clientCopy == "You turned this off")
    }

    /// Every case is spoken for — a new state added to the enum without copy
    /// would fail here rather than render an empty line on a privacy screen.
    @Test func everyCaseHasCopy() {
        for status in ChartShareStatus.allCases {
            #expect(status.clientCopy.isEmpty == false)
        }
    }
}
