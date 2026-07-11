import Foundation
import Testing
@testable import TovisKit

// Proves the pro migration wizard's read service hits the right route and decodes
// the summary the two "bookend" screens (entry progress + review/go-live) render.
// The native read side of the web `/pro/migrate` flow's RSC-only entry + review
// pages:
//   • summary() → GET /api/v1/pro/migrate/summary (decodes counts + raises;
//                 derives the entry progress + review labels)
//   • 404 while ENABLE_PRO_MIGRATION is off → APIError.server(404) (build-dark),
//                 which the screen turns into a "not available yet" state.

/// Records the outgoing request and serves a canned envelope.
final class MigrationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedNativeHeader = request.value(forHTTPHeaderField: "x-tovis-native")

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

@Suite(.serialized) struct ProMigrationTests {
    private func makeService() async -> ProMigrationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MigrationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.migration.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProMigrationService(api: api)
    }

    private func reset() {
        MigrationURLProtocol.capturedPath = nil
        MigrationURLProtocol.capturedMethod = nil
        MigrationURLProtocol.capturedAuthHeader = nil
        MigrationURLProtocol.capturedNativeHeader = nil
        MigrationURLProtocol.status = 200
        MigrationURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    @Test func summaryGetsMigrateRouteAndDecodesCountsAndRaises() async throws {
        reset()
        MigrationURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "summary": {
            "offerings": 12,
            "clients": 34,
            "importedBookings": 8,
            "importedBlocks": 3,
            "raises": [
              {
                "serviceName": "Gel X",
                "from": 45,
                "to": 60,
                "stepMode": "PCT",
                "stepValue": 10,
                "cadenceWeeks": 10
              },
              {
                "serviceName": "Balayage",
                "from": 120,
                "to": 150,
                "stepMode": "USD",
                "stepValue": 15,
                "cadenceWeeks": 8
              }
            ]
          }
        }
        """.utf8)

        let summary = try await makeService().summary()

        #expect(MigrationURLProtocol.capturedPath == "/api/v1/pro/migrate/summary")
        #expect(MigrationURLProtocol.capturedMethod == "GET")
        #expect(MigrationURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(MigrationURLProtocol.capturedNativeHeader == "ios")

        // Raw counts.
        #expect(summary.offerings == 12)
        #expect(summary.clients == 34)
        #expect(summary.importedBookings == 8)
        #expect(summary.importedBlocks == 3)

        // Entry-screen derived progress (matches web: calendar = bookings + blocks).
        #expect(summary.servicesCount == 12)
        #expect(summary.clientsCount == 34)
        #expect(summary.calendarCount == 11)
        #expect(summary.hasAnyImport == true)

        // Raises decode + derive labels (mirrors web buildReviewViewModel).
        #expect(summary.raises.count == 2)
        let pct = try #require(summary.raises.first)
        #expect(pct.serviceName == "Gel X")
        #expect(pct.fromLabel == "$45")
        #expect(pct.toLabel == "$60")
        #expect(pct.cadenceLabel == "10% / 10 wks")
        let usd = summary.raises[1]
        #expect(usd.cadenceLabel == "$15 / 8 wks")
    }

    @Test func summaryThrowsServer404WhenFlagOff() async throws {
        reset()
        MigrationURLProtocol.status = 404
        MigrationURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Not found\"}".utf8)

        await #expect(throws: APIError.self) {
            _ = try await makeService().summary()
        }

        do {
            _ = try await makeService().summary()
            Issue.record("expected a 404 to throw")
        } catch let error as APIError {
            guard case .server(404, _, _) = error else {
                Issue.record("expected APIError.server(404), got \(error)")
                return
            }
        }
    }

    @Test func hasAnyImportFalseForAnEmptyMigration() async throws {
        reset()
        MigrationURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "summary": {
            "offerings": 0, "clients": 0, "importedBookings": 0,
            "importedBlocks": 0, "raises": []
          }
        }
        """.utf8)

        let summary = try await makeService().summary()

        #expect(summary.calendarCount == 0)
        #expect(summary.hasAnyImport == false)
        #expect(summary.raises.isEmpty)
    }
}
