import Foundation
import Testing
@testable import TovisKit

// The claim screen's state machine — the port of web's `ClaimPageState` plus the
// sub-branches web nests inside its `ready` state (app/claim/[token]/page.tsx).
//
// These live on the model precisely so they are reachable: `swift test` is the
// real gate for this repo (there is no CI), and the app target has essentially no
// view tests — a rule left in a SwiftUI view would be untestable.

@Suite struct ClaimScreenStateTests {
    // MARK: - Viewer branches (no outcome yet)

    @Test func signedOutViewerIsOfferedSignup() {
        #expect(
            ClaimScreenState.resolve(contextState: ClaimContextState.ready, viewer: .signedOut)
                == .signedOut
        )
    }

    @Test func signedInClientIsOfferedTheInAppClaim() {
        // The whole point of the step: a signed-in client no longer bounces to
        // signup, which is all this screen used to do.
        #expect(
            ClaimScreenState.resolve(contextState: ClaimContextState.ready, viewer: .client)
                == .readyToClaim
        )
    }

    @Test func unverifiedClientMustVerifyFirst() {
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .needsVerification
            ) == .needsVerification
        )
    }

    @Test func professionalCannotClaim() {
        #expect(
            ClaimScreenState.resolve(contextState: ClaimContextState.ready, viewer: .professional)
                == .notAClient
        )
    }

    // MARK: - Link state short-circuits the viewer (mirrors web's precedence)

    @Test func revokedLinkShortCircuitsEveryViewer() {
        for viewer in [ClaimViewer.signedOut, .client, .needsVerification, .professional] {
            #expect(
                ClaimScreenState.resolve(contextState: ClaimContextState.revoked, viewer: viewer)
                    == .revoked
            )
        }
    }

    @Test func alreadyClaimedLinkShortCircuitsEveryViewer() {
        for viewer in [ClaimViewer.signedOut, .client, .needsVerification, .professional] {
            #expect(
                ClaimScreenState.resolve(
                    contextState: ClaimContextState.alreadyClaimed,
                    viewer: viewer
                ) == .alreadyClaimed
            )
        }
    }

    @Test func unknownContextStateFallsBackToTheViewerBranch() {
        // A state the client doesn't know must not black-hole the screen: fall
        // back to the viewer rather than render nothing.
        #expect(
            ClaimScreenState.resolve(contextState: "some_future_state", viewer: .client)
                == .readyToClaim
        )
    }

    // MARK: - The outcome is authoritative once it exists

    @Test func successRendersTheClaimedState() {
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .claimed(bookingId: "bk_1")
            ) == .claimed(bookingId: "bk_1")
        )
    }

    @Test func booklessSuccessCarriesNoBooking() {
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .claimed(bookingId: nil)
            ) == .claimed(bookingId: nil)
        )
    }

    @Test func mismatchIsOnlyKnowableFromTheOutcome() {
        // Native reads the claim over the PUBLIC, unauthenticated GET, which does
        // not expose the invite's client id — so unlike web it cannot pre-empt a
        // mismatch. The accept POST is what answers it.
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .clientMismatch
            ) == .clientMismatch
        )
    }

    @Test func aRefusedMergeRendersItsOwnState() {
        // NOT the mismatch card: a refusal is not "wrong account", it is "a person
        // has to look at this". The viewer can do nothing but reach support, and
        // nothing was written — so it gets its own state rather than being folded
        // into the mismatch copy, which would send them hunting for another account
        // that does not exist.
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .mergeRefused
            ) == .mergeRefused
        )
    }

    @Test func conflictIsRenderedSoTheViewerCanRetry() {
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .conflict
            ) == .conflict
        )
    }

    @Test func aClaimThatRacedAnotherReportsAlreadyClaimed() {
        // The link read as `ready`, but the server says otherwise — the server wins.
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .alreadyClaimed
            ) == .alreadyClaimed
        )
    }

    @Test func revokedOutcomeWinsOverAReadyContext() {
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .revoked
            ) == .revoked
        )
    }

    @Test func notFoundOutcomeWinsOverAReadyContext() {
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .notFound
            ) == .notFound
        )
    }

    @Test func vanishedClientIdentityFallsBackToSignup() {
        // Web redirects `client_not_found` to signup; `.signedOut` is the state
        // that offers exactly that.
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .clientNotFound
            ) == .signedOut
        )
    }

    @Test func aNonClientSessionRejectedByTheServerRendersNotAClient() {
        // `activeRole` defaults to `.client` when the JWT can't be decoded, so a
        // pro CAN reach the claim button; the server's 403 is the backstop.
        #expect(
            ClaimScreenState.resolve(
                contextState: ClaimContextState.ready,
                viewer: .client,
                outcome: .notAClient
            ) == .notAClient
        )
    }
}
