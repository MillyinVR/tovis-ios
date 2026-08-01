import Foundation
import Testing

@testable import TovisKit

/// K17-B — the per-client booking requirements as a CONTROL.
///
/// Every other lenient model on this wire answers a read: a malformed field
/// hides a chip and costs nothing. This one is edited and PUT back as a WHOLE
/// OBJECT, so leniency has a second edge — a form built from a half-decoded
/// policy would clear the fields it could not read the moment the pro touched
/// any other switch. These tests pin the two places that decision lives:
/// `display` refuses anything partial, and `cardOnFileRailEnabled` fails CLOSED.
@Suite struct ProClientPolicyTests {
    private func decodeResponse(_ json: String) throws -> ProClientPolicyResponse {
        try JSONDecoder().decode(ProClientPolicyResponse.self, from: Data(json.utf8))
    }

    private func decodePolicy(_ json: String) throws -> ProClientPolicy {
        try JSONDecoder().decode(ProClientPolicy.self, from: Data(json.utf8))
    }

    // MARK: - The stored row, whole

    @Test func decodesAFullPolicy() throws {
        let response = try decodeResponse(#"""
        {
          "ok": true,
          "policy": {
            "requireDeposit": true,
            "prepayScope": "ENTIRE_BOOKING",
            "requireCardOnFile": false,
            "blockSelfServeBooking": true
          },
          "cardOnFileRailEnabled": true
        }
        """#)
        let display = try #require(response.policy?.display)
        #expect(display.requireDeposit == true)
        #expect(display.prepayScope == .entireBooking)
        #expect(display.requireCardOnFile == false)
        #expect(display.blockSelfServeBooking == true)
        #expect(display.isEmpty == false)
        #expect(response.cardOnFileRailEnabled == true)
    }

    /// A pro who has set nothing is a different fact from four falses — the
    /// server DELETEs the row rather than storing an all-off one, so `null` has
    /// to survive as `null` and not become an empty policy on the way in.
    @Test func aNullPolicyStaysNull() throws {
        let response = try decodeResponse(#"""
        { "ok": true, "policy": null, "cardOnFileRailEnabled": false }
        """#)
        #expect(response.policy == nil)
        #expect(response.cardOnFileRailEnabled == false)
    }

    /// Absent prepay is a real value (no prepay requirement), not a failure.
    @Test func absentPrepayScopeIsNotARefusal() throws {
        let policy = try decodePolicy(#"""
        {
          "requireDeposit": false,
          "prepayScope": null,
          "requireCardOnFile": false,
          "blockSelfServeBooking": false
        }
        """#)
        let display = try #require(policy.display)
        #expect(display.prepayScope == nil)
        #expect(display.isEmpty)
    }

    // MARK: - 🔴 The refusals that protect the WRITE

    /// 🔴 Load-bearing. A switch that failed to decode must take the whole
    /// editable policy with it: the save is a whole-object PUT, so rendering the
    /// other three would arm a control that silently clears this one.
    @Test func aPartialPolicyHasNoEditableDisplay() throws {
        // `requireDeposit` is missing — the pro may well have it ON.
        let policy = try decodePolicy(#"""
        {
          "prepayScope": null,
          "requireCardOnFile": true,
          "blockSelfServeBooking": false
        }
        """#)
        #expect(policy.requireCardOnFile == true, "the fields that DID arrive still decode")
        #expect(policy.display == nil, "but there is nothing safe to edit")
    }

    /// The same refusal when a field arrives with the wrong type rather than
    /// missing — leniency turns it into nil, and nil is what `display` refuses.
    @Test func aMistypedSwitchAlsoRefuses() throws {
        let policy = try decodePolicy(#"""
        {
          "requireDeposit": "yes",
          "prepayScope": null,
          "requireCardOnFile": false,
          "blockSelfServeBooking": false
        }
        """#)
        #expect(policy.display == nil)
    }

    /// 🔴 A prepay scope this build cannot name is a REQUIREMENT the pro cannot
    /// see. Treating it as "no prepay" would show an off switch over a live
    /// requirement, and the next save would make the lie true.
    @Test func anUnknownPrepayScopeRefusesTheWholePolicy() throws {
        let policy = try decodePolicy(#"""
        {
          "requireDeposit": false,
          "prepayScope": "ADD_ONS_ONLY",
          "requireCardOnFile": false,
          "blockSelfServeBooking": false
        }
        """#)
        #expect(policy.prepayScope == "ADD_ONS_ONLY")
        #expect(policy.display == nil)
    }

    /// The known set is derived from the enum, never typed out beside it.
    @Test func knownPrepayScopesAreDerivedFromTheEnum() {
        #expect(ProClientPolicy.knownPrepayScopes == ["SERVICE_ONLY", "ENTIRE_BOOKING"])
        #expect(ProClientPolicy.knownPrepayScopes.count == ProClientPolicy.PrepayScope.allCases.count)
    }

    // MARK: - 🔴 The capability fails CLOSED

    /// 🔴 A missing `cardOnFileRailEnabled` must read as false. The write route
    /// 409s a card-on-file requirement while the rail is dark, so defaulting the
    /// other way offers a switch the server is going to refuse
    /// ([[kill-switch-must-reach-the-control]]).
    @Test func aMissingRailCapabilityReadsAsOff() throws {
        let response = try decodeResponse(#"{ "ok": true, "policy": null }"#)
        #expect(response.cardOnFileRailEnabled == false)
    }

    @Test func aMistypedRailCapabilityReadsAsOff() throws {
        let response = try decodeResponse(#"""
        { "ok": true, "policy": null, "cardOnFileRailEnabled": "true" }
        """#)
        #expect(response.cardOnFileRailEnabled == false)
    }

    /// The rail flag is NOT folded into the stored switch on the way in. A pro
    /// who turned card-on-file on sees it on, even while the rail is dark —
    /// that is the whole reason the two travel separately.
    @Test func theRailFlagDoesNotZeroTheStoredSwitch() throws {
        let response = try decodeResponse(#"""
        {
          "ok": true,
          "policy": {
            "requireDeposit": false,
            "prepayScope": null,
            "requireCardOnFile": true,
            "blockSelfServeBooking": false
          },
          "cardOnFileRailEnabled": false
        }
        """#)
        let display = try #require(response.policy?.display)
        #expect(display.requireCardOnFile == true)
        #expect(response.cardOnFileRailEnabled == false)
    }

    /// A whole malformed policy object must not fail the response decode — the
    /// screen still renders, showing that it could not read the requirements.
    @Test func aMalformedPolicyObjectDoesNotFailTheResponse() throws {
        let response = try decodeResponse(#"""
        { "ok": true, "policy": "corrupt", "cardOnFileRailEnabled": true }
        """#)
        #expect(response.policy?.display == nil)
        #expect(response.cardOnFileRailEnabled == true)
    }

    // MARK: - The empty policy

    @Test func anAllOffDisplayIsEmpty() {
        #expect(ProClientPolicy.Display.none.isEmpty)
        #expect(ProClientPolicy.Display.none.prepayScope == nil)
    }

    @Test func anyOneSwitchMakesItNotEmpty() {
        let policies: [ProClientPolicy.Display] = [
            .init(requireDeposit: true, prepayScope: nil, requireCardOnFile: false, blockSelfServeBooking: false),
            .init(requireDeposit: false, prepayScope: .serviceOnly, requireCardOnFile: false, blockSelfServeBooking: false),
            .init(requireDeposit: false, prepayScope: nil, requireCardOnFile: true, blockSelfServeBooking: false),
            .init(requireDeposit: false, prepayScope: nil, requireCardOnFile: false, blockSelfServeBooking: true),
        ]
        for policy in policies { #expect(policy.isEmpty == false) }
    }

    // MARK: - 🔴 The verbatim wire

    /// A VERBATIM capture of the live route with the rail DARK. This is the case
    /// the whole contract exists for: the stored switch says true, the capability
    /// beside it says the rail cannot honour it, and BOTH facts survive the trip.
    @Test func decodesTheVerbatimCaptureWithTheRailDark() throws {
        let response = try JSONDecoder().decode(
            ProClientPolicyResponse.self, from: fixture("proClientPolicy")
        )
        let display = try #require(response.policy?.display)
        #expect(display.requireCardOnFile == true, "the pro set this, and still sees it set")
        #expect(response.cardOnFileRailEnabled == false, "but the rail cannot honour it")
        #expect(display.blockSelfServeBooking == true)
        #expect(display.requireDeposit == false)
        #expect(display.prepayScope == nil)
        #expect(setCount(display) == 2)
    }

    /// The DELETE response, verbatim — the route's answer for "this pro requires
    /// nothing of this client".
    @Test func decodesTheVerbatimClearedCapture() throws {
        let response = try JSONDecoder().decode(
            ProClientPolicyResponse.self, from: fixture("proClientPolicyNone")
        )
        #expect(response.policy == nil)
        #expect(response.cardOnFileRailEnabled == false)
    }

    private func setCount(_ policy: ProClientPolicy.Display) -> Int {
        [policy.requireDeposit, policy.prepayScope != nil,
         policy.requireCardOnFile, policy.blockSelfServeBooking].filter { $0 }.count
    }

    // MARK: - The request body

    /// Every switch is sent every time. The route stores the object it is given,
    /// so a key left out is a silent clear.
    @Test func theRequestSendsEverySwitch() throws {
        let body = ProClientPolicyRequest(
            requireDeposit: true,
            prepayScope: ProClientPolicy.PrepayScope.serviceOnly.rawValue,
            requireCardOnFile: false,
            blockSelfServeBooking: true
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder.canonical.encode(body)
        ) as? [String: Any]
        let keys = try #require(json?.keys).sorted()
        #expect(keys == ["blockSelfServeBooking", "prepayScope", "requireCardOnFile", "requireDeposit"])
        #expect(json?["prepayScope"] as? String == "SERVICE_ONLY")
        #expect(json?["requireDeposit"] as? Bool == true)
    }

    /// A cleared prepay requirement travels as an omitted key, which the route
    /// parses to null — the same answer an explicit null gives.
    @Test func aClearedPrepayScopeOmitsTheKey() throws {
        let body = ProClientPolicyRequest(
            requireDeposit: false,
            prepayScope: nil,
            requireCardOnFile: false,
            blockSelfServeBooking: true
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder.canonical.encode(body)
        ) as? [String: Any]
        #expect(json?["prepayScope"] == nil)
        #expect(json?["blockSelfServeBooking"] as? Bool == true)
    }
}
