import CoreGraphics
import Foundation
import Testing
@testable import TovisKit

// The crop arithmetic that decides whether the client is in the picture the pro
// posts. Pure geometry, so it is fully checkable here — and it has to be, because
// the failure mode is a beautiful export of somebody's shoulder.

private let sourceThreeFour = CGSize(width: 900, height: 1200)   // the camera's 3:4
private let sourceLandscape = CGSize(width: 1600, height: 900)   // an imported 16:9
private let sourceSquare = CGSize(width: 1200, height: 1200)

/// Aspect of a normalized crop measured in the SOURCE's real pixels — what the
/// exported file will actually be shaped like.
private func croppedAspect(_ crop: CGRect, source: CGSize) -> CGFloat {
    (crop.width * source.width) / (crop.height * source.height)
}

@Suite struct SocialExportCropTests {
    // 🔴 The invariant that matters more than any single number: whatever the
    // source shape and wherever the subject is, the crop is INSIDE the source and
    // has EXACTLY the target aspect. Everything downstream (the placement, the
    // draw, the canvas size) assumes both, and neither is obvious by inspection.
    @Test func everyCropIsInsideTheSourceAndHasTheTargetAspect() {
        let sources = [sourceThreeFour, sourceLandscape, sourceSquare,
                       CGSize(width: 1080, height: 1920), CGSize(width: 4032, height: 3024)]
        let subjects: [CGRect?] = [
            nil,
            CGRect(x: 0.35, y: 0.10, width: 0.30, height: 0.30),   // high in frame
            CGRect(x: 0.05, y: 0.70, width: 0.25, height: 0.25),   // low and left
            CGRect(x: -0.2, y: 0.9, width: 0.5, height: 0.5),      // partly outside
        ]

        for format in SocialExportFormat.allCases {
            for source in sources {
                for subject in subjects {
                    for adjust in [CGFloat(-1), -0.3, 0, 0.4, 1] {
                        let crop = SocialExportPlanner.crop(
                            sourceAspect: source.width / source.height,
                            targetAspect: format.aspect,
                            subject: subject,
                            adjust: adjust
                        )
                        #expect(crop.minX >= -0.0001)
                        #expect(crop.minY >= -0.0001)
                        #expect(crop.maxX <= 1.0001)
                        #expect(crop.maxY <= 1.0001)
                        #expect(crop.width > 0 && crop.height > 0)
                        let error = abs(croppedAspect(crop, source: source) - format.aspect)
                        #expect(error < 0.0005, "\(format) \(source) aspect drifted by \(error)")
                    }
                }
            }
        }
    }

    @Test func matchingAspectsShipTheWholeFrame() {
        let crop = SocialExportPlanner.crop(
            sourceAspect: PublishCrop.feed, targetAspect: PublishCrop.feed
        )
        #expect(crop == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // A 3:4 capture into a 9:16 box loses width, not height — the same 40% the
    // published Looks feed has always taken, which is why the coach judges inside
    // `PublishCrop.feedRect`. The export must take exactly the same bite.
    @Test func nineSixteenFromACaptureMatchesTheCoachsCropGuide() {
        let crop = SocialExportPlanner.crop(
            sourceAspect: PublishCrop.captureAspect, targetAspect: PublishCrop.feed
        )
        #expect(abs(crop.height - 1) < 0.0001)
        #expect(abs(crop.width - PublishCrop.feedRect.width) < 0.0001)
        #expect(abs(crop.minX - PublishCrop.feedRect.minX) < 0.0001)
    }

    // With no subject there is nothing to be clever about: centre it.
    @Test func noSubjectCentresTheCrop() {
        let crop = SocialExportPlanner.crop(
            sourceAspect: 1.6, targetAspect: PublishCrop.feed
        )
        #expect(abs(crop.midX - 0.5) < 0.0001)
    }

    // 🔴 The headroom rule surviving the crop. A subject centred in the source
    // must come out ABOVE the middle of the export, not on it — that is the whole
    // point of `subjectAnchorY`, and a regression to 0.5 would look almost right
    // and quietly cost every portrait its composition.
    @Test func aCentredSubjectLandsAboveTheMiddleOfTheExport() {
        let subject = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)  // midY 0.5
        let crop = SocialExportPlanner.crop(
            // A tall source into a 4:5 box, so there is real vertical travel.
            sourceAspect: 0.5, targetAspect: PublishCrop.instagramFeed, subject: subject
        )
        let subjectInCrop = PublishCrop.inCropSpace(subject, crop: crop)
        #expect(subjectInCrop.midY < 0.5)
        #expect(abs(subjectInCrop.midY - SocialExportPlanner.subjectAnchorY) < 0.001)
    }

