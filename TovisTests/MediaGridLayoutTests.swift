import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Tovis

// The geometry contract behind every uniform media grid (portfolio, my-media,
// review shots).
//
// 🔴 Why this suite exists: a pro reported the Profile tab's portfolio "media
// overlapping" and "not the same size". The cause was that a cell's size was
// being derived from the CONTENT — a `scaledToFill` image inside a ZStack under
// a height-only `.frame` reports the size it needs to cover its proposal, the
// ZStack reports the union of its children, and so a 4032×3024 upload made its
// own cell ~146pt wide inside a 114pt column and drew over its neighbour. Every
// source aspect produced a different width, so the row was uneven as well as
// overlapping.
//
// Layout itself isn't unit-testable here (this repo has no view-inspection
// harness — views are confirmed by screenshot), so what these tests pin is the
// arithmetic and the shared constants the layout is built from: a row's cells
// exactly fill their container, and every KIND of cell in a grid agrees on one
// aspect ratio. The second is not academic — the pro's portfolio put a
// hard-coded 120pt-tall before/after slider in the same row as aspect-derived
// photo tiles, which is the other half of what "uneven" meant.
@MainActor
@Suite struct MediaGridLayoutTests {

    // MARK: - A row fills its container and never exceeds it

    @Test func threeColumnsAndTheirGapsFillTheContainerExactly() {
        // The pro Profile tab's portfolio: 402pt screen − 20pt padding each side.
        let container: CGFloat = 362
        let spacing: CGFloat = 10
        let width = MediaGridLayout.columnWidth(container: container, count: 3, spacing: spacing)

        #expect(abs(width - 114) < 0.001)
        // Three cells plus two gaps == the container. Not "≈", not "under" — a
        // row that adds up to more than this is a row that overlaps.
        #expect(abs((width * 3 + spacing * 2) - container) < 0.001)
    }

    @Test func columnWidthNeverOverflowsAtAnyRealisticSize() {
        // Every width/spacing/count combination the four grids actually use.
        for container in stride(from: CGFloat(280), through: 1000, by: 13) {
            for spacing in [CGFloat(2), 8, 10] {
                for count in [2, 3] {
                    let width = MediaGridLayout.columnWidth(container: container, count: count, spacing: spacing)
                    let row = width * CGFloat(count) + spacing * CGFloat(count - 1)
                    #expect(row <= container + 0.001, "row \(row) overflows \(container)")
                    #expect(width > 0)
                }
            }
        }
    }

    @Test func aDegenerateColumnCountIsZeroWidthRatherThanACrash() {
        #expect(MediaGridLayout.columnWidth(container: 362, count: 0, spacing: 10) == 0)
        // A container narrower than its own gutters clamps at 0 instead of
        // going negative and inverting the layout.
        #expect(MediaGridLayout.columnWidth(container: 10, count: 3, spacing: 40) == 0)
    }

