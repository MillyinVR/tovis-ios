import Foundation
import Testing
@testable import TovisKit

// Pins the wire contract of the person block (App Store guideline 1.2).
//
// Every response body below is a VERBATIM capture from the real running route
// (tovis-app #969, driven against a local dev server on 2026-08-20) — not
// hand-written JSON. The sibling `ProFollowServiceTests` exists because a
// plausible-looking DELETE 405'd against a route that only had GET and POST,
// and it built and typechecked the whole way. So the METHOD and PATH are
// asserted here too, not just the decode.
//
// ⚠️ These DTOs are deliberately absent from `scripts/contract/validate-fixtures.mjs`
// — the backend keeps them out of `lib/dto/index.ts` so neither repo's CI
// blocks the other. See `Models/Blocks.swift`.

/// Its own static storage so it never races the other suites' mocks.
final class BlocksURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)
    nonisolated(unsafe) static var responseStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        // URLProtocol strips httpBody into a stream, so read it back out.
        Self.capturedBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let size = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: Self.responseStatus, httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct BlocksServiceTests {

    private func makeService() async -> BlocksService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlocksURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.blocks.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return BlocksService(api: api)
    }

    private func reset(_ body: String, status: Int = 200) {
        BlocksURLProtocol.capturedPath = nil
        BlocksURLProtocol.capturedMethod = nil
        BlocksURLProtocol.capturedBody = nil
        BlocksURLProtocol.responseBody = Data(body.utf8)
        BlocksURLProtocol.responseStatus = status
    }

    private func capturedJSON() throws -> [String: String] {
        let data = try #require(BlocksURLProtocol.capturedBody)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    // MARK: - Block

    /// Verbatim capture: POST /api/v1/blocks {"professionalId":"demoseed-pro-noor"}
    @Test func blocksAProfessionalById() async throws {
        reset(#"{"ok":true,"blockId":"cmt0xx4nv0001powcje7ixhjm","handle":"demo-noor","displayName":"Noor Haddad","blocked":true}"#)
        let service = await makeService()

        let created = try await service.block(.professional(id: "demoseed-pro-noor"))

        #expect(BlocksURLProtocol.capturedMethod == "POST")
        #expect(BlocksURLProtocol.capturedPath == "/api/v1/blocks")
        // 🔴 A pro is targeted by ProfessionalProfile id, never by handle: a
        // pro's handle is nullable, and the feed DTO's `professional.id` is NOT
        // a User id. Sending the wrong key 404s TARGET_NOT_FOUND.
        #expect(try capturedJSON() == ["professionalId": "demoseed-pro-noor"])
        #expect(created.blockId == "cmt0xx4nv0001powcje7ixhjm")
        #expect(created.displayName == "Noor Haddad")
        #expect(created.blocked)
    }

    @Test func blocksAClientAuthorByHandle() async throws {
        reset(#"{"ok":true,"blockId":"blk_1","handle":"maya-reyes","displayName":"@maya-reyes","blocked":true}"#)
        let service = await makeService()

        _ = try await service.block(.handle("maya-reyes"))

        #expect(try capturedJSON() == ["handle": "maya-reyes"])
    }

    /// A re-block returns the EXISTING row id rather than erroring, so the
    /// caller can always render Unblock afterwards.
    @Test func reBlockIsIdempotentAndStillYieldsTheRowId() async throws {
        reset(#"{"ok":true,"blockId":"cmt0xx4nv0001powcje7ixhjm","handle":"demo-noor","displayName":"Noor Haddad","blocked":true}"#)
        let service = await makeService()

        let again = try await service.block(.professional(id: "demoseed-pro-noor"))

        #expect(again.blockId == "cmt0xx4nv0001powcje7ixhjm")
    }

    // MARK: - Unblock

    /// Verbatim capture: DELETE /api/v1/blocks/{blockId}
    @Test func unblockDeletesByRowIdNotByHandle() async throws {
        reset(#"{"ok":true,"blockId":"cmt0xx4nv0001powcje7ixhjm","blocked":false}"#)
        let service = await makeService()

        let removed = try await service.unblock(blockId: "cmt0xx4nv0001powcje7ixhjm")

        #expect(BlocksURLProtocol.capturedMethod == "DELETE")
        // 🔴 Keyed on the BLOCK ROW, not the target: a blocked account can clear
        // its handle afterwards, and a block that cannot be lifted is worse than
        // the harassment it was meant to stop.
        #expect(BlocksURLProtocol.capturedPath == "/api/v1/blocks/cmt0xx4nv0001powcje7ixhjm")
        #expect(removed.blocked == false)
    }

    // MARK: - List

    /// Verbatim capture: GET /api/v1/blocks
    @Test func listsBlockedAccounts() async throws {
        reset(#"{"ok":true,"blocks":[{"blockId":"cmt0xx4nv0001powcje7ixhjm","handle":"demo-noor","displayName":"Noor Haddad","avatarUrl":"http://localhost:3000/seed-demo/lived-in-blonde.jpg"}]}"#)
        let service = await makeService()

        let blocks = try await service.blockedAccounts()

        #expect(BlocksURLProtocol.capturedMethod == "GET")
        #expect(BlocksURLProtocol.capturedPath == "/api/v1/blocks")
        #expect(blocks.count == 1)
        #expect(blocks[0].displayName == "Noor Haddad")
        // The wire carries no User id, and must not start to.
        #expect(blocks[0].blockId == "cmt0xx4nv0001powcje7ixhjm")
    }

    @Test func emptyListDecodes() async throws {
        reset(#"{"ok":true,"blocks":[]}"#)
        let service = await makeService()
        #expect(try await service.blockedAccounts().isEmpty)
    }

    /// A blocked account that later clears its handle still lists, so the block
    /// stays liftable — the label falls back rather than the row vanishing.
    @Test func handleLabelIsSuppressedWhenItWouldRepeatTheDisplayName() {
        let clientAuthor = BlockedAccount(
            blockId: "b1", handle: "maya-reyes",
            displayName: "@maya-reyes", avatarUrl: nil
        )
        #expect(clientAuthor.handleLabel == nil)

        let pro = BlockedAccount(
            blockId: "b2", handle: "demo-noor",
            displayName: "Noor Haddad", avatarUrl: nil
        )
        #expect(pro.handleLabel == "@demo-noor")

        let handleless = BlockedAccount(
            blockId: "b3", handle: "",
            displayName: "Blocked account", avatarUrl: nil
        )
        #expect(handleless.handleLabel == nil)
    }
}
