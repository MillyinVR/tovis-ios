// Whose name is on the picture.
//
// Two rules, and they pull in opposite directions on purpose:
//
//   1. A SAVE IS NOT A PUBLISH. When a pro saves a shot to their own camera roll
//      they get their own file — original bytes, original EXIF, no mark of any
//      kind, on every tier, forever. It is their photograph. Nothing in this file
//      can ever put ink on it.
//   2. AN EXPORT IS A PUBLISH. A platform-ready render is made to be posted, so it
//      carries a signature: the pro's handle, small, in a corner, the way a
//      photographer signs a print. A small platform mark sits beside it, and
//      dropping that mark is the membership perk.
//
// 🔴 Both directions of rule 2 are load-bearing and neither is visible from the
// outside. Get it wrong one way and a paying pro's exports carry a mark they paid
// to remove; get it wrong the other and the mark never ships and the membership
// page is selling a lie. Get rule 1 wrong and the app quietly defaces the pro's
// own archive. All three are red-proofed in SocialExportWatermarkTests.
import Foundation

/// What the pro asked for. The distinction that keeps rule 1 and rule 2 apart —
/// and the reason it is a type rather than a `Bool` on a call site is that both
/// paths can end at the same destination (the camera roll), so "where it's going"
/// can never be what decides whether it gets marked.
public enum MediaWriteIntent: String, Sendable, Equatable {
    /// The pro's own bytes, unchanged. Never marked, never re-encoded.
    case saveOriginal
    /// A platform-ready render, made to be posted. Always signed.
    case socialExport
}

/// The signature drawn into an export.
public struct ExportWatermark: Sendable, Equatable {
    /// The pro's signature line, ready to draw ("@toristyles", or their business
    /// name when they have no handle). `nil` only when the pro has neither.
    public let signature: String?
    /// The small platform mark beside the signature. Members drop it.
    public let showsPlatformMark: Bool
    /// The platform mark's text. Passed in rather than hardcoded — the app is
    /// white-label-bound and a tenant salon signs with its own name.
    public let platformMark: String

    public init(signature: String?, showsPlatformMark: Bool, platformMark: String) {
        self.signature = signature
        self.showsPlatformMark = showsPlatformMark
        self.platformMark = platformMark
    }

    /// Nothing to draw at all — a member with no handle and no business name.
    /// Legitimate: it is their photo and they have not told us what to sign it
    /// with. The export sheet nudges them to set a handle rather than inventing one.
    public var isEmpty: Bool { signature == nil && !showsPlatformMark }
}

public enum SocialExportPolicy {
    /// The entitlement key that drops the platform mark. Mirrors
    /// `SOCIAL_EXPORT_UNBRANDED` in tovis-app lib/pro/socialExportMark.ts.
    public static let unbrandedEntitlement = "social_export_unbranded"

    /// The watermark for a write, or `nil` when nothing may be drawn.
    ///
    /// - Parameters:
    ///   - membership: the pro's membership status, or nil when it could not be
    ///     loaded. See `dropsPlatformMark` for what a failed load resolves to.
    ///   - handle: the pro's `@handle`, with or without the leading "@".
    ///   - businessName: fallback signature when there is no handle.
    ///   - platformMark: the tenant's display name.
    public static func watermark(
        for intent: MediaWriteIntent,
        membership: ProMembership?,
        handle: String?,
        businessName: String?,
        platformMark: String
    ) -> ExportWatermark? {
        // 🔴 Rule 1, and it is first for a reason: no tier, no entitlement and no
        // membership state can reach past this line. A save is the pro's original.
        guard intent == .socialExport else { return nil }

        return ExportWatermark(
            signature: signature(handle: handle, businessName: businessName),
            showsPlatformMark: !dropsPlatformMark(membership),
            platformMark: platformMark
        )
    }

    /// Whether this membership drops the platform mark.
    ///
    /// The server already decided (`exportsUnbranded` on
    /// `/api/v1/pro/membership/status`, resolved by tovis-app
    /// lib/pro/socialExportMark.ts), the same way the finance payload ships
    /// `canExportTaxDocs` — so the tier rule is not re-derived inside a binary
    /// that ships on Apple's schedule.
    ///
    /// Two ways the answer can be missing, and both resolve to UNBRANDED:
    ///   • an older backend that predates the field (`exportsUnbranded == nil`);
    ///   • membership couldn't be loaded at all (`membership == nil` — offline,
    ///     a 500, a token refresh mid-flight).
    /// Being generous is the right side to fail on. A free pro's missing mark
    /// costs a little reach; a paying pro whose export sprouts a mark because
    /// their signal dropped is a broken promise they can see. It also matches
    /// production today, where the enforcement flag is off and the server answers
    /// "unbranded" for everybody anyway.
    public static func dropsPlatformMark(_ membership: ProMembership?) -> Bool {
        membership?.exportsUnbranded ?? true
    }

    /// The signature line: the handle if there is one, else the business name,
    /// else nothing. Never invents a name.
    public static func signature(handle: String?, businessName: String?) -> String? {
        if let handle = normalizedHandle(handle) { return handle }
        let name = businessName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return nil
    }

    /// `"@tori"`, from `"tori"`, `"@tori"`, `" @tori "` or `"@@tori"` alike. Nil
    /// for empty or "@"-only input, so a blank handle falls through to the
    /// business name instead of signing the print "@".
    public static func normalizedHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("@") { trimmed.removeFirst() }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "@\(trimmed)"
    }
}
