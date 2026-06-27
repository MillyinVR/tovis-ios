import SwiftUI
import TovisKit

/// App-level auth state. Owns the single `TovisClient` and drives which screen
/// the root shows. Inject it into the SwiftUI environment from the `@main` App.
@MainActor
@Observable
final class SessionModel {
    enum State: Equatable {
        case loading      // checking the Keychain at launch
        case signedOut
        case signedIn
    }

    private(set) var state: State = .loading
    private(set) var currentUser: AuthUser?
    var isWorking = false
    var errorMessage: String?

    let client: TovisClient

    init(config: TovisConfig) {
        self.client = TovisClient(config: config)
    }

    /// Call once on launch (e.g. `.task` on the root view).
    func bootstrap() async {
        state = await client.auth.hasSession() ? .signedIn : .signedOut
    }

    func login(email: String, password: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.login(
                email: email,
                password: password,
                deviceId: client.deviceId
            )
            currentUser = result.user
            state = .signedIn
            // After sign-in you'd register for push and call DeviceService.register(...).
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    func logout() async {
        await client.auth.logout()
        currentUser = nil
        state = .signedOut
    }
}