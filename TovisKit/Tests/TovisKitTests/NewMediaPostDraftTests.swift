import Foundation
import Testing
@testable import TovisKit

// Pins the "new media post" authoring rules against the web form they mirror
// (`app/pro/media/new/NewMediaPostForm.tsx`) and the route that re-validates them
// (`app/api/v1/pro/media/route.ts`). Both forms POST the same endpoint, so a rule
// that drifts here either blocks a legal post or ships one the server 400s AFTER
// the bytes are already in the bucket.
//
// The bar: every blocking reason, the derived visibility, the primary-service
// inference, and the exact body each draft shape puts on the wire.

@Suite struct NewMediaPostDraftTests {
    /// A draft that is ready to post: a photo, one tagged service, portfolio on
    /// (web's default). The minimum viable post.
    private func readyDraft() -> NewMediaPostDraft {
        var draft = NewMediaPostDraft()
        draft.image = .ready(byteCount: 1_024)
        draft.serviceIds = ["service_1"]
        return draft
    }

    // MARK: - Defaults

    @Test("A fresh draft matches web's defaults: portfolio on, Looks off, public")
    func defaultsMatchWeb() {
        let draft = NewMediaPostDraft()
        // Web: useState(true) for portfolio, false for Looks — so a pro who picks a
        // photo and posts gets it in their portfolio and NOT in the feed.
        #expect(draft.isFeaturedInPortfolio)
        #expect(!draft.isEligibleForLooks)
        #expect(!draft.isPrivate)
        #expect(draft.lookVisibility == .public)
        #expect(draft.visibility == .pub)
    }

    // MARK: - Blocking reasons

    @Test("A ready draft blocks on nothing")
    func readyDraftCanSubmit() {
        #expect(readyDraft().blockingReasons(hasServiceOptions: true).isEmpty)
        #expect(readyDraft().canSubmit(hasServiceOptions: true))
    }

    @Test("Each image state reports web's matching reason")
    func imageStateReasons() {
        var draft = readyDraft()

        draft.image = .none
        #expect(draft.blockingReasons(hasServiceOptions: true) == ["Choose a photo to post."])

        draft.image = .loading
        #expect(draft.blockingReasons(hasServiceOptions: true) == ["Preparing your photo…"])

        draft.image = .failed
        #expect(draft.blockingReasons(hasServiceOptions: true) == ["That photo couldn’t be read. Pick another one."])

        // Web calls a 0-byte file out separately from a missing one — a picked-but-
        // empty photo is a different problem from not having picked.
        draft.image = .ready(byteCount: 0)
        #expect(draft.blockingReasons(hasServiceOptions: true) == ["That photo looks empty."])

        draft.image = .ready(byteCount: NewMediaPostDraft.imageMaxBytes + 1)
        #expect(draft.blockingReasons(hasServiceOptions: true) == ["That photo is too large. Pick a smaller one."])

        // Exactly at the cap is allowed — the signing route rejects ABOVE it.
        draft.image = .ready(byteCount: NewMediaPostDraft.imageMaxBytes)
        #expect(draft.blockingReasons(hasServiceOptions: true).isEmpty)
    }

