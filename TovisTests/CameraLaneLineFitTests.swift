// Does the coach's longest REAL sentence survive the lane it has to live in?
//
// The lane is one row, 56pt, fixed (`CameraCoachLane.swift`). Its sentence is
// allowed two lines and may be scaled down to `CameraLane.minimumTextScale`
// before SwiftUI starts dropping words instead — and a line that reads
// beautifully in a string literal and loses its tail on a phone has not been
// shipped, it has been written. That failure has happened here before, and it
// was caught by LOOKING at the surface rather than by a test.
//
// So this measures the REAL strings — every line `CoachBookingVocabulary` can
// build, swept off `CoachMoment.allCases` rather than off a list someone typed
// — in the REAL font at the REAL floor size, against the REAL lane geometry,
// on the narrowest phone the app supports and on the widest.
//
// It then renders those same strings through the production `CameraLaneView`
// and writes the PNGs to the test process's temp directory, printing the host
// path — because the arithmetic is a proxy and the rendered lane is the thing
// being shipped.
import CoreText
import SwiftUI
import Testing
import UIKit
@testable import Tovis

@MainActor
@Suite struct CameraLaneLineFitTests {
    /// Screen widths in points: the narrowest iPhone the app supports, the
    /// common Pro, and the widest (`430` is also this codebase's layout cap).
    private let screenWidths: [CGFloat] = [375, 393, 430]

    /// The worst booking the vocabulary will accept: a name at the character
    /// limit and a service noun at the character limit. Anything longer is
    /// refused by the derivation, so nothing the app can build exceeds this.
    private var worstCase: CoachBookingVocabulary {
        CoachBookingVocabulary(serviceName: String(repeating: "w", count:
                                                   CoachBookingVocabulary.maxWorkNounLength),
                               clientFullName: String(repeating: "N", count: 14))
    }

    // MARK: - The real geometry

    /// What's left for the sentence on a screen `width` points wide, once the
    /// lane's own insets, the state dot, the spacing and the trailing expand
    /// chevron are taken off — the row a coach tip actually renders as
    /// (`showsDot: true`, `expandable: true`, no action word).
    private func textWidth(screen: CGFloat) -> CGFloat {
        let chevron = UIImage(systemName: "chevron.up")?.size.width ?? 16
        return screen
            - CameraLane.outerInset * 2
            - CameraLane.rowInset * 2
            - (CameraLane.dotSize + CameraLane.itemSpacing)
            - (chevron + CameraLane.itemSpacing)
    }

    /// Every face of the lane's family, at the smallest size SwiftUI may shrink
    /// the sentence to.
    ///
    /// All of them rather than the semibold the view asks for: Space Grotesk
    /// ships as a variable font whose registered members resolve through one
    /// another (asking a descriptor for `.semibold` hands back the same face),
    /// and its heavier masters actually set very slightly NARROWER. Measuring
    /// the whole family and taking the worst is a fact; picking one face and
    /// assuming it's the widest is the thing this file exists to stop.
    private var flooredFaces: [UIFont] {
        let size = CameraLane.textPointSize * CameraLane.minimumTextScale
        let faces = UIFont.fontNames(forFamilyName: "Space Grotesk")
            .compactMap { UIFont(name: $0, size: size) }
        return faces.isEmpty ? [UIFont.systemFont(ofSize: size, weight: .semibold)] : faces
    }

    /// The most lines this string lays out onto at that width, across the
    /// family — i.e. the worst the lane could do with it.
    private func laidOutLines(_ text: String, width: CGFloat) -> Int {
        flooredFaces.map { font in
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 10_000), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nil)
            return CFArrayGetCount(CTFrameGetLines(frame))
        }.max() ?? 0
    }

    // MARK: - Every line the vocabulary can build

    /// Swept off the enum, not off prose: a moment added later that the
    /// vocabulary writes a line for is measured here without anyone
    /// remembering to add it (the lesson from the spec-may-be-lying set).
    private func everyVocabularyLine(_ vocabulary: CoachBookingVocabulary? = nil) -> [String] {
        let vocabulary = vocabulary ?? worstCase
        let contexts = [
            CoachPhraseContext(namesAPerson: true),
            CoachPhraseContext(direction: "right", namesAPerson: true),
            CoachPhraseContext(),
        ]
        var seen: Set<String> = []
        return CoachMoment.allCases.flatMap { moment in
            contexts.compactMap { ctx in
                vocabulary.line(replacing: CoachNudge(category: .composition, message: "canonical",
                                                      moment: moment, phraseCtx: ctx))
            }
        }.filter { seen.insert($0).inserted }
    }

    @Test func theLongestLineTheVocabularyCanBuildStillFitsTheLane() {
        let lines = everyVocabularyLine()
        #expect(!lines.isEmpty, "the sweep found no vocabulary lines — it has stopped measuring anything")
        for width in screenWidths {
            let available = textWidth(screen: width)
            for line in lines {
                let used = laidOutLines(line, width: available)
                #expect(used <= CameraLane.maxTextLines,
                        "\(Int(width))pt: “\(line)” needs \(used) lines in \(Int(available))pt")
            }
        }
    }

    /// The control: today's canonical lines must still fit too — including the
    /// one the lane's own comment calls its longest instruction.
    @Test func todaysCanonicalLinesStillFit() {
        let canonical = [
            "Light’s behind them — turn them to face the window",
            "Their face is blown out — turn away from the bright light",
            "They’re outside the feed crop — center them",
            "Move in closer — fill the frame",
            "Mixed light — turn off the overheads",
        ]
        for width in screenWidths {
            let available = textWidth(screen: width)
            for line in canonical {
                #expect(laidOutLines(line, width: available) <= CameraLane.maxTextLines,
                        "\(Int(width))pt: canonical “\(line)” no longer fits")
            }
        }
    }

    // MARK: - Looking at it

    /// The arithmetic above says the sentences fit. This renders them through
    /// the PRODUCTION `CameraLaneView` at every supported width and writes the
    /// picture out, because the thing being SHIPPED is a rendered lane, not a
    /// line count — and the last time this surface lost a tail, a person
    /// looking at it is what caught it.
    ///
    /// The file lands in the test process's temporary directory (the host path
    /// is printed); nothing in the repo is touched, and CI simply discards it.
    @Test func rendersEveryVocabularyLineThroughTheRealLane() throws {
        // Both halves matter: the worst booking the derivation will ACCEPT
        // (which is what the assertions above are about) and an ordinary one
        // (which is what a pro actually reads mid-session).
        let ordinary = CoachBookingVocabulary(serviceName: "Caramel Balayage",
                                              clientFullName: "Maya Lopez")
        let lines = everyVocabularyLine().sorted { $0.count > $1.count }
            + everyVocabularyLine(ordinary)
        for width in screenWidths {
            let view = VStack(spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    CameraLaneView(
                        message: LaneMessage(text: line, tone: .warn, expandable: true, pulses: true),
                        backgroundBusy: false, onAction: { _ in }, onExpand: {},
                        accessibilityValue: line)
                }
            }
            .frame(width: width)
            .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.uiImage)
            let png = try #require(image.pngData())
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tovis-lane-\(Int(width))pt.png")
            try png.write(to: url)
            print("LANE SNAPSHOT \(Int(width))pt → \(url.path)")
        }
    }
}
