import Foundation
import Testing
@testable import TovisKit

// Purchasing is web-only (Apple IAP), so the app has to hand a pro off to the
// hosted site. The web origin is DERIVED from baseURL rather than configured
// separately, so a local build can never open the production site — or worse, a
// TestFlight build open localhost.
@Suite struct TovisConfigWebURLTests {
    @Test func stripsTheApiPathFromTheProductionBase() {
        let config = TovisConfig(baseURL: URL(string: "https://www.tovis.app/api/v1")!)
        #expect(config.webBaseURL.absoluteString == "https://www.tovis.app")
        #expect(
            config.webPageURL("/pro/membership").absoluteString
                == "https://www.tovis.app/pro/membership"
        )
    }

    // 🔴 The reason this is derived. A dev build must open the dev site.
    @Test func keepsThePortForALocalBuild() {
        let config = TovisConfig(baseURL: URL(string: "http://localhost:3000/api/v1")!)
        #expect(
            config.webPageURL("/pro/membership").absoluteString
                == "http://localhost:3000/pro/membership"
        )
    }

    @Test func toleratesAPathWithoutALeadingSlash() {
        let config = TovisConfig(baseURL: URL(string: "https://www.tovis.app/api/v1")!)
        #expect(
            config.webPageURL("pro/membership").absoluteString
                == "https://www.tovis.app/pro/membership"
        )
    }

    @Test func anEmptyPathFallsBackToTheOrigin() {
        let config = TovisConfig(baseURL: URL(string: "https://www.tovis.app/api/v1")!)
        #expect(config.webPageURL("").absoluteString == "https://www.tovis.app")
    }
}
