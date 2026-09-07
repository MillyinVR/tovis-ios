import XCTest
@testable import TovisKit

/// The iOS half of the "a repeat must not look like the first" contract. Mirrors
/// lib/consult/captureRetakeGuidance.test.ts in tovis-app; the two must agree,
/// because a client who switches device must not get a different account of the
/// same photograph.
final class ConsultRetakeGuidanceTests: XCTestCase {
    func testFirstRefusalSaysNothingExtra() {
        let g = consultSlotRetakeGuidance(
            reasonCode: "TOO_DARK",
            previousReasonCode: nil,
            retakeTip: "Move somewhere brighter.",
            attemptCount: 1
        )
        XCTAssertNil(g.attemptLabel)
        XCTAssertNil(g.repeatedLine)
        XCTAssertEqual(g.nextStep, "Move somewhere brighter.")
    }

    func testRepeatNumbersTheAttemptAndNamesIt() {
        let g = consultSlotRetakeGuidance(
            reasonCode: "TOO_DARK",
            previousReasonCode: "TOO_DARK",
            retakeTip: "Move somewhere brighter.",
            attemptCount: 2
        )
        XCTAssertEqual(g.attemptLabel, "Attempt 2")
        XCTAssertEqual(g.repeatedLine, "This one’s dark too.")
    }

    func testRepeatGivesADifferentLeverNotTheSameTip() {
        let g = consultSlotRetakeGuidance(
            reasonCode: "TOO_DARK",
            previousReasonCode: "TOO_DARK",
            retakeTip: "Move somewhere brighter.",
            attemptCount: 2
        )
        XCTAssertNotEqual(g.nextStep, "Move somewhere brighter.")
        XCTAssertEqual(g.nextStep, "Try turning on more light, or moving to a brighter room.")
    }

    /// A different finding is PROGRESS. Saying "too" there would be a lie, and
    /// the model's tip is about the frame it actually looked at.
    func testDifferentFindingIsNotARepeat() {
        let g = consultSlotRetakeGuidance(
            reasonCode: "BLURRY",
            previousReasonCode: "TOO_DARK",
            retakeTip: "Hold still.",
            attemptCount: 2
        )
        XCTAssertNil(g.repeatedLine)
        XCTAssertEqual(g.nextStep, "Hold still.")
        XCTAssertEqual(g.attemptLabel, "Attempt 2")
    }

    func testNeverClaimsARepeatOfPass() {
        let g = consultSlotRetakeGuidance(
            reasonCode: "PASS",
            previousReasonCode: "PASS",
            retakeTip: nil,
            attemptCount: 3
        )
        XCTAssertNil(g.repeatedLine)
    }

    /// The wire may omit the new fields entirely — an older server, or a build
    /// that reaches prod before the deploy. A slot that fails to decode is a
    /// photo request that vanishes from the thread, so it must not.
    func testSlotDecodesWithoutTheNewFields() throws {
        let json = """
        {"shotKey":"face_front","state":"REJECTED","captureId":"c1",
         "qualityReasonCode":"BLURRY","qualityWarningCode":null,
         "retakeTip":"Hold still.","rawExpiresAt":null,"purgedAt":null}
        """.data(using: .utf8)!
        let slot = try JSONDecoder().decode(ConsultCaptureSlot.self, from: json)
        XCTAssertEqual(slot.attemptCount, 0)
        XCTAssertNil(slot.previousReasonCode)
    }

    func testSlotDecodesTheNewFieldsWhenPresent() throws {
        let json = """
        {"shotKey":"face_front","state":"REJECTED","captureId":"c1",
         "qualityReasonCode":"WARM_INDOOR_LIGHT","qualityWarningCode":null,
         "retakeTip":"Move to a window.","rawExpiresAt":null,"purgedAt":null,
         "attemptCount":3,"previousReasonCode":"WARM_INDOOR_LIGHT"}
        """.data(using: .utf8)!
        let slot = try JSONDecoder().decode(ConsultCaptureSlot.self, from: json)
        XCTAssertEqual(slot.attemptCount, 3)
        XCTAssertEqual(slot.previousReasonCode, "WARM_INDOOR_LIGHT")
    }
}