    @Test func columnsBuildsAnAdaptiveColumnThatPacksTheRequestedCountAtPhoneWidth() {
        // `columns` now hands the grid ONE adaptive GridItem instead of
        // `count` flexible ones — the grid itself decides how many columns
        // actually fit, so a wider container (iPad) gets more columns rather
        // than `count` tiles stretched across the extra width. The `count`
        // parameter still pins the phone-width behavior: at a phone-sized
        // container the adaptive minimum must land on exactly `count` columns,
        // matching how every one of these grids was originally tuned.
        for (count, spacing) in [(3, CGFloat(10)), (2, CGFloat(2))] {
            let columns = MediaGridLayout.columns(count: count, spacing: spacing)
            #expect(columns.count == 1)
            guard case let .adaptive(minimum, _) = columns[0].size else {
                Issue.record("expected an adaptive GridItem")
                continue
            }
            #expect(columns[0].spacing == spacing)

            let phoneContainer: CGFloat = 358
            let phonePacked = Int((phoneContainer + spacing) / (minimum + spacing))
            #expect(phonePacked == count,
                    "minimum \(minimum) packs \(phonePacked) columns at phone width, expected \(count)")

            let ipadContainer: CGFloat = 900
            let ipadPacked = Int((ipadContainer + spacing) / (minimum + spacing))
            #expect(ipadPacked > count,
                    "adaptive minimum \(minimum) didn't add columns on a wider container")
        }
    }

    // MARK: - Fill-crop overflows the cell; the cell must not absorb it

    @Test func aLandscapeSourceOverflowsTheCellHorizontallyAndMustBeClipped() {
        // The exact upload that produced the report: 4032×3024 in a 3:4 cell.
        let cell = CGSize(width: 114, height: 114 / MediaGridLayout.portraitAspect)
        let filled = MediaGridLayout.filledContentSize(source: CGSize(width: 4032, height: 3024), in: cell)

        // Fill covers the cell's height exactly and spills sideways — that spill
        // is what `.clipped()` removes and what must NEVER reach the cell's own
        // width. This is the regression, stated as a number.
        #expect(abs(filled.height - cell.height) < 0.001)
        #expect(filled.width > cell.width)
        #expect(abs(filled.width - 202.666) < 0.01)
    }

    @Test func aPortraitSourceOverflowsVerticallyInstead() {
        let cell = CGSize(width: 114, height: 114)   // square (my-media, reviews)
        let filled = MediaGridLayout.filledContentSize(source: CGSize(width: 3024, height: 4032), in: cell)

        #expect(abs(filled.width - cell.width) < 0.001)
        #expect(filled.height > cell.height)
    }

    @Test func everySourceAspectCoversTheWholeCell() {
        let cell = CGSize(width: 114, height: 152)
        let sources = [
            CGSize(width: 4032, height: 3024),   // landscape photo
            CGSize(width: 3024, height: 4032),   // portrait photo
            CGSize(width: 1080, height: 1080),   // square
            CGSize(width: 1920, height: 1080),   // 16:9 video poster
            CGSize(width: 1080, height: 1920),   // 9:16 vertical video
        ]
        for source in sources {
            let filled = MediaGridLayout.filledContentSize(source: source, in: cell)
            // Never a letterbox: fill means both axes reach at least the cell.
            #expect(filled.width >= cell.width - 0.001, "\(source) left a horizontal gap")
            #expect(filled.height >= cell.height - 0.001, "\(source) left a vertical gap")
        }
    }

    @Test func aZeroSizedSourceFallsBackToTheCellRatherThanDividingByZero() {
        let cell = CGSize(width: 114, height: 152)
        #expect(MediaGridLayout.filledContentSize(source: .zero, in: cell) == cell)
        #expect(MediaGridLayout.filledContentSize(source: CGSize(width: 100, height: 100), in: .zero) == .zero)
    }

    // MARK: - Every kind of cell in a grid is the same size

    @Test func aPairedSliderCellMatchesAPlainCellByDefault() {
        // Before this was shared, the pro's portfolio passed the slider a
        // hard-coded `height: 120` while photo tiles derived their own size —
        // two different tile sizes in one row.
        let plain = MediaGridCell { EmptyView() }
        let paired = MediaGridCompareCell(
            beforeURL: URL(string: "https://example.test/b.jpg")!,
            afterURL: URL(string: "https://example.test/a.jpg")!
        )

        #expect(plain.aspectRatio == paired.aspectRatio)
        #expect(plain.aspectRatio == MediaGridLayout.portraitAspect)
    }

    @Test func theSquareGridsOptIntoOneSharedSquareConstant() {
        let square = MediaGridCell(aspectRatio: MediaGridLayout.squareAspect) { EmptyView() }
        let pairedSquare = MediaGridCompareCell(
            beforeURL: URL(string: "https://example.test/b.jpg")!,
            afterURL: URL(string: "https://example.test/a.jpg")!,
            aspectRatio: MediaGridLayout.squareAspect
        )

        #expect(square.aspectRatio == pairedSquare.aspectRatio)
        #expect(MediaGridLayout.squareAspect == 1.0)
    }

    @Test func portfolioTilesUseThePortraitCropOnBothProfileSurfaces() {
        // The pro's own tab (10pt gutters, rounded, plain) and the public
        // profile (2pt gutters, flush, chipped) differ in gutter and chrome.
        // What they must NOT differ in is the crop: a tile is the same shape on
        // both, so a pro comparing the two screens sees one portfolio.
        #expect(abs(MediaGridLayout.portraitAspect - 0.75) < 1e-12)

        let proTab = MediaGridLayout.columnWidth(container: 362, count: 3, spacing: 10)
        let publicProfile = MediaGridLayout.columnWidth(container: 362, count: 3, spacing: 2)
        #expect(proTab < publicProfile)   // wider gutters → narrower cell

        // Same ratio applied to each, so neither surface can end up with a tile
        // that is a different SHAPE from the other's.
        let proTabHeight = proTab / MediaGridLayout.portraitAspect
        let publicHeight = publicProfile / MediaGridLayout.portraitAspect
        #expect(abs((proTab / proTabHeight) - (publicProfile / publicHeight)) < 1e-12)
    }
}
