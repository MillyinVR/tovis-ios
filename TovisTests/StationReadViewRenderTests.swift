// The station read's own screens, rendered and written out (camera plan
// P4.2). The setup sheet is its OWN surface, not the camera lane — so it is
// rendered HERE, the way `CameraLaneLineFitTests` renders the lane: every
// state, at the narrowest and widest supported widths, to a PNG a person can
// look at. The overlay is split from the live preview precisely so this can
// run without a capture session.
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Tovis

@MainActor
@Suite struct StationReadViewRenderTests {
    private let screenWidths: [CGFloat] = [375, 430]

    private func write(_ view: some View, width: CGFloat, name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Color.black))
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let png = try #require(image.pngData())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovis-station-\(name)-\(Int(width))pt.png")
        try png.write(to: url)
        print("STATION READ SNAPSHOT \(name) \(Int(width))pt → \(url.path)")
    }

    /// Every state the sheet's overlay can show, including the longest
    /// summary a read can produce and both refusals.
    @Test func rendersEveryOverlayState() throws {
        let longest = CoachStationRead.Profile(
            warmth: 0, greenTint: CoachTuning.greenCastTint + 0.05,
            thirdWarmths: [min(-0.1, CoachTuning.warmCastWarmth - 0.5),
                           CoachTuning.mixedLightSpread + 0.1,
                           CoachTuning.mixedLightSpread + 0.1],
            readAt: .distantPast)
        let phases: [StationReadOverlay.Phase] = [
            .aiming,
            .reading,
            .done(summary: longest.summary),
            .refused(message: "Someone’s in frame — this read is of the empty station, so the room’s light isn’t mixed up with skin and clothes."),
            .refused(message: "Too dark to read. Bring the room up to the light you actually shoot in, then try again."),
        ]
        for width in screenWidths {
            let view = VStack(spacing: 8) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                    StationReadOverlay(phase: phase, onRead: {}, onDone: {})
                }
            }
            try write(view, width: width, name: "overlay")
        }
    }

    /// The hub's two states: the invitation card, and the summary row with
    /// the re-read affordance — driven off a throwaway defaults suite so the
    /// render can't see or touch a real pro's rooms.
    @Test func rendersTheHubCardAndTheSummaryRow() throws {
        let suite = "tovis.test.station.render"
        UserDefaults().removePersistentDomain(forName: suite)
        let store = UserDefaults(suiteName: suite)!
        CoachRoomMemory(locationId: "loc-render", locationType: "SALON", store: store)!
            .recordStationRead(CoachStationRead.Profile(
                warmth: CoachTuning.warmCastWarmth + 0.05, greenTint: 0,
                thirdWarmths: [min(-0.1, CoachTuning.warmCastWarmth - 0.5),
                               CoachTuning.mixedLightSpread + 0.1,
                               CoachTuning.mixedLightSpread + 0.1],
                readAt: Date()))
        for width in screenWidths {
            let view = VStack(spacing: 8) {
                // No read yet → the invitation card.
                StationReadHubSection(locationId: "loc-unread", locationType: "SALON",
                                      refresh: 0, onRead: {}, store: store)
                // A recorded read → the summary row.
                StationReadHubSection(locationId: "loc-render", locationType: "SALON",
                                      refresh: 0, onRead: {}, store: store)
            }
            .padding(16)
            try write(view, width: width, name: "hub")
        }
        // …and the rule that the section renders NOTHING off a salon is the
        // memory's own `init?`, exercised here so a refactor that widens the
        // section can't silently show setup chrome on a mobile booking.
        #expect(CoachRoomMemory(locationId: "loc-x", locationType: "MOBILE", store: store) == nil)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
