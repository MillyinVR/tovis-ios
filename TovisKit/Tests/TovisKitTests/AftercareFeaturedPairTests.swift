import Foundation
import Testing
@testable import TovisKit

// Pure logic behind the pro's aftercare featured before/after pair picker
// (native counterpart to web's `featuredPairSeed.ts` + the `validFeatured*`
// guard). Partition/validation is unit-tested here without a SwiftUI host.
struct AftercareFeaturedPairTests {
    /// Build one `ProBookingMediaItem` JSON object with picker-relevant fields
    /// varied; the rest carry stable defaults.
    private func itemJSON(
        id: String, phase: String, type: String, createdAt: String
    ) -> String {
        """
        {
          "id": "\(id)", "mediaType": "\(type)", "visibility": "PRO_CLIENT",
          "phase": "\(phase)", "caption": null, "createdAt": "\(createdAt)",
          "reviewId": null, "isEligibleForLooks": true,
          "isFeaturedInPortfolio": false,
          "url": "https://x/\(id).jpg", "thumbUrl": "https://x/\(id)_t.jpg",
          "renderUrl": "https://x/\(id)_r.jpg", "renderThumbUrl": "https://x/\(id)_rt.jpg"
        }
        """
    }

    private func decodeItems(_ objects: [String]) throws -> [ProBookingMediaItem] {
        let json = "{ \"ok\": true, \"items\": [\(objects.joined(separator: ","))] }"
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ProBookingMediaListResponse.self, from: data).items
    }

    @Test func candidatesPartitionsSortsAndDropsVideos() throws {
        // Intentionally out of order + mixed phases/types.
        let items = try decodeItems([
            itemJSON(id: "b_late", phase: "BEFORE", type: "IMAGE", createdAt: "2026-07-15T18:00:00.000Z"),
            itemJSON(id: "b_early", phase: "BEFORE", type: "IMAGE", createdAt: "2026-07-15T17:00:00.000Z"),
            itemJSON(id: "a_img", phase: "AFTER", type: "IMAGE", createdAt: "2026-07-15T19:00:00.000Z"),
            itemJSON(id: "a_video", phase: "AFTER", type: "VIDEO", createdAt: "2026-07-15T19:30:00.000Z"),
            itemJSON(id: "b_video", phase: "BEFORE", type: "VIDEO", createdAt: "2026-07-15T16:00:00.000Z"),
            itemJSON(id: "other", phase: "OTHER", type: "IMAGE", createdAt: "2026-07-15T20:00:00.000Z"),
        ])

        let candidates = AftercareFeaturedPair.candidates(items)

        // BEFORE: images only, earliest-first; videos + OTHER excluded.
        #expect(candidates.before.map(\.id) == ["b_early", "b_late"])
        // AFTER: the video is dropped (featuring is image-only).
        #expect(candidates.after.map(\.id) == ["a_img"])
    }

    @Test func candidatesEmptyWhenNoBeforeAfterImages() throws {
        let items = try decodeItems([
            itemJSON(id: "v", phase: "AFTER", type: "VIDEO", createdAt: "2026-07-15T19:00:00.000Z"),
            itemJSON(id: "o", phase: "OTHER", type: "IMAGE", createdAt: "2026-07-15T20:00:00.000Z"),
        ])
        let candidates = AftercareFeaturedPair.candidates(items)
        #expect(candidates.before.isEmpty)
        #expect(candidates.after.isEmpty)
    }

    @Test func resolveValidFeaturedIdKeepsPresentDropsStaleAndNil() throws {
        let before = try decodeItems([
            itemJSON(id: "b1", phase: "BEFORE", type: "IMAGE", createdAt: "2026-07-15T17:00:00.000Z"),
        ])
        // Present → kept.
        #expect(AftercareFeaturedPair.resolveValidFeaturedId("b1", in: before) == "b1")
        // Stale / foreign / wrong-phase id → dropped (server would reject it).
        #expect(AftercareFeaturedPair.resolveValidFeaturedId("gone", in: before) == nil)
        // No selection stays nil (explicitly clears the pair).
        #expect(AftercareFeaturedPair.resolveValidFeaturedId(nil, in: before) == nil)
    }

    @Test func saveRequestEncodesFeaturedIdsWhenSet() throws {
        let request = ProAftercareSaveRequest(
            notes: "x", recommendedProducts: [], rebookMode: "NONE",
            rebookedFor: nil, rebookSlot: nil, rebookWindowStart: nil, rebookWindowEnd: nil,
            createRebookReminder: false, rebookReminderDaysBefore: 2,
            createProductReminder: false, productReminderDaysAfter: 7,
            featuredBeforeAssetId: "media_1", featuredAfterAssetId: "media_2",
            sendToClient: false, timeZone: "America/Los_Angeles", version: 2)

        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["featuredBeforeAssetId"] as? String == "media_1")
        #expect(object["featuredAfterAssetId"] as? String == "media_2")
    }

    @Test func saveRequestOmitsFeaturedIdsWhenNil() throws {
        // A nil selection is omitted from the body; the server coerces an absent
        // field to null, which clears any prior pair — the intended "clear".
        let request = ProAftercareSaveRequest(
            notes: "x", recommendedProducts: [], rebookMode: "NONE",
            rebookedFor: nil, rebookSlot: nil, rebookWindowStart: nil, rebookWindowEnd: nil,
            createRebookReminder: false, rebookReminderDaysBefore: 2,
            createProductReminder: false, productReminderDaysAfter: 7,
            featuredBeforeAssetId: nil, featuredAfterAssetId: nil,
            sendToClient: false, timeZone: nil, version: nil)

        let data = try JSONEncoder().encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["featuredBeforeAssetId"] == nil)
        #expect(object["featuredAfterAssetId"] == nil)
    }
}
