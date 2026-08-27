import Foundation
import Testing
import TovisKit
@testable import Tovis

nonisolated private struct StubConsultQC: ConsultPhotoQCEvaluating {
    let report: PhotoQCReport

    func evaluate(_ jpeg: Data, checkBlink: Bool) async -> PhotoQCReport { report }
}

private actor CountingPreparation: ConsultJPEGPreparing {
    private(set) var calls = 0
    let output: Data?

    init(output: Data?) { self.output = output }

    func prepare(_ source: Data) async -> Data? {
        calls += 1
        return output
    }
}

nonisolated private struct SlowConsultQC: ConsultPhotoQCEvaluating {
    let report: PhotoQCReport

    func evaluate(_ jpeg: Data, checkBlink: Bool) async -> PhotoQCReport {
        try? await Task.sleep(for: .milliseconds(100))
        return report
    }
}

@Suite struct ConsultGuidedCaptureTests {
    private var passingReport: PhotoQCReport {
        PhotoQCReport(
            retakeReason: nil,
            sharpness: 0.8,
            luma: 0.5,
            faceLuma: 0.5,
            eyesClosed: false,
            focalPoint: nil
        )
    }

    private func frame(
        luma: Double = 0.5,
        face: CGRect? = CGRect(x: 0.35, y: 0.15, width: 0.3, height: 0.35),
        faceLuma: Double? = 0.5,
        fill: Double? = 0.55,
        sharpness: Double = 0.8,
        color: ColorSignal? = ColorSignal(mixed: 0.01, greenTint: 0, warmth: 0),
        shot: ConsultCaptureShotKey
    ) -> FrameContext {
        FrameContext(
            avgLuma: luma,
            faceBounds: face,
            faceLuma: faceLuma,
            backgroundLuma: 0.5,
            sharpness: sharpness,
            backgroundClutter: 0.1,
            subjectFill: fill,
            pose: nil,
            deviceTilt: 0,
            color: color,
            expectations: ConsultShotGuidance.expectations(for: shot)
        )
    }

    @Test func sevenSlotsHaveSpecificVisionAndFramingExpectations() {
        let back = ConsultShotGuidance.expectations(for: .hairBack)
        let left = ConsultShotGuidance.expectations(for: .hairLeft)
        let right = ConsultShotGuidance.expectations(for: .hairRight)
        let crown = ConsultShotGuidance.expectations(for: .hairCrown)
        let faceFront = ConsultShotGuidance.expectations(for: .faceFront)
        let faceSide = ConsultShotGuidance.expectations(for: .faceSide)
        let eyes = ConsultShotGuidance.expectations(for: .eyesCloseup)

        #expect(back.face == .absent)
        #expect(back.fillBand == 0.22...0.9)
        #expect(left.face == .required)
        #expect(right.face == .required)
        #expect(left.fillBand == right.fillBand)
        #expect(crown.face == .absent)
        #expect(crown.isDetail)
        #expect(crown.fillBand == 0.3...0.95)
        // The hair views tolerate closed eyes; the face views need them open —
        // eye shape and lash observations read from open eyes.
        #expect(faceFront.face == .required)
        #expect(faceFront.fillBand == 0.22...0.85)
        #expect(faceSide.face == .required)
        #expect(eyes.face == .either)
        #expect(eyes.isDetail)
        #expect([faceFront, faceSide, eyes].allSatisfy { !$0.allowsClosedEyes })
        let all = [back, left, right, crown, faceFront, faceSide, eyes]
        #expect(all.allSatisfy { $0.poseRules.isEmpty })
        #expect([back, left, right, crown].allSatisfy { $0.allowsClosedEyes })
    }

    @Test func sideVisionResultRequiresAFaceWhileBackDoesNot() {
        let noFaceSide = CompositionCoach().evaluate(frame(
            face: nil, faceLuma: nil, shot: .hairLeft
        ))
        let noFaceBack = CompositionCoach().evaluate(frame(
            face: nil, faceLuma: nil, shot: .hairBack
        ))

        #expect(noFaceSide.moment == .compositionFaceRequired)
        #expect(noFaceSide.message == "Frame their face for this shot")
        #expect(noFaceBack.message == nil)
    }

