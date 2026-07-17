import Foundation

// The rules behind the native "new media post" authoring screen — the counterpart
// of the web `/pro/media/new` page (`app/pro/media/new/NewMediaPostForm.tsx`).
//
// They live on the model rather than in the SwiftUI view for the usual reason:
// this is the only place `swift test` can reach them, and the gate on this repo
// IS the local test run. The view owns pixels; everything below owns "can this
// post ship, and what does the server get".
//
// Mirrored from web deliberately, field for field, because the two forms feed the
// SAME endpoint (`POST /api/v1/pro/media`) and the server re-validates every rule.
// A native form that disagreed would either block a legal post or ship one the
// route 400s after the bytes are already in the bucket.

/// Where a published look appears in the Looks feed. Matches Prisma
/// `LookPostVisibility` + the web form's "Looks visibility" select. Only
/// meaningful once the post is Looks-eligible.
public enum LookVisibility: String, Codable, Sendable, CaseIterable, Identifiable {
    case `public` = "PUBLIC"
    case followersOnly = "FOLLOWERS_ONLY"
    case unlisted = "UNLISTED"

    public var id: String { rawValue }

    /// The picker label. Verbatim from the web select's `<option>` text.
    public var label: String {
        switch self {
        case .public: "Public"
        case .followersOnly: "Followers only"
        case .unlisted: "Unlisted"
        }
    }
}

/// A media asset's visibility. Matches Prisma `MediaVisibility`.
///
/// ⚠️ Always DERIVED from the two surface flags, never chosen directly and never
/// sent to the server — the route recomputes it and rejects a mismatched bucket.
/// This mirrors web's `computeVisibility` and the server's own
/// `normalizeVisibilityFromFlags`, which is why the rule lives in one place: the
/// media-manager edit sheet needs the identical derivation, and a second hand-
/// rolled copy is exactly how three display-name ports drifted (see
/// `ProPublicNameSource`).
public enum MediaPostVisibility: String, Sendable, Equatable {
    case pub = "PUBLIC"
    case proClient = "PRO_CLIENT"

    /// Public when either public surface is on; otherwise it stays between the pro
    /// and the client.
    public static func derived(
        isEligibleForLooks: Bool,
        isFeaturedInPortfolio: Bool
    ) -> MediaPostVisibility {
        (isEligibleForLooks || isFeaturedInPortfolio) ? .pub : .proClient
    }
}

/// The picked photo's progress from PhotosPicker to upload-ready bytes. Mirrors
/// web's file states (no file / preparing / ready / too big), which is what its
/// `getImageFileError` reports on.
public enum NewMediaPostImageState: Sendable, Equatable {
    /// Nothing picked yet.
    case none
    /// Picked; loading the transferable + encoding JPEG.
    case loading
    /// The pick could not be read or encoded.
    case failed
    /// Encoded and ready; `byteCount` is the JPEG's size.
    case ready(byteCount: Int)
}

/// The pro's in-progress post. A value type holding every choice the form
/// collects, deriving the submit gate + the exact request the service sends.
///
/// Deliberate divergences from web, both narrower rather than wider:
///   - **Images only.** Web also posts video; native picks with
///     `PhotosPicker(matching: .images)`. Video needs a poster frame and a
///     progress-tracked multi-MB upload, and the focal point this screen exists
///     to supply is face-detection on a still. Tracked as a parity gap.
///   - **No crop editor.** Web bakes a crop into the pixels; native keeps the
///     original and sends a focal point instead, so the Looks cover-crop centers
///     on the subject. That is this screen's whole reason for a web PR.
public struct NewMediaPostDraft: Sendable, Equatable {
    /// Matches web's `CAPTION_MAX` and the server's `MAX_CAPTION_LENGTH`.
    public static let captionMaxLength = 300
    /// Matches web's `PRICE_MAX_LENGTH`.
    public static let priceMaxLength = 20
    /// The signing route's hard cap (`app/api/v1/pro/uploads` rejects above this).
    /// Web's client allows far more and only fails at signing; native checks up
    /// front so the pro learns before the encode, not after.
    public static let imageMaxBytes = 30 * 1024 * 1024

    public var caption: String = ""
    /// The tagged services, in pick order.
    public var serviceIds: [String] = []
    /// The nominated primary; nil until the pro picks one (or only one is tagged).
    public var primaryServiceId: String?
    /// Private = visible only to the pro (media-private bucket, PRO_CLIENT). The
    /// pro can make it public later from their library.
    public var isPrivate: Bool = false
    public var isEligibleForLooks: Bool = false
    /// Web defaults this ON (`useState(true)`), so a pro who just picks a photo
    /// and posts gets it in their portfolio.
    public var isFeaturedInPortfolio: Bool = true
    public var lookVisibility: LookVisibility = .public
    public var priceStartingAt: String = ""
    public var image: NewMediaPostImageState = .none

    public init() {}

    // MARK: - Derived state

    /// Public when either surface is on. Web calls this `isPublicSelectionValid`.
    public var hasPublicSurface: Bool {
        isEligibleForLooks || isFeaturedInPortfolio
    }

    /// What the server will store. Read-only display; never sent.
    public var visibility: MediaPostVisibility {
        isPrivate
            ? .proClient
            : .derived(
                isEligibleForLooks: isEligibleForLooks,
                isFeaturedInPortfolio: isFeaturedInPortfolio
            )
    }

    /// A private post has no Looks settings — Looks is a public surface.
    public var showsLooksSettings: Bool { !isPrivate && isEligibleForLooks }

