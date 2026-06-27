import Foundation
import Testing
@testable import TovisKit

// Verifies our Swift models decode the EXACT JSON the backend emits.
// The fixtures below are the real /api/v1 wire shapes (lib/dto/auth.ts).

@Suite struct DecodingTests {
    @Test func decodesLoginResponse() throws {
        let json = """
        {
          "ok": true,
          "user": { "id": "usr_1", "email": "a@b.com", "role": "CLIENT" },
          "token": "jwt.abc.def",
          "nextUrl": "/client",
          "isPhoneVerified": true,
          "isEmailVerified": false,
          "isFullyVerified": false
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(LoginResponse.self, from: json)
        #expect(res.token == "jwt.abc.def")
        #expect(res.user.role == .client)
        #expect(res.isFullyVerified == false)
        #expect(res.nextUrl == "/client")
    }

    @Test func unknownRoleFallsBack() throws {
        let json = #"{ "id": "x", "email": "e", "role": "WIZARD" }"#.data(using: .utf8)!
        let user = try JSONDecoder().decode(AuthUser.self, from: json)
        #expect(user.role == .unknown)
    }

    @Test func decodesRefreshResponse() throws {
        let json = #"{ "token": "new.jwt" }"#.data(using: .utf8)!
        let res = try JSONDecoder().decode(RefreshResponse.self, from: json)
        #expect(res.token == "new.jwt")
    }

    @Test func decodesErrorBody() throws {
        let json = #"{ "ok": false, "error": "Invalid email or password", "code": "INVALID_CREDENTIALS" }"#.data(using: .utf8)!
        let body = try JSONDecoder().decode(APIErrorBody.self, from: json)
        #expect(body.error == "Invalid email or password")
        #expect(body.code == "INVALID_CREDENTIALS")
    }
}