import Foundation

// Wire models for the pro's CONSENT FORM LIBRARY —
// GET /api/v1/pro/consent-forms (web `ProConsentFormLibraryResponseDTO`).
//
// The app has consumed consent forms since K14: the technical record offers the
// pro's active forms when writing a consent record, the session hub lists the
// unsigned ones, and `ProClientsService.sendConsentRequest` texts a signing
// link. None of that could CREATE a form — K14 shipped the library with three
// write routes and no read route, so the whole authoring surface lived inside
// one web page. A pro who only has their phone could send a waiver and never
// write one.
//
// 🔴 The one idea these models have to carry: there is no editing. A form's text
// lives on APPEND-ONLY versions, so changing the words publishes version n+1 and
// every record already signed keeps resolving the version it was signed against.
// `signatureCount` is what makes that legible to the pro rather than surprising.

/// GET /api/v1/pro/consent-forms. 404s while the technical-record gate is off
/// for this pro — the same gate as the chart tab these forms attach to, never a
/// second switch (`ProCapabilities.clientTechnicalRecord` reports it).
public struct ProConsentFormLibrary: Decodable, Sendable, Equatable {
    /// The pro's own forms, active first then most recently created.
    public let forms: [ProConsentFormLibraryItem]
    /// Platform templates on offer, each carrying whether this pro adopted it.
    public let templates: [ProConsentFormTemplate]
    /// The lengths the write routes actually refuse past.
    public let limits: ProConsentFormLimits

    public init(
        forms: [ProConsentFormLibraryItem],
        templates: [ProConsentFormTemplate],
        limits: ProConsentFormLimits
    ) {
        self.forms = forms
        self.templates = templates
        self.limits = limits
    }
}

/// The title/body limits, read from the server rather than held here.
///
/// 🔴 Deliberately NOT a pair of Swift constants. These are the numbers
/// `parseConsentFormText` refuses against; a device holding its own copy stops
/// agreeing with the server the day one of them moves, and the pro finds out by
/// having a finished waiver refused.
public struct ProConsentFormLimits: Decodable, Sendable, Equatable {
    public let titleMax: Int
    public let bodyMax: Int

    public init(titleMax: Int, bodyMax: Int) {
        self.titleMax = titleMax
        self.bodyMax = bodyMax
    }
}

/// One form in the library — the pro's own, or a platform template.
public struct ProConsentFormLibraryItem: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    /// GENERAL_CONSENT | SERVICE_WAIVER | PATCH_TEST. A String, like every other
    /// consent kind on the wire: a kind this build cannot label is still a form
    /// the pro must be able to see and retire (`proConsentKindLabel`).
    public let kind: String
    /// False = retired. Kept for the records signed against it, offered to none.
    public let isActive: Bool
    /// PLATFORM_TEMPLATE | ADOPTED_TEMPLATE | PRO_AUTHORED.
    public let origin: String
    /// Provenance in words, composed server-side ("Platform template, edited").
    ///
    /// 🔴 Rendered verbatim, never re-derived here. The rule that separates an
    /// adopted template from an EDITED one lives in one place on the server, and
    /// a second spelling of it is how an edited form borrows the platform's
    /// authority.
    public let originLabel: String
    /// The text that would be signed today. Null only for a form whose versions
    /// were never published — not expected, but the server types it as possible.
    public let currentVersion: ProConsentFormLibraryVersion?
    public let versionCount: Int
    /// Consent records pointing at ANY version of this form. The number that
    /// explains why editing publishes rather than overwrites.
    public let signatureCount: Int

    public init(
        id: String,
        kind: String,
        isActive: Bool,
        origin: String,
        originLabel: String,
        currentVersion: ProConsentFormLibraryVersion?,
        versionCount: Int,
        signatureCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.isActive = isActive
        self.origin = origin
        self.originLabel = originLabel
        self.currentVersion = currentVersion
        self.versionCount = versionCount
        self.signatureCount = signatureCount
    }
}

/// The current text of a form.
public struct ProConsentFormLibraryVersion: Decodable, Sendable, Equatable {
    public let id: String
    /// The version NUMBER — 3 means "v3", not "the 3rd form".
    public let version: Int
    public let title: String
    /// The full text a client agrees to. Long; a surface discloses it.
    public let body: String
    /// ISO instant.
    public let publishedAt: String
    /// Whether these words are still the platform template's, byte for byte.
    public let verbatimFromTemplate: Bool

    public init(
        id: String,
        version: Int,
        title: String,
        body: String,
        publishedAt: String,
        verbatimFromTemplate: Bool
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.body = body
        self.publishedAt = publishedAt
        self.verbatimFromTemplate = verbatimFromTemplate
    }
}

/// A platform template on offer, plus whether this pro already adopted it.
///
/// The wire shape is FLAT — a form object with one extra key — so this decodes
/// the shared fields through `ProConsentFormLibraryItem` rather than restating
/// them. A second copy of eight field names is a copy that drifts.
public struct ProConsentFormTemplate: Decodable, Sendable, Equatable, Identifiable {
    public let form: ProConsentFormLibraryItem
    /// True once this pro holds a form copied from this template. The create
    /// route 409s a second adoption, so the surface must not offer it again.
    public let adopted: Bool

    public var id: String { form.id }

    private enum CodingKeys: String, CodingKey { case adopted }

    public init(from decoder: Decoder) throws {
        form = try ProConsentFormLibraryItem(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adopted = try container.decodeIfPresent(Bool.self, forKey: .adopted) ?? false
    }

    public init(form: ProConsentFormLibraryItem, adopted: Bool) {
        self.form = form
        self.adopted = adopted
    }
}