    @Test func aSubjectAtTheEdgeClampsInsteadOfCroppingOffTheSource() {
        let subject = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2)
        let crop = SocialExportPlanner.crop(
            sourceAspect: 0.5, targetAspect: PublishCrop.instagramFeed, subject: subject
        )
        #expect(crop.minY == 0)
        #expect(crop.maxY <= 1.0001)
    }

    // 🔴 Both extremes must stay reachable however off-centre the smart default
    // landed. The naive "smart ± adjust × slack/2" cannot reach an edge once the
    // subject has already pushed the crop toward it, and the pro would find the
    // slider simply refusing to go where they were dragging.
    @Test func theManualNudgeAlwaysReachesBothEdges() {
        let subject = CGRect(x: 0.4, y: 0.02, width: 0.2, height: 0.2)  // hard at the top
        let tall: CGFloat = 0.5
        let pinnedTop = SocialExportPlanner.crop(
            sourceAspect: tall, targetAspect: PublishCrop.instagramFeed,
            subject: subject, adjust: -1
        )
        let pinnedBottom = SocialExportPlanner.crop(
            sourceAspect: tall, targetAspect: PublishCrop.instagramFeed,
            subject: subject, adjust: 1
        )
        #expect(pinnedTop.minY == 0)
        #expect(abs(pinnedBottom.maxY - 1) < 0.0001)
    }

    @Test func zeroNudgeIsExactlyTheSmartDefault() {
        let subject = CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.3)
        let smart = SocialExportPlanner.crop(
            sourceAspect: 0.5, targetAspect: PublishCrop.instagramFeed, subject: subject
        )
        let nudged = SocialExportPlanner.crop(
            sourceAspect: 0.5, targetAspect: PublishCrop.instagramFeed,
            subject: subject, adjust: 0
        )
        #expect(smart == nudged)
    }

    @Test func outOfRangeNudgesClampRatherThanEscape() {
        for adjust in [CGFloat(-9), 9, .infinity, -.infinity] {
            let crop = SocialExportPlanner.crop(
                sourceAspect: 1.6, targetAspect: PublishCrop.feed, adjust: adjust
            )
            #expect(crop.minX >= -0.0001)
            #expect(crop.maxX <= 1.0001)
        }
    }

    // A degenerate decode must not produce a NaN rect that a later `.integral`
    // turns into a crash.
    @Test func degenerateSourcesDoNotProduceNonsense() {
        let source = SocialExportSource(pixelSize: .zero)
        #expect(source.aspect == 1)
        let crop = SocialExportPlanner.crop(
            sourceAspect: source.aspect, targetAspect: PublishCrop.feed
        )
        #expect(crop.width.isFinite && crop.height.isFinite)
        #expect(crop.width > 0 && crop.height > 0)
    }
}

@Suite struct SocialExportPlanTests {
    private let source = SocialExportSource(pixelSize: sourceThreeFour)

    @Test func aSingleShotFillsTheCanvas() {
        for format in SocialExportFormat.allCases {
            let plan = SocialExportPlanner.plan(format: format, subject: .single(source))
            #expect(plan.placements.count == 1)
            #expect(plan.placements[0].role == .single)
            #expect(plan.placements[0].destination == CGRect(origin: .zero, size: format.pixelSize))
            #expect(plan.canvasSize == format.pixelSize)
            #expect(plan.arrangement == nil)
        }
    }

    // 🔴 Order is the claim the picture makes. A diptych that reads after-then-
    // before is not a transformation, it is a warning — and nothing else in the
    // stack would catch the two being swapped.
    @Test func aPairIsAlwaysBeforeThenAfter() {
        for format in SocialExportFormat.allCases {
            let plan = SocialExportPlanner.plan(
                format: format,
                subject: .pair(before: source, after: source)
            )
            #expect(plan.placements.map(\.role) == [.before, .after])
        }
    }

    // Geometry, not taste: side by side inside a 9:16 box leaves each half at
    // ~0.28 w/h, which no face survives. So the tall canvas stacks.
    @Test func theTallCanvasStacksAndTheSquarerOneSitsSideBySide() {
        #expect(SocialExportFormat.feed916.pairArrangement == .stacked)
        #expect(SocialExportFormat.instagram45.pairArrangement == .sideBySide)

        for format in SocialExportFormat.allCases {
            let plan = SocialExportPlanner.plan(
                format: format, subject: .pair(before: source, after: source)
            )
            let halves = plan.placements.map(\.destination)
            // Equal halves, inside the canvas, separated by exactly the gutter.
            #expect(abs(halves[0].width - halves[1].width) < 0.001)
            #expect(abs(halves[0].height - halves[1].height) < 0.001)
            #expect(halves[0].minX >= 0 && halves[0].minY >= 0)
            #expect(halves[1].maxX <= plan.canvasSize.width + 0.001)
            #expect(halves[1].maxY <= plan.canvasSize.height + 0.001)

            let gap = format.pairArrangement == .stacked
                ? halves[1].minY - halves[0].maxY
                : halves[1].minX - halves[0].maxX
            #expect(abs(gap - SocialExportPlanner.diptychGutter) < 0.001)
        }
    }

