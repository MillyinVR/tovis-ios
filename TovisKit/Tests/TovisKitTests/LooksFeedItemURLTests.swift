import Foundation
import Testing
@testable import TovisKit

// The grid tile's image source.
//
// This exists because the tile got its URL wrong for a whole class of look and
// nobody could see it: written at the call site as
// `(look.thumbUrl ?? look.url).flatMap(URL.init(string:))`, Swift resolves the
// `??` at `String??` — the left side is then never nil, `look.url` is dead, and
// a look whose row carries no `thumbUrl` renders the placeholder sheen instead
// of its own image. The compiler said so ("left side of nil coalescing operator
// '??' has non-optional type 'String?'") and the warning was carried for a
// while as cosmetic. It was not cosmetic.
//
// So the fallback is asserted here, on the model, in the suite CI actually runs
// — not left implicit in a SwiftUI body no test target compiles.

@Suite("Looks feed item — tile URL")
struct LooksFeedItemURLTests {
    /// Minimal wire shape; only the fields this property reads have to be real.
    private func item(url: String, thumbUrl: String?) throws -> LooksFeedItem {
        let thumb = thumbUrl.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": "look_1",
          "url": "\(url)",
          "thumbUrl": \(thumb),
          "mediaType": "IMAGE",
          "caption": null,
          "createdAt": "2026-08-05T00:00:00.000Z",
          "professional": null,
          "clientAuthor": null,
          "_count": { "likes": 0, "comments": 0 },
          "viewerLiked": false,
          "viewerSaved": false,
          "viewerFollows": false,
          "serviceId": null,
          "serviceName": null,
          "category": null,
          "priceStartingAt": null,
          "focalX": null,
          "focalY": null,
          "before": null,
          "tags": null
        }
        """
        return try JSONDecoder().decode(LooksFeedItem.self, from: Data(json.utf8))
    }

    @Test("Prefers the thumb when the row has one")
    func prefersThumb() throws {
        let look = try item(url: "https://cdn.example/full.jpg",
                            thumbUrl: "https://cdn.example/thumb.jpg")
        #expect(look.thumbOrFullURL?.absoluteString == "https://cdn.example/thumb.jpg")
    }

    /// The regression. Before the fix this returned nil and the tile rendered
    /// `CardSheen()` — a look that HAS an image showing as a placeholder.
    @Test("Falls back to the full asset when the row has no thumb")
    func fallsBackToFullURL() throws {
        let look = try item(url: "https://cdn.example/full.jpg", thumbUrl: nil)
        #expect(look.thumbOrFullURL?.absoluteString == "https://cdn.example/full.jpg")
    }

    @Test("Unparseable bytes degrade to nil rather than a bad URL")
    func unparseableIsNil() throws {
        let look = try item(url: "", thumbUrl: nil)
        #expect(look.thumbOrFullURL == nil)
    }
}
