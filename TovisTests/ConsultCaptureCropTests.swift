import CoreGraphics
import Foundation
import Testing
import TovisKit
@testable import Tovis

/// A shot as the SERVER serves it — decoded, so these tests exercise the real
/// wire path for `framing` rather than a hand-built value.
private func shot(
    _ key: ConsultCaptureShotKey,
    framing: String? = nil
) -> ConsultCaptureShot {
    var json = "{\"key\": \"\(key.rawValue)\", \"title\": \"t\", "
        + "\"instruction\": \"i\", \"requirement\": \"REQUIRED\""
    if let framing { json += ", \"framing\": \"\(framing)\"" }
    json += "}"
    return try! JSONDecoder().decode(ConsultCaptureShot.self, from: Data(json.utf8))
}

@Suite struct ConsultCaptureCropTests {

    // MARK: - Which camera a shot opens on

    @Test func faceShotsOpenOnTheFrontCameraAndHairShotsOnTheRear() {
        for key in [ConsultCaptureShotKey.earlyPhoto, .eyesCloseup, .faceFront, .faceSide] {
            #expect(ConsultCaptureCrop.defaultCamera(for: key) == .front,
                    "\(key.rawValue) contains the client's face — she has to be able to compose it")
        }
        for key in [ConsultCaptureShotKey.hairBack, .hairLeft, .hairRight, .hairCrown] {
            #expect(ConsultCaptureCrop.defaultCamera(for: key) == .rear,
                    "\(key.rawValue) is of her own head — the front camera cannot see it")
        }
    }

    @Test func areaAndUnknownShotsOpenOnTheFrontCamera() {
        // Tori, 2026-09-06: the client is alone, so front is the default and the
        // hair pack is the only exception.
        #expect(ConsultCaptureCrop.defaultCamera(for: .areaWide) == .front)
        #expect(ConsultCaptureCrop.defaultCamera(for: .areaCloseup) == .front)
        #expect(ConsultCaptureCrop.defaultCamera(
            for: ConsultCaptureShotKey("nails_topdown_v9")) == .front)
    }

    // MARK: - The crop plan

    @Test func aFullViewShotIsNeverCropped() {
        for key in [ConsultCaptureShotKey.hairBack, .faceFront, .faceSide, .areaWide] {
            let plan = ConsultCaptureCrop.plan(
                for: shot(key, framing: "FULL_VIEW"),
                landmarkBand: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.1)
            )
            #expect(plan == .fullFrame,
                    "\(key.rawValue) is composed and uploaded as framed, landmarks or not")
        }
    }

    @Test func theEyesShotCropsToTheLandmarkBandWhenVisionFindsOne() {
        let raw = CGRect(x: 0.25, y: 0.40, width: 0.50, height: 0.08)
        let plan = ConsultCaptureCrop.plan(
            for: shot(.eyesCloseup, framing: "TIGHT_CROP"), landmarkBand: raw
        )
        guard case let .crop(rect, source) = plan else {
            Issue.record("expected a crop, got \(plan)"); return
        }
        #expect(source == .landmarks)
        // Padded outward on every side — the raw union stops AT the brow hairs
        // and the lower lid, and uploading that is the VIEW_MISMATCH this exists
        // to stop.
        #expect(rect.minX < raw.minX)
        #expect(rect.maxX > raw.maxX)
        #expect(rect.minY < raw.minY)
        #expect(rect.maxY > raw.maxY)
        // More room below the eyes than above the brows: lashes sit below the
        // lower lid and the gate is told to read them.
        #expect((raw.minY - rect.minY) < (rect.maxY - raw.maxY))
    }

    @Test func theEyesShotFallsBackToTheGuideBoxWithNoLandmarks() {
        let subject = shot(.eyesCloseup, framing: "TIGHT_CROP")
        let plan = ConsultCaptureCrop.plan(for: subject, landmarkBand: nil)
        #expect(plan == .crop(ConsultCaptureCrop.guideBox(for: subject)!, source: .guideBox))
    }

    @Test func theAreaCloseupAlwaysUsesTheGuideBoxEvenIfAFaceIsInFrame() {
        // There is no face in this shot by definition, so a landmark band here
        // came off something that is not the subject — a bystander, a poster.
        // Trusting it would crop the photo to a stranger's eyes.
        let subject = shot(.areaCloseup, framing: "TIGHT_CROP")
        let plan = ConsultCaptureCrop.plan(
            for: subject, landmarkBand: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        )
        #expect(plan == .crop(ConsultCaptureCrop.guideBox(for: subject)!, source: .guideBox))
    }

    @Test func aShotWithNoServedFramingIsTreatedAsFullView() {
        // A capture state written by a server that predates the field. The safe
        // direction to be wrong in is "upload as framed" — what every build did
        // before P3.
        #expect(shot(.eyesCloseup).framing == nil)
        #expect(shot(.eyesCloseup).framingOrDefault == .fullView)
        #expect(ConsultCaptureCrop.plan(for: shot(.eyesCloseup), landmarkBand: nil) == .fullFrame)
    }

    @Test func anUnknownFramingValueIsTreatedAsFullView() {
        let future = shot(.eyesCloseup, framing: "SOMETHING_NEW")
        #expect(future.framingOrDefault.rawValue == "SOMETHING_NEW")
        #expect(ConsultCaptureCrop.plan(for: future, landmarkBand: nil) == .fullFrame)
        #expect(ConsultCaptureCrop.guideBox(for: future) == nil)
    }

    // MARK: - The band stays inside the frame

    @Test func aBandNearAnEdgeSlidesInsteadOfBeingNarrowed() {
        // A client holding the phone low: the brows sit near the top of the
        // frame, so the padded band overhangs it. It must MOVE, not shrink — a
        // narrowed band clips the brow it was widened to include.
        let raw = CGRect(x: 0.30, y: 0.01, width: 0.40, height: 0.06)
        let band = ConsultCaptureCrop.band(fromEyeAndBrow: raw)
        // Compare against the band the same raw rect produces WELL INSIDE the
        // frame: same size, different place. Sliding preserves the size; a
        // narrowing clamp would not. (Compared with a tolerance — the two are
        // built by different arithmetic and need not be bit-identical.)
        let interior = ConsultCaptureCrop.band(
            fromEyeAndBrow: raw.offsetBy(dx: 0, dy: 0.4)
        )
        #expect(abs(band.width - interior.width) < 1e-9)
        #expect(abs(band.height - interior.height) < 1e-9)
        #expect(band.minY == 0)
    }

    @Test func everyBandAndGuideBoxStaysInsideTheFrame() {
        let corners = [
            CGRect(x: -0.4, y: -0.4, width: 0.5, height: 0.2),
            CGRect(x: 0.9, y: 0.95, width: 0.4, height: 0.3),
            CGRect(x: 0.0, y: 0.0, width: 2.0, height: 3.0),
        ]
        for raw in corners {
            let band = ConsultCaptureCrop.band(fromEyeAndBrow: raw)
            #expect(band.minX >= 0 && band.minY >= 0)
            #expect(band.maxX <= 1.0001 && band.maxY <= 1.0001)
            #expect(band.width > 0 && band.height > 0)
        }
        for key in [ConsultCaptureShotKey.eyesCloseup, .areaCloseup] {
            let box = ConsultCaptureCrop.guideBox(for: shot(key, framing: "TIGHT_CROP"))!
            #expect(box.minX >= 0 && box.minY >= 0)
            #expect(box.maxX <= 1 && box.maxY <= 1)
        }
    }

    @Test func theEyesGuideBoxIsAWideBandAndTheAreaBoxIsNot() {
        // On a 3:4 portrait frame. The eyes shot asks for both brows edge to
        // edge; a squarish box there would tell the client to compose something
        // the gate then refuses.
        let frame: CGFloat = 3.0 / 4.0
        let eyes = ConsultCaptureCrop.guideBox(for: shot(.eyesCloseup, framing: "TIGHT_CROP"))!
        let area = ConsultCaptureCrop.guideBox(for: shot(.areaCloseup, framing: "TIGHT_CROP"))!
        let eyesAspect = (eyes.width * frame) / (eyes.height * 1.0)
        let areaAspect = (area.width * frame) / (area.height * 1.0)
        #expect(eyesAspect > 2.0, "eyes band should be wide, got \(eyesAspect)")
        #expect(areaAspect < 1.5, "area box should be roughly square, got \(areaAspect)")
    }

    // MARK: - The camera memory

    @Test func theLastCameraChoiceIsRememberedPerShotNotGlobally() {
        let defaults = UserDefaults(suiteName: "p3-camera-memory-\(UUID().uuidString)")!
        // Unset → the policy default.
        #expect(ConsultCameraMemory.camera(for: .eyesCloseup, defaults: defaults) == .front)
        #expect(ConsultCameraMemory.camera(for: .hairBack, defaults: defaults) == .rear)

        ConsultCameraMemory.remember(.rear, for: .eyesCloseup, defaults: defaults)

        #expect(ConsultCameraMemory.camera(for: .eyesCloseup, defaults: defaults) == .rear)
        // The other shots are untouched — this is the whole point of per-shot.
        #expect(ConsultCameraMemory.camera(for: .faceFront, defaults: defaults) == .front)
        #expect(ConsultCameraMemory.camera(for: .hairBack, defaults: defaults) == .rear)
    }

    @Test func anUnparseableStoredChoiceFallsBackToThePolicyDefault() {
        let defaults = UserDefaults(suiteName: "p3-camera-junk-\(UUID().uuidString)")!
        defaults.set("sideways", forKey: ConsultCameraMemory.key(for: .faceFront))
        #expect(ConsultCameraMemory.camera(for: .faceFront, defaults: defaults) == .front)
    }
}

@Suite struct ConsultShotGuidanceCopyTests {
    @Test func onlyTheBackOfTheHeadGetsTheAskSomeoneLine() {
        let back = ConsultShotGuidance.helperLine(for: .hairBack)
        #expect(back?.detail == "Have someone take this one, or skip it for now.")
        // Every other shot is one she can take alone, so a "get help" line there
        // would be telling her a reachable shot is not reachable.
        for key in [ConsultCaptureShotKey.hairLeft, .hairRight, .hairCrown,
                    .faceFront, .faceSide, .eyesCloseup, .earlyPhoto, .areaWide] {
            #expect(ConsultShotGuidance.helperLine(for: key) == nil, "\(key.rawValue)")
        }
    }
}
