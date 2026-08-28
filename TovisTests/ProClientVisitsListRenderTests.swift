import Testing
import SwiftUI
import UIKit

@testable import Tovis
import TovisKit

/// Renders the merged visit card and asserts on the PIXELS.
///
/// The chart's visit list is only reachable behind a `NavigationLink`, synthetic
/// taps do not reach Simulator.app, and this project has no UI-test target — so
/// "the card looks right" had no way to be checked, which is exactly how a
/// build-green, unit-tested screen ships broken. `ImageRenderer` needs no taps:
/// it draws the real view with real data, in a chosen colour scheme, and the
/// resulting bitmap is the evidence.
@Suite struct ProClientVisitsListRenderTests {
    /// A visit with two frames, one without, and one belonging to another pro —
    /// the three cases the card renders differently.
    private func visits() -> [ProChartBooking] {
        let json = """
        [
          {"id":"bk_1","status":"COMPLETED","scheduledFor":"2026-07-01T17:00:00.000Z",
           "timeZone":"America/Los_Angeles","serviceName":"Balayage","categoryName":"Hair",
           "proName":"Studio Lumen","isMine":true,
           "relationshipBadge":{"kind":"RR","label":"RR","description":"Returning client",
                                "tone":"neutral","significant":true},
           "total":"180.00","durationMinutes":90,"aftercareNotes":"Gloss refresh in 6 weeks.",
           "photos":[
             {"id":"p1","bookingId":"bk_1","phase":"BEFORE","caption":null,"isMine":true,
              "serviceName":"Balayage","when":"2026-07-01T19:00:00.000Z","imageUrl":"https://x/b.jpg"},
             {"id":"p2","bookingId":"bk_1","phase":"AFTER","caption":null,"isMine":true,
              "serviceName":"Balayage","when":"2026-07-01T19:00:00.000Z","imageUrl":"https://x/a.jpg"}]},
          {"id":"bk_2","status":"NO_SHOW","scheduledFor":"2026-06-01T17:00:00.000Z",
           "timeZone":"America/Los_Angeles","serviceName":"Root Touch-Up","categoryName":"Hair",
           "proName":"Studio Lumen","isMine":true,"relationshipBadge":null,
           "total":"90.00","durationMinutes":45,"aftercareNotes":null,"photos":[]},
          {"id":"bk_3","status":"COMPLETED","scheduledFor":"2026-05-01T17:00:00.000Z",
           "timeZone":"America/Los_Angeles","serviceName":"Cut","categoryName":"Hair",
           "proName":"Other Pro","isMine":false,"relationshipBadge":null,
           "total":"60.00","durationMinutes":30,"aftercareNotes":null,
           "photos":[{"id":"p3","bookingId":"bk_3","phase":"AFTER","caption":null,"isMine":false,
                      "serviceName":"Cut","when":"2026-05-01T19:00:00.000Z","imageUrl":"https://x/c.jpg"}]}
        ]
        """
        return try! JSONDecoder().decode([ProChartBooking].self, from: Data(json.utf8))
    }

    @MainActor
    private func render(_ scheme: ColorScheme) -> UIImage? {
        let view = ProClientVisitsList(visits: visits(), viewingMedia: .constant(nil))
            .frame(width: 390)
            .padding(16)
            .background(BrandColor.bgPrimary)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }

    /// Both modes, written out for a human to look at. Rendering BOTH is the
    /// point: a token that is safe against a surface can vanish against a photo
    /// in exactly one of them, and either mode alone would ship the other's bug.
    @MainActor
    @Test func rendersInBothColourSchemes() throws {
        for (scheme, name) in [(ColorScheme.dark, "dark"), (ColorScheme.light, "light")] {
            let image = try #require(render(scheme), "ImageRenderer produced no image (\(name))")
            #expect(image.size.width > 0 && image.size.height > 0)

            // Written into the app container so a human can pull it out with
            // `simctl get_app_container` and actually LOOK at it. A render test
            // whose output nobody can see only proves "did not crash".
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let png = image.pngData() {
                let url = docs.appendingPathComponent("visits-\(name).png")
                try? png.write(to: url)
                print("RENDERED \(name): \(url.path)")
            }
        }
    }

    /// A card list that draws nothing would still "render", so pin the layout
    /// the merge is actually FOR: a visit with frames is taller than one without
    /// by at least a photo tile, and a visit without frames grows the card by
    /// nothing at all.
    @MainActor
    @Test func aVisitWithFramesIsTallerByAWholeTile() throws {
        let all = visits()
        let withPhotos = try #require(all.first { $0.id == "bk_1" })
        let withoutPhotos = try #require(all.first { $0.id == "bk_2" })

        func height(_ visits: [ProChartBooking]) throws -> CGFloat {
            let renderer = ImageRenderer(
                content: ProClientVisitsList(visits: visits, viewingMedia: .constant(nil))
                    .frame(width: 390))
            renderer.scale = 1
            return try #require(renderer.uiImage).size.height
        }

        let tall = try height([withPhotos])
        let short = try height([withoutPhotos])

        // A 96pt tile row, so the grid is REAL layout rather than a branch that
        // renders to nothing. The photo-less card is the control: if the grid
        // leaked onto every card this difference would collapse.
        #expect(tall - short >= 96)
    }
}
