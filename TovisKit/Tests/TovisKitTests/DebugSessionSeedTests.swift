#if DEBUG
import Foundation
import Testing
@testable import TovisKit

/// The debug launch-environment session seed: precedence between the two
/// variables, and the token-shape check that stops a bad paste from wedging the
/// Keychain. Pure input → action, so none of it needs a simulator.
@Suite struct DebugSessionSeedTests {
    /// Shape-valid and deliberately NOT a realistic JWT: `looksLikeJWT` only checks
    /// the shape (three non-empty base64url segments), so a real-looking token buys
    /// no coverage — and a base64url header/payload here trips GitGuardian's secret
    /// scan on the PR. Keep fixtures obviously synthetic.
    private let token = "header.payload.signature"

    @Test func seedsAWellFormedToken() {
        #expect(
            DebugSessionSeed.action(in: ["TOVIS_DEBUG_TOKEN": token]) == .seed(token)
        )
    }

    @Test func trimsSurroundingWhitespace() {
        // A token piped in from a shell almost always arrives with a newline.
        #expect(
            DebugSessionSeed.action(in: ["TOVIS_DEBUG_TOKEN": "  \(token)\n"]) == .seed(token)
        )
    }

    @Test func ignoresAMalformedToken() {
        // Each of these is a real paste/expansion accident. Storing any of them
        // would 401 every request instead of just landing on signed-out.
        for bad in [
            "",
            "   ",
            "not-a-jwt",
            "only.two",
            "four.parts.here.now",
            "..",
            "header..signature",             // empty middle segment
            "pnpm: command not found",       // a failed $(…) substitution
            "header.payload.sig nature",     // a paste that broke across a space
        ] {
            #expect(
                DebugSessionSeed.action(in: ["TOVIS_DEBUG_TOKEN": bad]) == .none,
                "expected \(bad.debugDescription) to be ignored"
            )
        }
    }

    @Test func signsOutOnRequest() {
        for truthy in ["1", "true", "TRUE", "yes", " Yes "] {
            #expect(
                DebugSessionSeed.action(in: ["TOVIS_DEBUG_SIGNOUT": truthy]) == .signOut,
                "expected \(truthy.debugDescription) to be truthy"
            )
        }
        for falsy in ["0", "false", "no", "", "maybe"] {
            #expect(
                DebugSessionSeed.action(in: ["TOVIS_DEBUG_SIGNOUT": falsy]) == .none,
                "expected \(falsy.debugDescription) to be falsy"
            )
        }
    }

    @Test func seedingBeatsSignOut() {
        #expect(
            DebugSessionSeed.action(in: [
                "TOVIS_DEBUG_TOKEN": token,
                "TOVIS_DEBUG_SIGNOUT": "1",
            ]) == .seed(token)
        )
    }

    @Test func signOutWinsOverAMalformedToken() {
        // A bad token is "not asked for", so an explicit sign-out still applies.
        #expect(
            DebugSessionSeed.action(in: [
                "TOVIS_DEBUG_TOKEN": "garbage",
                "TOVIS_DEBUG_SIGNOUT": "1",
            ]) == .signOut
        )
    }

    @Test func anEmptyEnvironmentIsANormalLaunch() {
        #expect(DebugSessionSeed.action(in: [:]) == .none)
        #expect(DebugSessionSeed.action(in: ["PATH": "/usr/bin"]) == .none)
    }
}
#endif