    @Test("No service options blocks differently from none picked")
    func serviceReasons() {
        var draft = readyDraft()

        draft.serviceIds = []
        #expect(draft.blockingReasons(hasServiceOptions: true) == ["Tag at least one service."])

        // A pro with no services at all can't fix this by tagging — web sends them
        // to go add one.
        #expect(
            draft.blockingReasons(hasServiceOptions: false)
                == ["No services found. Add at least one service before posting."]
        )
    }

    @Test("A public post with neither surface on has nowhere to go")
    func publicPostNeedsASurface() {
        var draft = readyDraft()
        draft.isFeaturedInPortfolio = false
        draft.isEligibleForLooks = false

        #expect(
            draft.blockingReasons(hasServiceOptions: true)
                == ["Select “Show in Looks” or “Show in Portfolio”."]
        )
        #expect(draft.visibility == .proClient)
    }

    @Test("A private post needs no surface — it IS the destination")
    func privatePostNeedsNoSurface() {
        var draft = readyDraft()
        draft.isPrivate = true
        draft.isFeaturedInPortfolio = false
        draft.isEligibleForLooks = false

        #expect(draft.blockingReasons(hasServiceOptions: true).isEmpty)
        #expect(draft.visibility == .proClient)
    }

    @Test("Reasons stack in web's order")
    func reasonsStack() {
        var draft = NewMediaPostDraft()
        draft.image = .none
        draft.serviceIds = []
        draft.isFeaturedInPortfolio = false
        draft.priceStartingAt = "abc"

        #expect(
            draft.blockingReasons(hasServiceOptions: true) == [
                "Choose a photo to post.",
                "Tag at least one service.",
                "Select “Show in Looks” or “Show in Portfolio”.",
                "Starting price must be a valid amount with up to 2 decimals.",
            ]
        )
    }

    // MARK: - Primary service

    @Test("A primary is required only for Looks with more than one tag")
    func primaryServiceRule() {
        var draft = readyDraft()
        draft.isEligibleForLooks = true

        // One tag → the server infers it, no nomination needed.
        #expect(!draft.needsPrimaryService)
        #expect(draft.resolvedPrimaryServiceId == "service_1")

        draft.serviceIds = ["service_1", "service_2"]
        #expect(draft.needsPrimaryService)
        #expect(draft.resolvedPrimaryServiceId == nil)
        #expect(
            draft.blockingReasons(hasServiceOptions: true)
                == ["Choose one primary service for Looks when multiple services are selected."]
        )

        draft.primaryServiceId = "service_2"
        #expect(!draft.needsPrimaryService)
        #expect(draft.resolvedPrimaryServiceId == "service_2")
        #expect(draft.blockingReasons(hasServiceOptions: true).isEmpty)
    }

    @Test("Portfolio-only and private posts never demand a primary")
    func primaryNotNeededWithoutLooks() {
        var draft = readyDraft()
        draft.serviceIds = ["service_1", "service_2"]

        // Portfolio-only: the route falls back to the first tag itself.
        #expect(!draft.needsPrimaryService)

        draft.isPrivate = true
        draft.isEligibleForLooks = true
        #expect(!draft.needsPrimaryService)
    }

    @Test("A primary that was un-tagged stops counting")
    func staleprimaryIsIgnored() {
        var draft = readyDraft()
        draft.isEligibleForLooks = true
        draft.serviceIds = ["service_1", "service_2"]
        draft.primaryServiceId = "service_2"
        #expect(draft.resolvedPrimaryServiceId == "service_2")

        // The pro un-tags the service they'd nominated. The route rejects a primary
        // outside serviceIds ("primaryServiceId must be included in serviceIds"), so
        // a stale nomination must not survive into the body.
        draft.serviceIds = ["service_1", "service_3"]
        #expect(draft.resolvedPrimaryServiceId == nil)
        #expect(draft.needsPrimaryService)
    }

    // MARK: - Price

    @Test("Price accepts web's format and nothing else", arguments: [
        ("", true), ("85", true), ("85.0", true), ("85.00", true), ("0", true),
        ("  85.00  ", true),
        ("85.000", false), ("85.", false), (".85", false), ("abc", false),
        ("8 5", false), ("-5", false), ("85.00.00", false),
    ])
    func priceValidation(value: String, expected: Bool) {
        #expect(NewMediaPostDraft.isValidPrice(value) == expected)
    }

    @Test("Price input is normalized as the pro types")
    func priceNormalization() {
        #expect(NewMediaPostDraft.normalizePriceInput("$85.00") == "85.00")
        #expect(NewMediaPostDraft.normalizePriceInput("8a5b.0c0") == "85.00")
        #expect(
            NewMediaPostDraft.normalizePriceInput(String(repeating: "9", count: 40)).count
                == NewMediaPostDraft.priceMaxLength
        )
    }

    // MARK: - Visibility derivation

    @Test("Visibility is derived from the surface flags, never chosen")
    func visibilityDerivation() {
        #expect(MediaPostVisibility.derived(isEligibleForLooks: false, isFeaturedInPortfolio: false) == .proClient)
        #expect(MediaPostVisibility.derived(isEligibleForLooks: true, isFeaturedInPortfolio: false) == .pub)
        #expect(MediaPostVisibility.derived(isEligibleForLooks: false, isFeaturedInPortfolio: true) == .pub)
        #expect(MediaPostVisibility.derived(isEligibleForLooks: true, isFeaturedInPortfolio: true) == .pub)
    }

    @Test("Private wins over the flags")
    func privateOverridesFlags() {
        var draft = readyDraft()
        draft.isPrivate = true
        draft.isEligibleForLooks = true
        draft.isFeaturedInPortfolio = true
        // The flags are stale UI state behind the privacy switch; the post is private.
        #expect(draft.visibility == .proClient)
        #expect(!draft.showsLooksSettings)
    }

    // MARK: - Upload kind

    @Test("The upload kind routes the bytes to the bucket the create expects")
    func uploadKind() {
        var draft = readyDraft()
        #expect(draft.uploadKind == "PORTFOLIO_PUBLIC")

        draft.isEligibleForLooks = true
        #expect(draft.uploadKind == "LOOKS_PUBLIC")

        // Private → the private bucket. The route cross-checks bucket vs derived
        // visibility and 400s on a mismatch, so this MUST track `visibility`.
        draft.isPrivate = true
        #expect(draft.uploadKind == "PORTFOLIO_PRIVATE")
        #expect(draft.visibility == .proClient)
    }

    // MARK: - The request body

    @Test("A Looks post sends its Looks settings")
    func looksRequestBody() {
        var draft = readyDraft()
        draft.isEligibleForLooks = true
        draft.caption = "  Balayage day  "
        draft.serviceIds = ["service_1", "service_2"]
        draft.primaryServiceId = "service_2"
        draft.lookVisibility = .followersOnly
        draft.priceStartingAt = " 85.00 "

        let request = draft.createRequest(
            uploadSessionId: "us_1",
            focal: MediaFocalPoint(x: 0.4, y: 0.3)
        )

        #expect(request.uploadSessionId == "us_1")
        #expect(request.caption == "Balayage day")
        #expect(request.mediaType == "IMAGE")
        #expect(request.isEligibleForLooks)
        #expect(request.publishToLooks)
        #expect(request.isFeaturedInPortfolio)
        #expect(request.serviceIds == ["service_1", "service_2"])
        #expect(request.primaryServiceId == "service_2")
        #expect(request.lookVisibility == "FOLLOWERS_ONLY")
        #expect(request.priceStartingAt == "85.00")
        #expect(request.focalX == 0.4)
        #expect(request.focalY == 0.3)
    }

    @Test("A private post sends no Looks flags or settings")
    func privateRequestBody() {
        var draft = readyDraft()
        draft.isPrivate = true
        // Stale UI state from before the pro flipped it private — none of it may leak.
        draft.isEligibleForLooks = true
        draft.isFeaturedInPortfolio = true
        draft.lookVisibility = .unlisted
        draft.priceStartingAt = "85.00"

        let request = draft.createRequest(uploadSessionId: "us_1", focal: nil)

        // §19b makes ANY public asset a LookPost, so a leaked flag here would
        // publish a post the pro explicitly marked private.
        #expect(!request.isEligibleForLooks)
        #expect(!request.publishToLooks)
        #expect(!request.isFeaturedInPortfolio)
        #expect(request.lookVisibility == nil)
        #expect(request.priceStartingAt == nil)
        #expect(request.primaryServiceId == nil)
    }

    @Test("A portfolio-only post sends no Looks settings")
    func portfolioOnlyRequestBody() {
        var draft = readyDraft()
        draft.lookVisibility = .unlisted
        draft.priceStartingAt = "85.00"

        let request = draft.createRequest(uploadSessionId: "us_1", focal: nil)

        #expect(request.isFeaturedInPortfolio)
        #expect(!request.isEligibleForLooks)
        #expect(!request.publishToLooks)
        // The route 400s `publishToLooks` without `isEligibleForLooks`; these three
        // must move together.
        #expect(request.lookVisibility == nil)
        #expect(request.priceStartingAt == nil)
    }

    @Test("An empty caption is omitted, and a long one is clamped to the server's max")
    func captionHandling() {
        var draft = readyDraft()

        draft.caption = "   \n  "
        #expect(draft.createRequest(uploadSessionId: "us_1", focal: nil).caption == nil)

        draft.caption = String(repeating: "a", count: 400)
        let clamped = draft.createRequest(uploadSessionId: "us_1", focal: nil).caption
        #expect(clamped?.count == NewMediaPostDraft.captionMaxLength)
    }

    @Test("No focal is omitted rather than zeroed")
    func focalOmitted() {
        let request = readyDraft().createRequest(uploadSessionId: "us_1", focal: nil)
        // A (0,0) focal is a legal top-left crop — sending it for "no face found"
        // would corner every faceless photo instead of centering it.
        #expect(request.focalX == nil)
        #expect(request.focalY == nil)
    }
}
