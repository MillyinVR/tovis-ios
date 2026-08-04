import Foundation
import Testing
@testable import TovisKit

// Proves the self-serve account-deletion surface hits the right routes and
// reads the envelope the web endpoint actually returns:
//   • status()          → GET    /me/account-deletion → { accountDeletion }
//   • requestDeletion() → POST   /me/account-deletion → { request }
//   • cancel()          → DELETE /me/account-deletion
//
// The blockers matter most: their `message` is the SERVER's copy and is what
// the screen renders verbatim, so a decode that dropped it would leave the user
// staring at an empty "before you can delete" box with no idea what to fix.

/// Records the outgoing request and serves a canned envelope.
final class AccountDeletionURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.accountDeletionBodyStreamData()

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
    func accountDeletionBodyStreamData() -> Data? {
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

@Suite(.serialized) struct AccountDeletionServiceTests {
    private func makeService() async -> AccountDeletionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountDeletionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.accountdeletion.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return AccountDeletionService(api: api)
    }

    private func reset() {
        AccountDeletionURLProtocol.capturedPath = nil
        AccountDeletionURLProtocol.capturedMethod = nil
        AccountDeletionURLProtocol.capturedBody = nil
        AccountDeletionURLProtocol.status = 200
        AccountDeletionURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    @Test func statusReadsEligibilityAndGracePeriod() async throws {
        reset()
        AccountDeletionURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "accountDeletion": {
            "gracePeriodDays": 14,
            "eligibility": { "eligible": true, "blockers": [] },
            "pendingRequest": null
          }
        }
        """.utf8)

        let service = await makeService()
        let status = try await service.status()

        #expect(AccountDeletionURLProtocol.capturedPath == "/api/v1/me/account-deletion")
        #expect(AccountDeletionURLProtocol.capturedMethod == "GET")
        #expect(status.gracePeriodDays == 14)
        #expect(status.eligibility.eligible == true)
        #expect(status.pendingRequest == nil)
    }

    @Test func statusKeepsEveryBlockerMessageVerbatim() async throws {
        reset()
        // The server sends `count` too; the DTO ignores it. What must survive is
        // the message, because that is the entire content of the screen's
        // "before you can delete" list.
        AccountDeletionURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "accountDeletion": {
            "gracePeriodDays": 14,
            "eligibility": {
              "eligible": false,
              "blockers": [
                { "code": "UPCOMING_BOOKINGS_AS_PRO",
                  "message": "You have 2 upcoming client appointments. Cancel or complete them first — deleting your account will not tell your clients.",
                  "count": 2 },
                { "code": "DEPOSIT_HELD",
                  "message": "A deposit is still being held on 1 appointment.",
                  "count": 1 }
              ]
            },
            "pendingRequest": null
          }
        }
        """.utf8)

        let service = await makeService()
        let status = try await service.status()

        #expect(status.eligibility.eligible == false)
        #expect(status.eligibility.blockers.count == 2)
        #expect(status.eligibility.blockers[0].code == "UPCOMING_BOOKINGS_AS_PRO")
        #expect(
            status.eligibility.blockers[0].message
                == "You have 2 upcoming client appointments. Cancel or complete them first — deleting your account will not tell your clients."
        )
        #expect(status.eligibility.blockers[1].code == "DEPOSIT_HELD")
    }

    @Test func statusReadsAScheduledDeletion() async throws {
        reset()
        AccountDeletionURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "accountDeletion": {
            "gracePeriodDays": 14,
            "eligibility": { "eligible": true, "blockers": [] },
            "pendingRequest": {
              "id": "adr_1",
              "status": "PENDING",
              "requestedAt": "2026-08-04T23:11:34.313Z",
              "scheduledFor": "2026-08-18T23:11:34.313Z"
            }
          }
        }
        """.utf8)

        let service = await makeService()
        let status = try await service.status()
        let pending = try #require(status.pendingRequest)

        #expect(pending.id == "adr_1")
        #expect(pending.status == "PENDING")
        // The screen formats this with Wire.dateOnly — prove the raw instant
        // survives decoding in a shape that formatter accepts.
        #expect(pending.scheduledFor == "2026-08-18T23:11:34.313Z")
        #expect(Wire.dateOnly(pending.scheduledFor, timeZone: "UTC") == "Aug 18, 2026")
    }

    @Test func requestDeletionPostsTheTypedConfirmation() async throws {
        reset()
        AccountDeletionURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "request": {
            "id": "adr_2",
            "status": "PENDING",
            "requestedAt": "2026-08-04T23:11:34.313Z",
            "scheduledFor": "2026-08-18T23:11:34.313Z"
          }
        }
        """.utf8)

        let service = await makeService()
        let created = try await service.requestDeletion(confirmEmail: "me@example.com")

        #expect(AccountDeletionURLProtocol.capturedPath == "/api/v1/me/account-deletion")
        #expect(AccountDeletionURLProtocol.capturedMethod == "POST")
        #expect(created.id == "adr_2")

        let body = try #require(AccountDeletionURLProtocol.capturedBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        // The server compares this against the account email. Sending the wrong
        // key would make deletion impossible for everyone.
        #expect(json["confirmEmail"] as? String == "me@example.com")
    }

    @Test func blockedRequestSurfacesTheServerMessage() async throws {
        reset()
        AccountDeletionURLProtocol.status = 409
        AccountDeletionURLProtocol.responseBody = Data("""
        {
          "ok": false,
          "error": "Your account still has things to settle first.",
          "code": "BLOCKED"
        }
        """.utf8)

        let service = await makeService()

        await #expect(throws: APIError.self) {
            _ = try await service.requestDeletion(confirmEmail: "me@example.com")
        }

        do {
            _ = try await service.requestDeletion(confirmEmail: "me@example.com")
            Issue.record("expected the blocked request to throw")
        } catch let error as APIError {
            // Rendered straight to the user — a generic string here would strip
            // the only explanation they get.
            #expect(error.userMessage == "Your account still has things to settle first.")
            if case let .server(status, _, code) = error {
                #expect(status == 409)
                #expect(code == "BLOCKED")
            } else {
                Issue.record("expected APIError.server, got \(error)")
            }
        }
    }

    @Test func cancelUsesDelete() async throws {
        reset()
        let service = await makeService()
        try await service.cancel()

        #expect(AccountDeletionURLProtocol.capturedPath == "/api/v1/me/account-deletion")
        #expect(AccountDeletionURLProtocol.capturedMethod == "DELETE")
    }
}