    @Test func exposureAndColorSignalsStayInTheExistingCoachPipeline() {
        let dark = LightingCoach().evaluate(frame(
            luma: 0.55, faceLuma: 0.1, shot: .hairLeft
        ))
        let warm = ColorCoach().evaluate(frame(
            color: ColorSignal(mixed: 0, greenTint: 0, warmth: 0.5),
            shot: .hairCrown
        ))

        #expect(dark.moment == .lightingBacklit || dark.moment == .lightingTooDark)
        #expect(dark.score < 0.5)
        #expect(warm.moment == .colorWarm)
        #expect(warm.message?.contains("daylight") == true)
    }

    @Test func permissionDenialAndInterruptionKeepThePickerFallbackReachable() {
        #expect(ConsultGuidedCameraAvailability(cameraStatus: .denied) == .fallback)
        #expect(ConsultGuidedCameraAvailability(cameraStatus: .failed("ignored")) == .fallback)
        #expect(ConsultGuidedCameraAvailability(cameraStatus: .interrupted) == .interrupted)

        var machine = ConsultGuidedCaptureMachine()
        machine.cameraChanged(.fallback)
        #expect(machine.phase == .fallback)

        machine.cameraChanged(.ready)
        #expect(machine.phase == .ready)
        machine.cameraChanged(.interrupted)
        #expect(machine.phase == .interrupted)
        machine.cameraChanged(.ready)
        #expect(machine.phase == .ready)
    }

    @Test func cancellationCannotBeUndoneByALateCameraCallback() {
        var machine = ConsultGuidedCaptureMachine()
        machine.cameraChanged(.ready)
        machine.beginCapture()
        machine.cancel()
        machine.cameraChanged(.ready)
        machine.delivered()
        #expect(machine.phase == .cancelled)
    }

    @Test func postCaptureQCRejectsBeforeJPEGPreparation() async {
        let preparation = CountingPreparation(output: Data("prepared".utf8))
        let report = PhotoQCReport(
            retakeReason: "It came out soft",
            sharpness: 0.05,
            luma: 0.5,
            faceLuma: nil,
            eyesClosed: false,
            focalPoint: nil
        )
        let pipeline = ConsultTransientPhotoPipeline(
            quality: StubConsultQC(report: report),
            preparation: preparation
        )

        let outcome = await pipeline.process(
            Data("synthetic-frame".utf8),
            expectations: ConsultShotGuidance.expectations(for: .hairBack)
        )

        #expect(outcome == .retake("It came out soft"))
        #expect(await preparation.calls == 0)
        #expect(await pipeline.retainedByteCount() == 0)
    }

    @Test func passingCandidateReturnsOnlyPreparedJPEGAndRetainsNothing() async {
        let prepared = Data("prepared-jpeg".utf8)
        let pipeline = ConsultTransientPhotoPipeline(
            quality: StubConsultQC(report: passingReport),
            preparation: CountingPreparation(output: prepared)
        )

        let outcome = await pipeline.process(
            Data("synthetic-frame".utf8),
            expectations: ConsultShotGuidance.expectations(for: .hairRight)
        )

        #expect(outcome == .accepted(prepared))
        #expect(await pipeline.retainedByteCount() == 0)
    }

    @Test func cancellationClearsAnInFlightCandidate() async {
        let pipeline = ConsultTransientPhotoPipeline(
            quality: SlowConsultQC(report: passingReport),
            preparation: CountingPreparation(output: Data("prepared".utf8))
        )
        let task = Task {
            await pipeline.process(
                Data(repeating: 7, count: 512),
                expectations: ConsultShotGuidance.expectations(for: .hairCrown)
            )
        }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(await pipeline.retainedByteCount() == 0)
    }

    @Test func visualOnlyRuntimeCannotHarvestSpeakOrTouchProHaptics() {
        let options = CoachRuntimeOptions.visualOnly
        #expect(!options.speak)
        #expect(!options.haptics)
        #expect(!options.autoHarvest)
        #expect(options.personality == .calmMentor)
    }
}

@Suite(.serialized) @MainActor struct ProCoachRuntimeRegressionTests {
    @Test func persistedProSettingsStillFeedEveryEngineRuntimeOption() {
        let settings = CoachSettings()
        let options = settings.runtimeOptions
        #expect(options.speak == settings.speak)
        #expect(options.haptics == settings.haptics)
        #expect(options.autoHarvest == settings.autoHarvest)
        #expect(options.personality == settings.personality)
    }
}
