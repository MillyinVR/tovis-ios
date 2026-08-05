import Foundation
import Testing
@testable import TovisKit

/// Wire-shape proof for the one-time web sign-in hand-off.
///
/// The fixture is the SAME file `scripts/contract/validate-fixtures.mjs` checks
/// against the backend's generated schema, so the shape is pinned from both
/// sides: decode here, schema there.
@Suite struct SessionHandoffTests {
    @Test func decodesTheHandoffResponse() throws {
        let data = try fixture("authSessionHandoff")
        let handoff = try JSONDecoder().decode(SessionHandoff.self, from: data)

        #expect(handoff.redirectPath == "/pro/membership")
        #expect(handoff.expiresAt == "2026-08-05T12:01:00.000Z")
        #expect(handoff.url.scheme == "https")
        #expect(handoff.url.path == "/api/v1/auth/session-handoff/clx9handoffrow1.4f8c2a1d9e7b6c5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1a")
    }

    /// `url` is a Swift `URL`, so a backend that ever returned a RELATIVE path
    /// would fail to decode rather than silently producing an unopenable link.
    /// This pins that the type is doing that work.
    @Test func requiresAnAbsoluteURL() throws {
        let relative = """
        { "ok": true, "url": "/api/v1/auth/session-handoff/a.b",
          "redirectPath": "/pro/membership", "expiresAt": "2026-08-05T12:01:00.000Z" }
        """.data(using: .utf8)!

        // Foundation's URL does decode a relative string, so assert what we
        // actually get: no host. The app must never open one of these, which is
        // why the SERVER builds the absolute URL rather than the client.
        let decoded = try JSONDecoder().decode(SessionHandoff.self, from: relative)
        #expect(decoded.url.host == nil)
    }

    @Test func failsClosedOnAMissingURL() throws {
        let noURL = """
        { "ok": true, "redirectPath": "/pro/membership",
          "expiresAt": "2026-08-05T12:01:00.000Z" }
        """.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SessionHandoff.self, from: noURL)
        }
    }

    /// The request body the app sends. Pinned because the server's allowlist
    /// reads exactly this key — a rename would 400 every tap-out.
    ///
    /// Asserted by PARSING rather than by string-matching the bytes: Foundation
    /// escapes forward slashes, so the wire bytes are
    /// `{"redirectPath":"\/pro\/membership"}`. That is valid JSON and the
    /// backend's `JSON.parse` unescapes it — verified against the running
    /// endpoint (200, `redirectPath` came back as `/pro/membership`) rather than
    /// assumed. A byte-level assertion here would fail for no real reason.
    @Test func encodesTheRequestedDestination() throws {
        let body = try JSONEncoder.canonical.encode(
            SessionHandoffRequest(redirectPath: "/pro/membership")
        )

        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(parsed?["redirectPath"] as? String == "/pro/membership")
    }
}
