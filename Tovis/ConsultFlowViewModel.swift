import Foundation
import Observation
import TovisKit

@MainActor
@Observable
final class ConsultFlowViewModel {
    private(set) var machine: ConsultFlowMachine
    private(set) var agreementState: ConsultAgreementState?
    private(set) var intakeState: ConsultIntakeState?
    private(set) var captureState: ConsultCaptureState?
    private(set) var results: ConsultClientResults?
    private(set) var answers: [String: String] = [:]
    private(set) var busy = false
    private(set) var processingShot: ConsultCaptureShotKey?
    private(set) var failure: ConsultClientFailure?
    private(set) var teaserTapped = false

    let professionalId: String

    @ObservationIgnored private let service: any ConsultServicing
    @ObservationIgnored private let exposure: ConsultExposurePolicy
    @ObservationIgnored private var intakeIdempotencyKey = UUID().uuidString
    @ObservationIgnored private var analysisIdempotencyKey = UUID().uuidString
    @ObservationIgnored private var pendingPhoto: PendingPhoto?

    private struct PendingPhoto {
        let shot: ConsultCaptureShot
        let data: Data
        let keys: ConsultCaptureMutationKeys
    }

    init(bookingId: String, professionalId: String,
         service: any ConsultServicing,
         exposure: ConsultExposurePolicy = .production) {
        machine = ConsultFlowMachine(bookingId: bookingId)
        self.professionalId = professionalId
        self.service = service
        self.exposure = exposure
    }

    var stage: ConsultFlowStage { machine.stage }
    var canEnter: Bool { exposure.allows(professionalId: professionalId) }

    var canSubmitIntake: Bool {
        guard let pack = intakeState?.questionPack else { return false }
        return pack.questions.allSatisfy {
            $0.requirement == .skippable || answers[$0.key] != nil
        }
    }

    var canRetryPhoto: Bool { pendingPhoto != nil && !busy }

    func start() async {
        guard canEnter else {
            failure = .hidden
            return
        }
        await perform {
            let session = try await service.create(bookingId: machine.bookingId)
            guard session.professionalId == professionalId,
                  exposure.allows(professionalId: session.professionalId) else {
                throw ConsultClientFailure.hidden
            }
            try machine.apply(session: session)
            let agreements = try await service.agreements(consultId: session.id)
            agreementState = agreements
            try machine.apply(agreements: agreements)
            try await loadCurrentStage(consultId: session.id)
        }
    }

    func accept(_ requirement: ConsultAgreementRequirement) async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let state = try await service.acceptAgreement(
                consultId: consultId,
                kind: requirement.kind,
                agreementVersionId: requirement.requiredVersion.id
            )
            agreementState = state
            try machine.apply(agreements: state)
            if state.allCurrent { try await loadIntake(consultId: consultId) }
        }
    }

    func revokeSensitiveConsent() async {
        guard let consultId = machine.consultId,
              let acceptance = agreementState?.requirements.first(where: {
                  $0.kind == .sensitiveDataConsent
              })?.currentAcceptance else { return }
        await perform {
            let state = try await service.revokeAgreement(
                consultId: consultId,
                acceptanceId: acceptance.id
            )
            pendingPhoto = nil
            agreementState = state
            try machine.apply(agreements: state)
        }
    }

    func selectAnswer(questionKey: String, value: String) {
        guard intakeState?.questionPack.questions.contains(where: {
            $0.key == questionKey && $0.options.contains(where: { $0.value == value })
        }) == true else { return }
        if answers[questionKey] != value {
            answers[questionKey] = value
            intakeIdempotencyKey = UUID().uuidString
        }
        failure = nil
    }

    func submitIntake() async {
        guard canSubmitIntake, let consultId = machine.consultId,
              let intakeState else { return }
        await perform {
            let updated = try await service.submitIntake(
                consultId: consultId,
                state: intakeState,
                answers: answers,
                idempotencyKey: intakeIdempotencyKey
            )
            self.intakeState = updated
            try machine.apply(intake: updated)
            let capture = try await service.capture(consultId: consultId)
            captureState = capture
            try machine.apply(capture: capture)
        }
    }

    func submitPhoto(_ data: Data, for shot: ConsultCaptureShot) async {
        pendingPhoto = PendingPhoto(shot: shot, data: data, keys: ConsultCaptureMutationKeys())
        await sendPendingPhoto()
    }

    func retryPhoto() async { await sendPendingPhoto() }

    private func sendPendingPhoto() async {
        guard let pendingPhoto, let consultId = machine.consultId,
              let pack = captureState?.shotPack else { return }
        processingShot = pendingPhoto.shot.key
        await perform {
            let response = try await service.uploadAndCheckCapture(
                consultId: consultId,
                shot: pendingPhoto.shot,
                pack: pack,
                jpegData: pendingPhoto.data,
                keys: pendingPhoto.keys
            )
            self.pendingPhoto = nil
            captureState = response.capture
            try machine.apply(capture: response.capture)
        }
        processingShot = nil
    }

    func startAnalysis() async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let analysis = try await service.startAnalysis(
                consultId: consultId,
                idempotencyKey: analysisIdempotencyKey
            )
            try machine.apply(analysis: analysis)
            if analysis.status == .completed { try await loadResults(consultId: consultId) }
        }
    }

    func refreshAnalysis() async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let analysis = try await service.analysis(consultId: consultId)
            try machine.apply(analysis: analysis)
            if analysis.status == .completed { try await loadResults(consultId: consultId) }
        }
    }

    func tapLockedMeCard() async {
        guard let consultId = machine.consultId, !teaserTapped else { return }
        await perform {
            try await service.recordLockedTeaserTap(consultId: consultId)
            teaserTapped = true
        }
    }

    func clearFailure() { failure = nil }

    private func loadCurrentStage(consultId: String) async throws {
        switch machine.stage {
        case .prerequisites, .stopped:
            return
        case .intake:
            try await loadIntake(consultId: consultId)
        case .capture:
            let capture = try await service.capture(consultId: consultId)
            captureState = capture
            try machine.apply(capture: capture)
        case .analysis:
            let analysis = try await service.analysis(consultId: consultId)
            try machine.apply(analysis: analysis)
            if analysis.status == .completed { try await loadResults(consultId: consultId) }
        case .results:
            try await loadResults(consultId: consultId)
        }
    }

    private func loadIntake(consultId: String) async throws {
        let intake = try await service.intake(consultId: consultId)
        intakeState = intake
        var seeded = intake.latestRevision?.answers ?? [:]
        for suggestion in intake.prefillSuggestions where seeded[suggestion.questionKey] == nil {
            seeded[suggestion.questionKey] = suggestion.value
        }
        answers = seeded
        try machine.apply(intake: intake)
    }

    private func loadResults(consultId: String) async throws {
        let loaded = try await service.results(consultId: consultId)
        try machine.apply(results: loaded)
        results = loaded
        teaserTapped = loaded.meCardTeaser.tapped
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await operation()
        } catch {
            failure = ConsultClientFailure.stable(error)
        }
    }
}
