import Foundation
import Testing
@testable import Tovis

// TovisWebLinks force-unwraps its URL literals, so a typo'd host or path would
// crash on first access rather than fail to compile. These pin the canonical
// production pages that both settings hubs and the signup consent row link to.
@Suite struct TovisWebLinksTests {
    @Test func privacyResolvesToTheCanonicalPage() {
        #expect(TovisWebLinks.privacy.absoluteString == "https://www.tovis.app/privacy")
    }

    @Test func termsResolvesToTheCanonicalPage() {
        #expect(TovisWebLinks.terms.absoluteString == "https://www.tovis.app/terms")
    }
}
