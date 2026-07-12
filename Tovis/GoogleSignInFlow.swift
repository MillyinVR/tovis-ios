import Foundation
import GoogleSignIn

/// Runs the interactive Google Sign-In and hands back the OIDC id-token for
/// `POST /api/v1/auth/google`.
///
/// This lives in the app target — not TovisKit — because the Google Sign-In SDK
/// is UI (it presents a web-auth sheet). Keeping heavy UI SDKs off the
/// dependency-free TovisKit package is the same rule Stripe follows: the network
/// call sits behind a plain `AuthService` method, and only the SDK-driven UI step
/// is up here. See the SPM-dependency recipe (memory: ios-first-remote-spm-dependency).
enum GoogleSignInFlow {
    enum FlowError: Error {
        case noPresenter
        case missingIdToken
    }

    /// Present the Google account picker and return the resulting id-token.
    ///
    /// - `clientID` is the **iOS** OAuth client id the SDK runs the flow with.
    /// - `serverClientID` is the **web** OAuth client id; Google stamps it as the
    ///   id-token's `aud`, so the backend verifier (pinned to that same id in
    ///   `lib/auth/googleIdentity.ts`) accepts the token.
    ///
    /// Throws `GIDSignInError.canceled` when the user backs out of the sheet —
    /// callers treat that as a silent no-op.
    @MainActor
    static func idToken(clientID: String, serverClientID: String) async throws -> String {
        guard let presenter = UIApplication.topPresentedViewController() else {
            throw FlowError.noPresenter
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw FlowError.missingIdToken
        }
        return idToken
    }
}
