// The rule for where a client's name/avatar leads on a pro screen — the native
// mirror of tovis-app's `lib/profiles/profileHrefs.test.ts`.
//
// The `.none` direction is the load-bearing one and the reason this is a test
// rather than three inline `if`s: a client who never opted into a public profile
// has no public page BY DESIGN, and pushing them anywhere lands on a 404. The
// failure mode is silent — an inert row looks exactly like a correctly-refused
// one — so it has to be asserted rather than eyeballed.
import Testing

@testable import TovisKit

@Suite struct ClientIdentityDestinationTests {
    // MARK: - The gated-id shape (calendar events, booking reads)

    @Test func chartWinsWhenTheProMayOpenIt() {
        #expect(
            ClientIdentityDestination.resolve(
                clientProfileId: "cl_1",
                publicProfileHandle: "ava"
            ) == .chart(clientId: "cl_1")
        )
    }

    // 🔴 The case this whole change exists for. Chart closed + public client used
    // to mean dead text on every pro screen.
    @Test func fallsBackToThePublicProfileWhenTheChartIsClosed() {
        #expect(
            ClientIdentityDestination.resolve(
                clientProfileId: nil,
                publicProfileHandle: "ava"
            ) == .publicProfile(handle: "ava")
        )
    }

    @Test func isNoneWhenTheChartIsClosedAndTheClientIsPrivate() {
        #expect(
            ClientIdentityDestination.resolve(
                clientProfileId: nil,
                publicProfileHandle: nil
            ) == .none
        )
    }

    // A whitespace handle would build `/u/` and land on a page that is not this
    // client's — worse than no link at all.
    @Test func treatsBlankStringsAsAbsent() {
        #expect(
            ClientIdentityDestination.resolve(
                clientProfileId: "   ",
                publicProfileHandle: "  "
            ) == .none
        )
        #expect(
            ClientIdentityDestination.resolve(
                clientProfileId: "  ",
                publicProfileHandle: "ava"
            ) == .publicProfile(handle: "ava")
        )
    }

    @Test func trimsTheValuesItReturns() {
        #expect(
            ClientIdentityDestination.resolve(
                clientProfileId: nil,
                publicProfileHandle: " ava\n"
            ) == .publicProfile(handle: "ava")
        )
    }

    // MARK: - The roster shape (id always present + a canViewClient flag)

    @Test func rosterUsesTheChartOnlyWhenCanViewClient() {
        #expect(
            ClientIdentityDestination.resolve(
                clientId: "cl_1",
                canViewClient: true,
                publicProfileHandle: "ava"
            ) == .chart(clientId: "cl_1")
        )
    }

    // The roster carries the id even for clients it may NOT open, so this is
    // where a call site would most easily leak a chart push.
    @Test func rosterNeverPushesTheChartWhenCanViewClientIsFalse() {
        #expect(
            ClientIdentityDestination.resolve(
                clientId: "cl_1",
                canViewClient: false,
                publicProfileHandle: "ava"
            ) == .publicProfile(handle: "ava")
        )
        #expect(
            ClientIdentityDestination.resolve(
                clientId: "cl_1",
                canViewClient: false,
                publicProfileHandle: nil
            ) == .none
        )
    }

    @Test func rosterAgreesWithTheGatedIdShapeForTheSameFacts() {
        #expect(
            ClientIdentityDestination.resolve(
                clientId: "cl_1",
                canViewClient: false,
                publicProfileHandle: "ava"
            )
                == ClientIdentityDestination.resolve(
                    clientProfileId: nil,
                    publicProfileHandle: "ava"
                )
        )
    }

    // MARK: - isTappable

    // The chevron and the link styling read this. If it disagreed with `resolve`
    // the row would promise a destination the tap then refuses — or hide one it
    // would happily open, which is the bug this shipped to fix.
    @Test func isTappableMatchesWhetherThereIsAnywhereToGo() {
        #expect(ClientIdentityDestination.chart(clientId: "cl_1").isTappable)
        #expect(ClientIdentityDestination.publicProfile(handle: "ava").isTappable)
        #expect(!ClientIdentityDestination.none.isTappable)
    }
}
