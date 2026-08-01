import Testing
import TovisKit

@testable import Tovis

/// K17-B — the copy tables the client chart's consent + requirements surfaces
/// share.
///
/// Both tables are file-scope for the same reason K17-A made
/// `proConsentProofMethodOptions` file-scope: rows written inline inside a
/// `Picker` or a `switch` inside a `View` cannot be asserted on, and that is
/// exactly how K14's dead proof method survived unnoticed until K17-A went
/// looking. A vocabulary a test can read is a vocabulary that can be kept
/// honest.
@Suite struct ProClientRequirementTests {
    // MARK: - The four booking requirements

    /// Every requirement K16 stores has a row here — a fifth switch added to the
    /// schema with no row would render as nothing at all.
    @Test func coversEveryStoredRequirement() {
        #expect(ProClientRequirement.allCases.map(\.rawValue)
            == ["deposit", "prepay", "cardOnFile", "noOnlineBooking"])
    }

    @Test func everyRequirementHasWordsAndAHint() {
        for requirement in ProClientRequirement.allCases {
            #expect(!requirement.title.isEmpty)
            #expect(!requirement.hint.isEmpty)
        }
    }

    /// The summary prints only what is SET, in one fixed order.
    @Test func theSummaryListsOnlyWhatIsSet() {
        let policy = ProClientPolicy.Display(
            requireDeposit: true,
            prepayScope: nil,
            requireCardOnFile: false,
            blockSelfServeBooking: true
        )
        #expect(proClientRequirementSummary(policy).map(\.label) == ["Deposit", "No online booking"])
    }

    /// A policy with nothing set prints nothing — the surface says so in words
    /// instead of showing an empty chip row.
    @Test func anEmptyPolicySummarisesToNothing() {
        #expect(proClientRequirementSummary(.none).isEmpty)
    }

    /// 🔴 The prepay chip names its SCOPE. "Prepay" alone would read the same for
    /// a client paying for one service and a client paying for the whole visit,
    /// and those are different amounts of money.
    @Test func thePrepayChipNamesItsScope() {
        let wholeBooking = ProClientPolicy.Display(
            requireDeposit: false,
            prepayScope: .entireBooking,
            requireCardOnFile: false,
            blockSelfServeBooking: false
        )
        let serviceOnly = ProClientPolicy.Display(
            requireDeposit: false,
            prepayScope: .serviceOnly,
            requireCardOnFile: false,
            blockSelfServeBooking: false
        )
        #expect(proClientRequirementSummary(wholeBooking).map(\.label) == ["Prepay (whole booking)"])
        #expect(proClientRequirementSummary(serviceOnly).map(\.label) == ["Prepay (service)"])
    }

    /// Web's roster prints exactly these words (`summarizeProClientPolicy`). A pro
    /// who sets a requirement on the phone and reads the list on the web must not
    /// meet two names for one thing.
    @Test func theChipsMatchWebsRosterVocabulary() {
        let all = ProClientPolicy.Display(
            requireDeposit: true,
            prepayScope: .serviceOnly,
            requireCardOnFile: true,
            blockSelfServeBooking: true
        )
        #expect(proClientRequirementSummary(all).map(\.label)
            == ["Deposit", "Prepay (service)", "Card on file", "No online booking"])
    }

    // MARK: - 🔴 What a SAVE sends

    /// 🔴 Load-bearing, and found by driving the real route. With the rail dark
    /// the card-on-file switch is DISABLED but still rendered ON — so masking the
    /// value with the rail flag would silently clear a requirement the pro set,
    /// the first time they opened the sheet to change something else. The stored
    /// value travels verbatim; the route 409s in its own words; nothing is lost.
    @Test func aDarkRailNeverClearsAStoredCardRequirement() {
        let draft = proClientPolicyDraft(
            requireDeposit: false,
            prepayScope: nil,
            requireCardOnFile: true,
            blockSelfServeBooking: true,
            cardOnFileRailEnabled: false
        )
        #expect(draft.requireCardOnFile == true)
        #expect(draft.blockSelfServeBooking == true)
    }

    /// The rail flag changes NOTHING about what is sent — it gates the CONTROL,
    /// not the payload.
    @Test func theRailFlagDoesNotAlterTheDraft() {
        for rail in [true, false] {
            let draft = proClientPolicyDraft(
                requireDeposit: true,
                prepayScope: .serviceOnly,
                requireCardOnFile: true,
                blockSelfServeBooking: false,
                cardOnFileRailEnabled: rail
            )
            #expect(draft == ProClientPolicy.Display(
                requireDeposit: true,
                prepayScope: .serviceOnly,
                requireCardOnFile: true,
                blockSelfServeBooking: false
            ))
        }
    }

    /// Prepay off sends no scope — the scope column IS the switch.
    @Test func prepayOffSendsNoScope() {
        let draft = proClientPolicyDraft(
            requireDeposit: false,
            prepayScope: nil,
            requireCardOnFile: false,
            blockSelfServeBooking: false,
            cardOnFileRailEnabled: true
        )
        #expect(draft.prepayScope == nil)
        #expect(draft.isEmpty)
    }

    // MARK: - The consent vocabulary

    /// 🔴 Load-bearing. The picker's kind table and the model's derived
    /// `knownKinds` must name the same set. They are reached by different paths —
    /// one is hand-written words, one is derived from the enum — and a kind added
    /// to only one of them means either a form the pro cannot record against, or
    /// a picker row that posts a value the server rejects.
    @Test func theKindPickerCoversEveryKnownKind() {
        #expect(Set(proConsentKindOptions.map(\.value)) == ProConsentFormOption.knownKinds)
    }

    @Test func kindLabelsAreTheOnesTheCardsPrint() {
        #expect(proConsentKindLabel("GENERAL_CONSENT") == "General consent")
        #expect(proConsentKindLabel("SERVICE_WAIVER") == "Service waiver")
        #expect(proConsentKindLabel("PATCH_TEST") == "Patch test")
    }

    /// A stored kind this build doesn't know still labels a record that EXISTS —
    /// unlike the picker, which offers only what can be written. Disappearing
    /// would hide a real consent record from the pro who took it.
    @Test func anUnknownStoredKindStillPrintsReadably() {
        #expect(proConsentKindLabel("MEDIA_RELEASE") == "Media Release")
    }

    /// K17-A's refusal, re-pinned here because this suite now owns the consent
    /// vocabulary: `CLIENT_TOKEN` is REFUSED by `POST …/consent`, and the only
    /// way to record a link signature is the Send button on the session hub.
    @Test func theProofMethodPickerStillRefusesClientToken() {
        #expect(!proConsentProofMethodOptions.map(\.value).contains("CLIENT_TOKEN"))
        #expect(proConsentProofMethodOptions.map(\.value) == ["IN_PERSON", "PAPER_ON_FILE"])
    }
}