    // Each half is cropped to ITS OWN shape — the reason the arrangement is
    // per-format in the first place. Cropping both halves to the canvas aspect
    // would squash them when drawn.
    @Test func eachHalfIsCroppedToTheHalfSShapeNotTheCanvasS() {
        for format in SocialExportFormat.allCases {
            let plan = SocialExportPlanner.plan(
                format: format, subject: .pair(before: source, after: source)
            )
            for placement in plan.placements {
                let slotAspect = placement.destination.width / placement.destination.height
                let cropAspect = croppedAspect(placement.sourceCrop, source: sourceThreeFour)
                #expect(abs(cropAspect - slotAspect) < 0.0005)
            }
        }
    }

    // The subject hint is the focal point the camera already found, not a fresh
    // detection pass. A shot with a face low in the frame must crop lower than
    // the same shot without one — otherwise the "smart" in smart crop is a lie.
    @Test func theStoredFocalPointActuallyMovesTheCrop() {
        let size = CGSize(width: 1200, height: 2400)  // tall, so there is travel
        let low = SocialExportSource(pixelSize: size, focal: MediaFocalPoint(x: 0.5, y: 0.8))
        let centred = SocialExportSource(pixelSize: size, focal: MediaFocalPoint(x: 0.5, y: 0.5))
        let none = SocialExportSource(pixelSize: size, focal: nil)

        func cropY(_ source: SocialExportSource) -> CGFloat {
            SocialExportPlanner.plan(format: .instagram45, subject: .single(source))
                .placements[0].sourceCrop.minY
        }
        #expect(cropY(low) > cropY(centred))
        #expect(none.subject == nil)
        #expect(abs(cropY(none) - cropY(centred)) > 0.0001)
    }

    @Test func anInvalidFocalIsNoHintRatherThanABadOne() {
        #expect(MediaFocalPoint(x: 1.4, y: 0.5) == nil)
        let source = SocialExportSource(
            pixelSize: CGSize(width: 900, height: 1200),
            focal: MediaFocalPoint(x: .nan, y: 0.5)
        )
        #expect(source.subject == nil)
    }

    @Test func aPairHonoursEachSideSOwnNudgeIndependently() {
        let plan = SocialExportPlanner.plan(
            format: .instagram45,
            subject: .pair(
                before: SocialExportSource(pixelSize: sourceThreeFour, adjust: -1),
                after: SocialExportSource(pixelSize: sourceThreeFour, adjust: 1)
            )
        )
        #expect(plan.placements[0].sourceCrop.minX == 0)
        #expect(abs(plan.placements[1].sourceCrop.maxX - 1) < 0.0001)
    }
}

@Suite struct SocialExportSignatureBoxTests {
    // 🔴 The failure that looks perfect in the preview. A 9:16 post is covered by
    // the platform's caption, audio row and action rail across roughly its bottom
    // 450 of 1920 — a signature in the true corner is a signature nobody ever
    // sees, which makes the entire feature pointless. So the 9:16 box must clear
    // that band by the published cover-safe numbers.
    @Test func theNineSixteenSignatureClearsThePlatformChrome() {
        let canvas = SocialExportFormat.feed916.pixelSize
        let box = SocialExportPlanner.signatureBox(in: canvas, format: .feed916)
        let chromeStartsAt = canvas.height * (1 - PublishCrop.coverSafeBottomFraction)
        #expect(box.maxY < chromeStartsAt)
        #expect(box.minY > canvas.height * PublishCrop.coverSafeTopFraction * 0.5)
    }

    // An Instagram feed post has no such overlay, so the signature goes where a
    // photographer would actually put it: the corner.
    @Test func theFourFiveSignatureSitsInThePlainCorner() {
        let canvas = SocialExportFormat.instagram45.pixelSize
        let box = SocialExportPlanner.signatureBox(in: canvas, format: .instagram45)
        let inset = min(canvas.width, canvas.height) * SocialExportPlanner.signatureInsetFraction
        #expect(abs(box.maxY - (canvas.height - inset)) < 0.001)
        #expect(abs(box.maxX - (canvas.width - inset)) < 0.001)
    }

    @Test func everySignatureBoxIsInsideItsCanvas() {
        for format in SocialExportFormat.allCases {
            let canvas = format.pixelSize
            let box = SocialExportPlanner.signatureBox(in: canvas, format: format)
            #expect(box.minX >= 0 && box.minY >= 0)
            #expect(box.maxX <= canvas.width && box.maxY <= canvas.height)
            #expect(box.width > 0 && box.height > 0)
        }
    }
}
