// The pro's consent form library, rendered on the iOS toolchain over the
// CONTRACT fixture and written to PNGs a person can look at.
//
// Same shape as the consult render suites: the SHIPPING cards over the SHIPPING
// wire shape, in both modes, at a phone width. It does not claim the screen was
// reached by tapping through the app.
//
// The other half of this file is the copy that carries a RULE rather than a
// label — `proConsentPublishNote`. That sentence is the only place a pro is told
// that saving publishes a new version instead of changing this one, and its
// three arms depend on a count. A wrong arm there does not look broken; it just
// quietly misdescribes what the button is about to do.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@Suite @MainActor struct ProConsentFormsRenderTests {
    private func library() throws -> ProConsentFormLibrary {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent(
            "TovisKit/Tests/TovisKitTests/Fixtures/proConsentForms.json"
        )
        return try JSONDecoder().decode(
            ProConsentFormLibrary.self, from: Data(contentsOf: url)
        )
    }

    @Test func theFixtureCarriesEveryArmThisScreenRenders() throws {
        let library = try library()

        // A form with signatures, a RETIRED one, and one adopted verbatim —
        // each renders differently, and a fixture with only the happy arm would
        // prove nothing about the other two.
        #expect(library.forms.contains { $0.signatureCount > 0 })
        #expect(library.forms.contains { !$0.isActive })
        #expect(library.forms.contains { $0.currentVersion?.verbatimFromTemplate == true })
        // Both sides of the adopt button.
        #expect(library.templates.contains { $0.adopted })
        #expect(library.templates.contains { !$0.adopted })
    }

    @Test func rendersTheFormCardsInBothModes() throws {
        let library = try library()
        let form = try #require(library.forms.first { $0.signatureCount > 0 })
        let retired = try #require(library.forms.first { !$0.isActive })

        for (scheme, name) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let image = render(
                VStack(spacing: 12) {
                    ProConsentFormCard(form: form)
                    ProConsentFormCard(form: retired)
                },
                scheme: scheme
            )
            #expect(image.size.width == 390)
            // Two stacked cards, each with a title, a subtitle, pills, a
            // disclosure and an action row. A collapsed render means the card
            // drew nothing.
            #expect(image.size.height > 200)

            let png = try #require(image.pngData())
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("pro-consent-forms-\(name).png")
            try png.write(to: out)
            print("CONSENT FORM CARD SNAPSHOT → \(out.path)")
        }
    }

    @Test func rendersTheTemplateCardsInBothModes() throws {
        let library = try library()
        let adopted = try #require(library.templates.first { $0.adopted })
        let offered = try #require(library.templates.first { !$0.adopted })

        for (scheme, name) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let image = render(
                VStack(spacing: 12) {
                    ProConsentTemplateCard(template: adopted)
                    ProConsentTemplateCard(template: offered)
                },
                scheme: scheme
            )
            #expect(image.size.width == 390)
            #expect(image.size.height > 120)

            let png = try #require(image.pngData())
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("pro-consent-templates-\(name).png")
            try png.write(to: out)
            print("CONSENT TEMPLATE CARD SNAPSHOT → \(out.path)")
        }
    }

    // MARK: - The subtitle

    /// The provenance half is printed as the server composed it. Re-deriving it
    /// on the device is the one thing D6 forbids: "Platform template, edited"
    /// and "Platform template, unchanged" are the same row with a different
    /// claim about who wrote the words.
    @Test func theSubtitleQuotesTheServersProvenanceVerbatim() throws {
        let library = try library()
        let edited = try #require(
            library.forms.first { $0.originLabel == "Platform template, edited" }
        )
        let mine = try #require(library.forms.first { $0.originLabel == "Written by you" })

        #expect(proConsentFormSubtitle(edited) == "General consent · Platform template, edited · v3 of 3")
        #expect(proConsentFormSubtitle(mine) == "Service waiver · Written by you · v2 of 2")
    }

    /// A form with no published version is not expected, but the wire types it
    /// as possible — and the subtitle must say so rather than printing "v of".
    @Test func aFormWithNoPublishedTextSaysSo() {
        let empty = ProConsentFormLibraryItem(
            id: "f1",
            kind: "SERVICE_WAIVER",
            isActive: true,
            origin: "PRO_AUTHORED",
            originLabel: "Written by you",
            currentVersion: nil,
            versionCount: 0,
            signatureCount: 0
        )
        #expect(proConsentFormSubtitle(empty) == "Service waiver · Written by you · no text published")
    }

    /// A kind this build cannot label still has to be readable: it labels a form
    /// that EXISTS, and a pro must be able to see and retire it.
    @Test func anUnknownKindStillPrintsReadably() {
        let odd = ProConsentFormLibraryItem(
            id: "f2",
            kind: "MEDICAL_HISTORY",
            isActive: true,
            origin: "PRO_AUTHORED",
            originLabel: "Written by you",
            currentVersion: nil,
            versionCount: 0,
            signatureCount: 0
        )
        #expect(proConsentFormSubtitle(odd).hasPrefix("Medical History · "))
    }

    // MARK: - The publish note

    /// 🔴 The sentence that carries the rule. All three arms, because the count
    /// is what decides which one a pro reads, and the plural arm is the one that
    /// actually explains why their old records are safe.
    @Test func thePublishNoteNamesTheNextVersionAndWhatKeepsItsOwn() throws {
        let library = try library()
        let signedThrice = try #require(library.forms.first { $0.signatureCount == 3 })
        let signedOnce = try #require(library.forms.first { $0.signatureCount == 1 })
        let unsigned = try #require(library.forms.first { $0.signatureCount == 0 })

        #expect(
            proConsentPublishNote(for: signedThrice)
                == "Saving publishes v3. The 3 records already signed against this form keep their own versions."
        )
        #expect(
            proConsentPublishNote(for: signedOnce)
                == "Saving publishes v2. The record already signed against this form keeps its own version."
        )
        #expect(
            proConsentPublishNote(for: unsigned)
                == "Saving publishes v4. Nothing has been signed against this form yet."
        )
    }

    /// Creating is the one case with no version to succeed, so it says what will
    /// happen LATER rather than naming a number.
    @Test func aNewFormIsToldItPublishesV1() {
        #expect(
            proConsentPublishNote(for: nil)
                == "This publishes v1. Editing it later publishes a new version — nothing already signed ever changes."
        )
    }

    private func render(_ view: some View, scheme: ColorScheme) -> UIImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 358).padding(16)
                .background(BrandColor.bgPrimary)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2
        // A nil image is a broken view, and the force is what makes the test
        // say so rather than passing over nothing.
        return renderer.uiImage!
    }
}