    /// The server requires an explicit primary once Looks is on and more than one
    /// service is tagged; with exactly one tag it infers it.
    ///
    /// ⚠️ Keyed on the RESOLVED primary, not the raw `primaryServiceId`. Web can
    /// ask `!primaryServiceId` because a `useEffect` clears the nomination the
    /// moment it leaves `serviceIds`; a value type has no such effect, so a stale
    /// nomination (picked, then un-tagged) would read as "primary chosen" while
    /// `resolvedPrimaryServiceId` correctly reports nil — and the post would sail
    /// past the gate into a 400 from the route's own guard.
    public var needsPrimaryService: Bool {
        !isPrivate && isEligibleForLooks && serviceIds.count > 1
            && resolvedPrimaryServiceId == nil
    }

    /// The primary actually sent: the nomination, or the lone tag when there is
    /// only one. Mirrors the route's `primaryServiceId ?? (serviceIds.length === 1 ? serviceIds[0] : null)`.
    public var resolvedPrimaryServiceId: String? {
        if let primaryServiceId, serviceIds.contains(primaryServiceId) { return primaryServiceId }
        return serviceIds.count == 1 ? serviceIds.first : nil
    }

    public var trimmedCaption: String {
        caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedPrice: String {
        priceStartingAt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Validation

    /// Web's `isValidPriceString`: digits, optionally one dot and up to 2 decimals.
    /// Blank is valid — the price is optional.
    public static func isValidPrice(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.wholeMatch(of: priceRegex) != nil
    }

    // ⚠️ Computed, not `static let` — swift-tools-version 6.0 makes `Regex`
    // non-Sendable, so a stored static would fail the concurrency check.
    // The group is non-capturing so the type stays `Regex<Substring>`; a capturing
    // one widens it to `Regex<(Substring, Substring?)>` and won't compile.
    private static var priceRegex: Regex<Substring> {
        /[0-9]+(?:\.[0-9]{1,2})?/
    }

    /// Web's `normalizeMoneyInput` — strip everything but digits and dots, then
    /// clamp the length. Applied as the pro types so the field can't hold junk.
    public static func normalizePriceInput(_ value: String) -> String {
        String(value.filter { $0.isNumber || $0 == "." }.prefix(priceMaxLength))
    }

    /// Every reason this post can't ship yet, in web's order. Empty == ready.
    /// The first is surfaced on the submit button, the rest in the "Before you can
    /// post:" list — same as web.
    public func blockingReasons(hasServiceOptions: Bool) -> [String] {
        var reasons: [String] = []

        switch image {
        case .none:
            reasons.append("Choose a photo to post.")
        case .loading:
            reasons.append("Preparing your photo…")
        case .failed:
            reasons.append("That photo couldn’t be read. Pick another one.")
        case let .ready(byteCount):
            if byteCount <= 0 {
                reasons.append("That photo looks empty.")
            } else if byteCount > Self.imageMaxBytes {
                reasons.append("That photo is too large. Pick a smaller one.")
            }
        }

        if !hasServiceOptions {
            reasons.append("No services found. Add at least one service before posting.")
        } else if serviceIds.isEmpty {
            reasons.append("Tag at least one service.")
        }

        // A private post has no public surface to pick — it's visible only to the pro.
        if !isPrivate && !hasPublicSurface {
            reasons.append("Select “Show in Looks” or “Show in Portfolio”.")
        }

        if needsPrimaryService {
            reasons.append("Choose one primary service for Looks when multiple services are selected.")
        }

        if !Self.isValidPrice(priceStartingAt) {
            reasons.append("Starting price must be a valid amount with up to 2 decimals.")
        }

        return reasons
    }

    public func canSubmit(hasServiceOptions: Bool) -> Bool {
        blockingReasons(hasServiceOptions: hasServiceOptions).isEmpty
    }

    // MARK: - The wire

    /// The `kind` the signing route needs. Drives which bucket the bytes land in,
    /// and the route cross-checks it against the visibility the create derives —
    /// a private post in the public bucket (or vice versa) is a 400.
    public var uploadKind: String {
        if isPrivate { return "PORTFOLIO_PRIVATE" }
        return isEligibleForLooks ? "LOOKS_PUBLIC" : "PORTFOLIO_PUBLIC"
    }

    /// The `POST /api/v1/pro/media` body for this draft.
    ///
    /// A private post sends neither Looks flags nor Looks settings: the route
    /// treats `isEligibleForLooks` as the gate for `publishToLooks`, and §19b
    /// turns any public asset into a LookPost. `focal` is omitted when the photo
    /// has no detectable subject — the server then centers, exactly as before.
    ///
    /// Internal: the request type is a wire detail, so the app target composes a
    /// draft and hands it to `ProMediaService.createPost` rather than building a
    /// body itself. `swift test` still reaches this via `@testable`.
    func createRequest(
        uploadSessionId: String,
        focal: MediaFocalPoint?
    ) -> ProMediaPostRequest {
        let looksOn = !isPrivate && isEligibleForLooks
        let featured = !isPrivate && isFeaturedInPortfolio
        let caption = trimmedCaption
        let price = trimmedPrice

        return ProMediaPostRequest(
            uploadSessionId: uploadSessionId,
            caption: caption.isEmpty ? nil : String(caption.prefix(Self.captionMaxLength)),
            mediaType: MediaType.image.rawValue,
            isFeaturedInPortfolio: featured,
            isEligibleForLooks: looksOn,
            publishToLooks: looksOn,
            serviceIds: serviceIds,
            primaryServiceId: looksOn ? resolvedPrimaryServiceId : nil,
            lookVisibility: looksOn ? lookVisibility.rawValue : nil,
            priceStartingAt: looksOn && !price.isEmpty ? price : nil,
            focalX: focal?.x,
            focalY: focal?.y
        )
    }
}
