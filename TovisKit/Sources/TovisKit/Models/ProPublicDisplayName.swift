import Foundation

// The single public display-name rule for professionals — the Swift port of
// tovis-app/lib/privacy/professionalDisplayName.ts.
//
// Web deliberately splits the rule in two: `pickProfessionalPublicDisplayName`
// resolves the name or returns null, and `formatProfessionalPublicDisplayName`
// applies a caller-supplied fallback (default "Professional"). Three Swift
// models had each fused those halves into their own `displayName`, which is
// exactly how the fallback string drifted three ways ("Your pro" /
// "Professional" / "A pro") while the resolution logic stayed identical. The
// split is preserved here so the shared half can be reused without forcing one
// piece of user-facing copy on every surface.
//
// See ProPublicDisplayNameTests for the pinned behavior.

extension String {
    /// Trimmed, or nil when the string is blank — the single "a blank token is
    /// no token" guard, mirroring the web `str()` helpers.
    ///
    /// ⚠️ **`public` on purpose.** This was `internal`, which is precisely why
    /// the app target re-rolled it 30-odd times under five different names
    /// (`trimOrNil`, `emptyToNil`, `nilIfBlank`, a private `trimmedOrNil(_:)`,
    /// plus inline pairs) — none of those files could see it. Two of the
    /// re-rolls even diverged from each other: `nilIfBlank` was declared twice
    /// with OPPOSITE semantics, one returning the trimmed value and one the
    /// untrimmed receiver. Round-3 queue item 15 collapsed them. Keep it public.
    ///
    /// Trims `.whitespacesAndNewlines`, so a newline-only string is nil. The
    /// `.whitespaces`-only variants it replaced did not do that — see
    /// `TrimmedOrNilTests` for the cases where that mattered.
    public var trimmedOrNil: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }

    /// Edge-trimmed, keeping blanks as `""` — the half of the guard that callers
    /// doing their own `.isEmpty` check or `Int(…)` parse actually want. Three
    /// files re-rolled this one too (two as a `trimmed(_:)` method, one as a
    /// private property), all with the same `.whitespacesAndNewlines` set.
    public var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The PII-safe identity tokens the public display-name rule reads. Any wire
/// model carrying the pro's name-display toggle plus its name tokens conforms,
/// and gets `publicDisplayName` / `handleLabel` for free.
///
/// Leaner pro references (`HomeProfessional`, `MessageProPreview`) deliberately
/// do NOT conform: their payloads carry no `nameDisplay`/real-name fields at
/// all, so they cannot honor the toggle and have their own simpler rules.
public protocol ProPublicNameSource {
    var businessName: String? { get }
    var firstName: String? { get }
    var lastName: String? { get }
    var handle: String? { get }
    var nameDisplay: ProNameDisplay? { get }
}

public extension ProPublicNameSource {
    /// "@handle", or nil when there's no usable handle. Independent of the
    /// display mode — a caller may show it alongside the resolved name.
    var handleLabel: String? { handle?.trimmedOrNil.map { "@\($0)" } }

    /// Port of `pickProfessionalPublicDisplayName`: honor the pro's chosen mode,
    /// degrading to the other forms so solo pros never render as a blank or a
    /// raw email. Nil only when the pro has no usable name token at all.
    ///
    /// ⚠️ BUSINESS_NAME (and the unknown/absent modes that fold into it) must
    /// NEVER fall through to the handle — a pro who chose to be known by their
    /// business has not consented to their handle standing in for it. Only
    /// REAL_NAME and HANDLE mode may surface an @handle.
    var publicDisplayName: String? {
        let business = businessName?.trimmedOrNil
        let realName = [firstName?.trimmedOrNil, lastName?.trimmedOrNil]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmedOrNil

        switch nameDisplay {
        case .realName:
            return realName ?? business ?? handleLabel
        case .handle:
            return handleLabel ?? business ?? realName
        case .businessName, .unknown, .none:
            return business ?? realName
        }
    }

    /// Port of `formatProfessionalPublicDisplayName`: the resolved name, or the
    /// surface's own copy when the pro has no usable name token.
    ///
    /// The fallback stays a per-call-site parameter on purpose — it is
    /// user-facing copy, and the surfaces legitimately differ ("Your pro" reads
    /// right on a booking the viewer owns; "A pro" reads right on a stranger's
    /// look). Pinned per surface in ProPublicDisplayNameTests.
    func publicDisplayName(fallback: String) -> String {
        publicDisplayName ?? fallback
    }
}
