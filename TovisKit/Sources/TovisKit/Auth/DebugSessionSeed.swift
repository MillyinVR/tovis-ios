#if DEBUG
import Foundation

/// **Debug builds only** — seeds the Keychain session token from the launch
/// environment, so a simulator run can be driven without signing in through the
/// UI.
///
/// ## Why this exists
/// Local sign-in is broken by design, not by bug: `POST /auth/login` looks a user
/// up by `emailHashV2` — a PII-keyring HMAC — so a seeded `client@tovis.app`
/// 401s under a different `PII_LOOKUP_HMAC_KEYS_JSON`, and **resetting the
/// password doesn't help** (the lookup fails before the password compare). Native
/// auth is also bearer-token/Keychain, so the web trick of pasting a cookie can't
/// work either. The result: iOS screens have been shipping build-green and
/// unit-tested but **never visually confirmed**.
///
/// Handing the app a pre-minted JWT sidesteps the broken lookup entirely —
/// `getCurrentUser` accepts any correctly-signed bearer token.
///
/// ## Usage
/// Mint a token against the LOCAL dev DB (from `~/Dev/tovis-app`):
/// ```
/// pnpm dev:mint-jwt                      # client@tovis.app
/// pnpm dev:mint-jwt --email pro@tovis.app
/// ```
/// Then launch the simulator with it. `simctl` forwards any `SIMCTL_CHILD_*`
/// variable to the app with the prefix stripped:
/// ```
/// SIMCTL_CHILD_TOVIS_DEBUG_TOKEN="$(cd ~/Dev/tovis-app && pnpm -s dev:mint-jwt)" \
///   xcrun simctl launch booted app.tovis.Tovis
/// ```
/// `tovis-ios/scripts/sim-login.sh` does the whole loop (mint → build → install →
/// launch). In Xcode, set `TOVIS_DEBUG_TOKEN` under Scheme → Run → Arguments →
/// Environment Variables instead.
///
/// Set `TOVIS_DEBUG_SIGNOUT=1` to clear the stored token and land on signed-out.
/// Seeding takes precedence: passing both signs you in.
///
/// ## Safety
/// The whole file is `#if DEBUG`, so it does not exist in Release builds
/// (TestFlight / App Store) — there is no runtime flag to flip, and no way to
/// reach it from a shipped binary. The token minter refuses to run against
/// anything but a local database, so a token that reaches here can only ever
/// address local dev data.
public enum DebugSessionSeed {
    /// A pre-minted session JWT to store in the Keychain before bootstrap.
    public static let tokenEnvKey = "TOVIS_DEBUG_TOKEN"
    /// Set to `1`/`true`/`yes` to clear the stored token instead.
    public static let signOutEnvKey = "TOVIS_DEBUG_SIGNOUT"

    /// What the launch environment is asking for.
    public enum Action: Equatable, Sendable {
        /// Store this token, then bootstrap as normal.
        case seed(String)
        /// Clear any stored token (land on signed-out).
        case signOut
        /// Nothing asked for — a normal launch.
        case none
    }

    /// Resolve the launch environment into an action. Pure, so the precedence and
    /// the token-shape rules are unit-testable rather than trapped in app code.
    ///
    /// A malformed `TOVIS_DEBUG_TOKEN` resolves to `.none` rather than being
    /// stored: writing garbage to the Keychain would produce confusing 401s on
    /// every request instead of an obvious "you're signed out".
    public static func action(in environment: [String: String]) -> Action {
        if let raw = environment[tokenEnvKey] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeJWT(token) { return .seed(token) }
            // Deliberately falls through: an empty or malformed token is treated
            // as "not asked for", so a stale/blank shell variable can't wedge a
            // launch. An explicit sign-out below still wins over a bad token.
        }

        if isTruthy(environment[signOutEnvKey]) { return .signOut }
        return .none
    }

    /// Three non-empty, dot-separated segments. Deliberately a *shape* check, not
    /// a verification — the app can't validate a signature it has no secret for,
    /// and the backend is the real authority. This only catches fat-finger input
    /// (a shell variable that expanded to an error message, a truncated paste).
    static func looksLikeJWT(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy(isBase64URLCharacter)
        }
    }

    private static func isBase64URLCharacter(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
            || character.isNumber && character.isASCII
            || character == "-" || character == "_" || character == "="
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return ["1", "true", "yes"].contains(value)
    }
}
#endif
