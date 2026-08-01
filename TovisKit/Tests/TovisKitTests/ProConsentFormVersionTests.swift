import Foundation
import Testing

@testable import TovisKit

/// K17-B — K14's consent VERSIONS on the technical record.
///
/// Two shapes with adjacent names and opposite jobs, which is the thing to keep
/// straight: `ProConsentFormVersion` is the immutable snapshot a record already
/// attests to (what was signed), and `ProConsentFormOption` is a live choice a
/// pro can pin a NEW record to (what would be signed today). They carry
/// different ids on purpose — an attestation has the version's own `id`, an
/// option has both `formId` and `versionId`.
@Suite struct ProConsentFormVersionTests {
    private func decodeRecord(_ json: String) throws -> ProClientTechnicalRecord {
        try JSONDecoder().decode(ProClientTechnicalRecord.self, from: Data(json.utf8))
    }

    private func decodeVersion(_ json: String) throws -> ProConsentFormVersion {
        try JSONDecoder().decode(ProConsentFormVersion.self, from: Data(json.utf8))
    }

    private func decodeOption(_ json: String) throws -> ProConsentFormOption {
        try JSONDecoder().decode(ProConsentFormOption.self, from: Data(json.utf8))
    }

    // MARK: - The attestation

    @Test func decodesAnAttestation() throws {
        let display = try #require(decodeVersion(#"""
        {
          "id": "cfv_1",
          "version": 3,
          "title": "Corrective colour waiver",
          "body": "I understand corrective colour may require multiple sessions.",
          "originLabel": "Your own wording"
        }
        """#).display)
        #expect(display.title == "Corrective colour waiver")
        #expect(display.version == 3)
        #expect(display.summary == "Corrective colour waiver · v3")
        #expect(display.originLabel == "Your own wording")
        #expect(display.body?.isEmpty == false)
    }

    /// The claim is "this record attests to v3 of THIS form". Half of it is a
    /// different claim, not a weaker one, so neither half alone renders.
    @Test func anAttestationWithoutAVersionRefuses() throws {
        let version = try decodeVersion(#"""
        { "id": "cfv_1", "title": "Corrective colour waiver", "body": "x", "originLabel": "y" }
        """#)
        #expect(version.title == "Corrective colour waiver")
        #expect(version.display == nil)
    }

    @Test func anAttestationWithoutATitleRefuses() throws {
        #expect(try decodeVersion(#"{ "id": "cfv_1", "version": 2 }"#).display == nil)
        #expect(try decodeVersion(#"{ "version": 2, "title": "   " }"#).display == nil)
    }

    /// Body and origin are the readable extras — losing them costs the pro the
    /// ability to read the text back, not the knowledge that a version exists.
    @Test func aBodylessAttestationStillRenders() throws {
        let display = try #require(decodeVersion(#"""
        { "id": "cfv_1", "version": 1, "title": "Standard client consent" }
        """#).display)
        #expect(display.summary == "Standard client consent · v1")
        #expect(display.body == nil)
        #expect(display.originLabel == nil)
    }

    /// Non-throwing, like every model that rides inside an array: a malformed
    /// attestation must not blank a client's whole consent history.
    @Test func aMalformedAttestationDoesNotThrow() throws {
        #expect(try decodeVersion(#"{ "version": "three", "title": 42 }"#).display == nil)
    }

    // MARK: - The attestation, in place on a record

    @Test func aConsentRecordCarriesItsAttestation() throws {
        let record = try decodeRecord(#"""
        {
          "formula": [],
          "photoReleaseStatus": "NOT_SET",
          "consentForms": [],
          "consents": [
            {
              "id": "c1", "scope": "full", "kind": "SERVICE_WAIVER",
              "when": null, "timeZone": null, "serviceScope": null,
              "signedAt": "2026-07-30T18:00:00.000Z", "proofMethod": "IN_PERSON",
              "proofRef": null, "patchTestResult": null, "validUntil": null,
              "notes": null, "byName": null,
              "formVersion": {
                "id": "cfv_1", "version": 2, "title": "K17 drive release",
                "body": "text", "originLabel": "Tovis template, unmodified"
              }
            }
          ]
        }
        """#)
        let display = try #require(record.consents.first?.formVersion?.display)
        #expect(display.summary == "K17 drive release · v2")
    }

    /// Every pre-K14 record, and every record whose pro attached no form.
    @Test func aRecordWithNoAttestationDecodesFine() throws {
        let record = try decodeRecord(#"""
        {
          "formula": [], "photoReleaseStatus": "GRANTED", "consentForms": [],
          "consents": [
            {
              "id": "c1", "scope": "full", "kind": "GENERAL_CONSENT",
              "when": null, "timeZone": null, "serviceScope": null, "signedAt": null,
              "proofMethod": null, "proofRef": null, "patchTestResult": null,
              "validUntil": null, "notes": null, "byName": null
            }
          ]
        }
        """#)
        #expect(record.consents.count == 1)
        #expect(record.consents[0].formVersion == nil)
    }

    /// 🔴 A safety-scoped row is another pro's patch test. The signed text is
    /// part of the artifact and travels with the proof fields, so the server
    /// nulls it — this pins that the device expects that and does not go looking
    /// for the text elsewhere.
    @Test func aSafetyScopedRowCarriesNoFormText() throws {
        let record = try decodeRecord(#"""
        {
          "formula": [], "photoReleaseStatus": "NOT_SET", "consentForms": [],
          "consents": [
            {
              "id": "c2", "scope": "safety", "kind": "PATCH_TEST",
              "when": null, "timeZone": null, "serviceScope": null, "signedAt": null,
              "proofMethod": null, "proofRef": null, "patchTestResult": "PASS",
              "validUntil": "2026-12-01T00:00:00.000Z", "notes": null,
              "byName": "Another pro", "formVersion": null
            }
          ]
        }
        """#)
        let consent = try #require(record.consents.first)
        #expect(consent.scope == "safety")
        #expect(consent.patchTestResult == "PASS")
        #expect(consent.formVersion?.display == nil)
    }

    /// 🔴 A malformed attestation on ONE row must cost that row its text and
    /// nothing else — the array around it still decodes (the K9 lesson).
    @Test func aMalformedAttestationDoesNotBlankTheConsentList() throws {
        let record = try decodeRecord(#"""
        {
          "formula": [], "photoReleaseStatus": "NOT_SET", "consentForms": [],
          "consents": [
            {
              "id": "c1", "scope": "full", "kind": "SERVICE_WAIVER",
              "when": null, "timeZone": null, "serviceScope": null, "signedAt": null,
              "proofMethod": null, "proofRef": null, "patchTestResult": null,
              "validUntil": null, "notes": null, "byName": null,
              "formVersion": "not-an-object"
            },
            {
              "id": "c2", "scope": "full", "kind": "GENERAL_CONSENT",
              "when": null, "timeZone": null, "serviceScope": null, "signedAt": null,
              "proofMethod": null, "proofRef": null, "patchTestResult": null,
              "validUntil": null, "notes": null, "byName": null, "formVersion": null
            }
          ]
        }
        """#)
        #expect(record.consents.count == 2)
        #expect(record.consents[0].formVersion?.display == nil)
        #expect(record.consents[1].id == "c2")
    }

    // MARK: - The picker options

    @Test func decodesAnOption() throws {
        let display = try #require(decodeOption(#"""
        {
          "formId": "cf_1", "versionId": "cfv_9", "version": 2,
          "kind": "SERVICE_WAIVER", "title": "K17 drive release"
        }
        """#).display)
        #expect(display.formId == "cf_1")
        #expect(display.versionId == "cfv_9")
        #expect(display.kind == .serviceWaiver)
        #expect(display.label == "K17 drive release · v2")
    }

    /// The known set is derived from the enum, never typed out beside it.
    @Test func knownKindsAreDerivedFromTheEnum() {
        #expect(ProConsentFormOption.knownKinds == ["GENERAL_CONSENT", "SERVICE_WAIVER", "PATCH_TEST"])
        #expect(ProConsentFormOption.knownKinds.count == ProConsentFormOption.Kind.allCases.count)
    }

    /// A kind this build cannot label is dropped rather than shown raw — the pro
    /// is choosing what to bind a legal record to, not reading an enum.
    @Test func anUnknownKindIsNotOffered() throws {
        let option = try decodeOption(#"""
        { "formId": "cf_1", "versionId": "cfv_9", "version": 1,
          "kind": "MEDIA_RELEASE", "title": "Media release" }
        """#)
        #expect(option.kind == "MEDIA_RELEASE")
        #expect(option.display == nil)
    }

    @Test func anOptionMissingAnIdOrNameIsNotOffered() throws {
        #expect(try decodeOption(#"{ "versionId": "v", "version": 1, "kind": "PATCH_TEST", "title": "x" }"#).display == nil)
        #expect(try decodeOption(#"{ "formId": "f", "version": 1, "kind": "PATCH_TEST", "title": " " }"#).display == nil)
        #expect(try decodeOption(#"{ "formId": "f", "kind": "PATCH_TEST", "title": "x" }"#).display == nil)
    }

    @Test func offerableDropsOnlyTheUnusableRows() throws {
        let record = try decodeRecord(#"""
        {
          "formula": [], "consents": [], "photoReleaseStatus": "NOT_SET",
          "consentForms": [
            { "formId": "cf_1", "versionId": "cfv_1", "version": 1, "kind": "GENERAL_CONSENT", "title": "Standard client consent" },
            { "formId": "cf_2", "versionId": "cfv_2", "version": 4, "kind": "NOT_A_KIND", "title": "Future form" },
            { "formId": "cf_3", "versionId": "cfv_3", "version": 2, "kind": "SERVICE_WAIVER", "title": "K17 drive release" }
          ]
        }
        """#)
        #expect(record.consentForms.count == 3)
        let offerable = record.consentForms.offerable
        #expect(offerable.map(\.label) == ["Standard client consent · v1", "K17 drive release · v2"])
    }

    // MARK: - 🔴 The picker never takes the screen down

    /// 🔴 Load-bearing. `consentForms` is a convenience for one sheet. Arriving
    /// malformed it must cost the pro that picker and NOTHING else — the formula
    /// history and the consent records are the reason the screen exists.
    @Test func aMalformedFormListDoesNotFailTheRecord() throws {
        let record = try decodeRecord(#"""
        {
          "formula": [],
          "consents": [
            {
              "id": "c1", "scope": "full", "kind": "GENERAL_CONSENT",
              "when": null, "timeZone": null, "serviceScope": null, "signedAt": null,
              "proofMethod": null, "proofRef": null, "patchTestResult": null,
              "validUntil": null, "notes": null, "byName": null
            }
          ],
          "photoReleaseStatus": "GRANTED",
          "consentForms": "not-a-list"
        }
        """#)
        #expect(record.consents.count == 1)
        #expect(record.photoReleaseStatus == "GRANTED")
        #expect(record.consentForms.isEmpty)
    }

    /// An older server that never sends the key at all.
    @Test func anOmittedFormListReadsAsNone() throws {
        let record = try decodeRecord(#"""
        { "formula": [], "consents": [], "photoReleaseStatus": "NOT_SET" }
        """#)
        #expect(record.consentForms.isEmpty)
        #expect(record.consentForms.offerable.isEmpty)
    }

    // MARK: - 🔴 The verbatim wire

    /// A VERBATIM capture of the live technical route — the first time this
    /// endpoint has had any contract coverage at all (it shipped in PR4 with no
    /// DTO, which is how K14's two fields crossed the wire unnoticed).
    @Test func decodesTheVerbatimTechnicalCapture() throws {
        let record = try JSONDecoder().decode(
            ProClientTechnicalRecord.self, from: fixture("proClientTechnical")
        )
        #expect(record.photoReleaseStatus == "NOT_SET")

        // Three records: one written with NO form pinned, two attesting to one.
        #expect(record.consents.count == 3)
        let attested = record.consents.compactMap(\.formVersion?.display)
        #expect(attested.count == 2)
        #expect(record.consents.filter { $0.formVersion?.display == nil }.count == 1)

        // 🔴 The version number is the part a pro cannot infer from anywhere else
        // on screen, and it is per-record — two records on one client can attest
        // to different versions of different forms.
        #expect(Set(attested.map(\.summary))
            == ["Standard client consent · v2", "Corrective colour waiver · v1"])
        // Provenance is server-composed and rendered verbatim, never re-derived.
        #expect(Set(attested.compactMap(\.originLabel))
            == ["Platform template, edited", "Written by you"])

        // ⚠️ A STORED CLIENT_TOKEN still arrives and must still read honestly.
        // K17-A removed it from the pro's picker because the route REFUSES it as
        // a hand-typed claim — a write-side refusal, not a reason to hide a
        // signature a real link actually produced.
        #expect(record.consents.contains { $0.proofMethod == "CLIENT_TOKEN" })
    }

    /// The picker's real choices, verbatim: three active forms across two kinds.
    @Test func decodesTheVerbatimFormOptions() throws {
        let record = try JSONDecoder().decode(
            ProClientTechnicalRecord.self, from: fixture("proClientTechnical")
        )
        let offerable = record.consentForms.offerable
        #expect(offerable.count == 3)
        #expect(offerable.map(\.label) == [
            "Corrective colour waiver · v2",
            "Standard client consent · v2",
            "K17 drive release · v1",
        ])
        // 🔴 The record sheet filters by kind, because the route 400s a form whose
        // kind disagrees with the record's. Two of these are SERVICE_WAIVER.
        #expect(offerable.filter { $0.kind == .serviceWaiver }.count == 2)
        #expect(offerable.filter { $0.kind == .generalConsent }.count == 1)
        #expect(offerable.filter { $0.kind == .patchTest }.isEmpty)
        // The version a NEW record would pin is the version id, not the form id.
        #expect(offerable.allSatisfy { $0.versionId != nil && $0.versionId != $0.formId })
    }

    /// 🔴 The three ORIGINAL fields keep their old strictness on purpose: a
    /// technical record that silently drops half a client's history is worse
    /// than one that says it broke.
    @Test func anUnreadableConsentListStillFailsTheLoad() {
        #expect(throws: (any Error).self) {
            try decodeRecord(#"""
            { "formula": [], "consents": "gone", "photoReleaseStatus": "NOT_SET", "consentForms": [] }
            """#)
        }
    }
}
