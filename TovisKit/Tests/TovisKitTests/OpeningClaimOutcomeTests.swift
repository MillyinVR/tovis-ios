import Testing
@testable import TovisKit

// The claim sheet decides between "Someone just grabbed it" and the server's own
// error copy. Getting that wrong is user-visible in both directions: a policy
// refusal dressed up as a race tells the client to give up on a slot that is
// still there, and a real race reported as a generic error leaves them re-tapping
// a button that can never succeed.
//
// Every status/code pair below was DRIVEN against the live API, not inferred:
// `POST /holds` at an out-of-hours instant answers 400 OUTSIDE_WORKING_HOURS,
// `POST /bookings/finalize` with a time that doesn't match the opening answers
// 409 OPENING_NOT_AVAILABLE, and a pro with an incomplete profile answers
// 409 PRO_NOT_READY — which is precisely why this cannot branch on 409 alone.
@Suite struct OpeningClaimOutcomeTests {
    @Test func openingNotAvailableIsTaken() {
        #expect(
            OpeningClaimFailure.classify(
                status: 409,
                code: "OPENING_NOT_AVAILABLE",
                message: "That opening was just taken. Please pick another slot."
            ) == .taken
        )
    }

    @Test func slotConflictsAreTaken() {
        for code in ["TIME_BOOKED", "TIME_HELD", "TIME_BLOCKED"] {
            #expect(
                OpeningClaimFailure.classify(status: 409, code: code, message: "x") == .taken,
                "\(code) should read as gone"
            )
        }
    }

    @Test func codeMatchingIgnoresCaseAndPadding() {
        #expect(
            OpeningClaimFailure.classify(
                status: 409, code: "  opening_not_available  ", message: "x"
            ) == .taken
        )
    }

    // The regression that matters: a 409 that is NOT a race.
    @Test func proNotReadyIsNotTaken() {
        let outcome = OpeningClaimFailure.classify(
            status: 409,
            code: "PRO_NOT_READY",
            message: "This professional is not currently accepting bookings."
        )
        #expect(
            outcome == .failed(
                message: "This professional is not currently accepting bookings."
            )
        )
    }

    // A policy refusal is a 400 and must surface its own copy — telling the client
    // someone grabbed it would be a lie AND would hide the real reason.
    @Test func policyRefusalsSurfaceTheServerCopy() {
        let cases = [
            ("OUTSIDE_WORKING_HOURS", "That time is outside working hours."),
            ("STEP_MISMATCH", "That start time is not on a valid booking boundary."),
            ("ADVANCE_NOTICE_REQUIRED", "That slot is too soon. Please choose a later time."),
        ]
        for (code, copy) in cases {
            #expect(
                OpeningClaimFailure.classify(status: 400, code: code, message: copy)
                    == .failed(message: copy),
                "\(code) should surface its own copy"
            )
        }
    }

    @Test func unknownCodeFallsBackToTheServerCopy() {
        #expect(
            OpeningClaimFailure.classify(
                status: 422, code: "SOMETHING_NEW", message: "Try later."
            ) == .failed(message: "Try later.")
        )
    }

    // No code we know AND no copy: say the honest generic thing for the status
    // rather than inventing a cause.
    @Test func bareConflictWithNoBodyStillReadsAsAConflict() {
        #expect(
            OpeningClaimFailure.classify(status: 409, code: nil, message: nil)
                == .failed(message: "That time is no longer available. Please try another opening.")
        )
        #expect(
            OpeningClaimFailure.classify(status: 500, code: nil, message: "   ")
                == .failed(message: "Couldn’t claim this opening. Please try again.")
        )
    }

    @Test func transportFailuresUseTheClientCopy() {
        #expect(
            OpeningClaimFailure.classify(APIError.transport("offline"))
                == .failed(message: "Can't reach the server. Check your connection.")
        )
    }

    @Test func serverErrorsRouteThroughTheCodeClassifier() {
        #expect(
            OpeningClaimFailure.classify(
                APIError.server(status: 409, message: "gone", code: "OPENING_NOT_AVAILABLE")
            ) == .taken
        )
        #expect(
            OpeningClaimFailure.classify(
                APIError.server(status: 409, message: "not ready", code: "PRO_NOT_READY")
            ) == .failed(message: "not ready")
        )
    }
}
