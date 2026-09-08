import Foundation
import Testing
@testable import TovisKit

@Suite struct FounderDecodingTests {
    @Test func portalUsesOnlyTheRoomsReturnedByTheServer() throws {
        let response = try JSONDecoder().decode(
            FounderPortalResponse.self,
            from: fixture("founderPortal")
        )

        #expect(response.portal.rooms.map(\.key) == [.proAll, .proBarber])
        #expect(response.portal.rooms.count == 2)
        #expect(response.portal.rooms.first?.unreadCount == 4)
    }

    @Test func decodesCategorizedFounderMessages() throws {
        let response = try JSONDecoder().decode(
            FounderMessagesResponse.self,
            from: fixture("founderMessages")
        )

        #expect(response.room.key == .proBarber)
        #expect(response.messages.first?.kind == .question)
        #expect(response.messages.first?.author.displayName == "Northside Barber")
        #expect(response.hasMore == false)
    }
}
