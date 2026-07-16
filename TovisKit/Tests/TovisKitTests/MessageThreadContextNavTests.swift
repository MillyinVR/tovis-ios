import Foundation
import Testing
@testable import TovisKit

// Proves the thread-header context-navigation rules ported from web's thread
// header (app/messages/thread/[id]/page.tsx): which contexts get a link, where
// it points, and when the pro's client-chart jump shows.
//
// Threads are decoded from inline JSON rather than the shared fixture:
// `MessageThread` is Decodable with no memberwise init, and each case here needs
// a different contextType/bookingId combination than the one fixture carries.

@Suite struct MessageThreadContextNavTests {
    /// Decode a thread with the context fields under test; everything else is
    /// filler the rules never read.
    private func makeThread(
        contextType: String?,
        bookingId: String?,
        isViewerPro: Bool = false
    ) throws -> MessageThread {
        let contextTypeJSON = contextType.map { "\"\($0)\"" } ?? "null"
        let bookingIdJSON = bookingId.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": "thr_1",
          "contextType": \(contextTypeJSON),
          "bookingId": \(bookingIdJSON),
          "lastMessageAt": "2026-07-16T18:30:00.000Z",
          "lastMessagePreview": "See you at 2!",
          "updatedAt": "2026-07-16T18:30:00.000Z",
          "client": { "id": "cli_1", "firstName": "Amara", "lastName": "Reyes", "avatarUrl": null },
          "professional": { "id": "pro_1", "businessName": "Plume Studio", "avatarUrl": null },
          "participants": [{ "lastReadAt": null }],
          "isViewerPro": \(isViewerPro),
          "eyebrow": "BOOKING CONFIRMED — Balayage — Sat 2:30 PM",
          "isAccentContext": true
        }
        """
        return try JSONDecoder().decode(MessageThread.self, from: Data(json.utf8))
    }

    // MARK: - contextDestination

    @Test func bookingContextLinksToItsBooking() throws {
        let thread = try makeThread(contextType: "BOOKING", bookingId: "bk_1")
        #expect(thread.contextDestination == .booking(id: "bk_1"))
    }

    @Test func proProfileContextLinksToTheThreadsPro() throws {
        // Web uses the thread's contextId, which for PRO_PROFILE is the pro's id;
        // the modeled professional.id is that same pro.
        let thread = try makeThread(contextType: "PRO_PROFILE", bookingId: nil)
        #expect(thread.contextDestination == .proProfile(id: "pro_1"))
    }

    @Test func contextsWebGivesNoLinkGetNone() throws {
        for contextType in ["SERVICE", "OFFERING", "WAITLIST"] {
            let thread = try makeThread(contextType: contextType, bookingId: nil)
            #expect(thread.contextDestination == nil, "\(contextType) should have no link")
        }
    }

    /// Web requires `contextType === BOOKING && bookingId` — a BOOKING thread whose
    /// optional bookingId pointer was nulled (the FK is `onDelete: SetNull`) has
    /// nowhere to go, so it must not render a link to nothing.
    @Test func bookingContextWithoutABookingIdGetsNoLink() throws {
        #expect(try makeThread(contextType: "BOOKING", bookingId: nil).contextDestination == nil)
        #expect(try makeThread(contextType: "BOOKING", bookingId: "").contextDestination == nil)
    }

    /// A context type this build doesn't know (server-added) degrades to no link
    /// rather than guessing a destination.
    @Test func unknownOrAbsentContextTypeGetsNoLink() throws {
        #expect(try makeThread(contextType: "SOMETHING_NEW", bookingId: "bk_1").contextDestination == nil)
        #expect(try makeThread(contextType: nil, bookingId: "bk_1").contextDestination == nil)
    }

    // MARK: - showsClientChartLink

    @Test func onlyTheThreadsProGetsTheClientChartJump() throws {
        let asPro = try makeThread(contextType: "BOOKING", bookingId: "bk_1", isViewerPro: true)
        let asClient = try makeThread(contextType: "BOOKING", bookingId: "bk_1", isViewerPro: false)
        #expect(asPro.showsClientChartLink)
        #expect(asClient.showsClientChartLink == false)
    }

    /// The chart jump is independent of the context — web renders it from the
    /// viewer's role alone, alongside whatever context link the thread has.
    @Test func theClientChartJumpDoesNotDependOnContext() throws {
        for contextType in ["BOOKING", "PRO_PROFILE", "SERVICE", "WAITLIST"] {
            let thread = try makeThread(contextType: contextType, bookingId: nil, isViewerPro: true)
            #expect(thread.showsClientChartLink, "\(contextType) should still offer the chart")
        }
    }
}
