import Foundation
import Testing
@testable import TovisKit

// Pure session-flow + closeout logic (no network). Mirrors the web
// `lib/proSession/sessionFlow.ts` + `closeoutChecklist.ts` so the native hub
// routes screens + builds the rail identically.
struct ProSessionFlowTests {
    // MARK: - SessionStep parsing

    @Test func parsesServerStepCaseInsensitively() {
        #expect(SessionStep(serverValue: "before_photos") == .beforePhotos)
        #expect(SessionStep(serverValue: "SERVICE_IN_PROGRESS") == .serviceInProgress)
        #expect(SessionStep(serverValue: nil) == .none)
        #expect(SessionStep(serverValue: "") == .none)
        #expect(SessionStep(serverValue: "WHO_KNOWS") == .unknown)
    }

    // MARK: - screenKey

    @Test func mapsEffectiveStepToScreen() {
        #expect(ProSessionFlow.screenKey(effectiveStep: .none) == .consultation)
        #expect(ProSessionFlow.screenKey(effectiveStep: .consultation) == .consultation)
        #expect(ProSessionFlow.screenKey(effectiveStep: .consultationPendingClient) == .waitingOnClient)
        #expect(ProSessionFlow.screenKey(effectiveStep: .beforePhotos) == .beforePhotos)
        #expect(ProSessionFlow.screenKey(effectiveStep: .serviceInProgress) == .serviceInProgress)
        #expect(ProSessionFlow.screenKey(effectiveStep: .finishReview) == .wrapUp)
        #expect(ProSessionFlow.screenKey(effectiveStep: .afterPhotos) == .wrapUp)
        #expect(ProSessionFlow.screenKey(effectiveStep: .done) == .done)
        #expect(ProSessionFlow.screenKey(effectiveStep: .unknown) == .consultation)
    }

    // MARK: - step rail

    @Test func railHasFourMondayOrderedSteps() {
        let items = ProSessionFlow.stepItems(effectiveStep: .consultation)
        #expect(items.map(\.key) == [.consultation, .beforePhotos, .service, .wrapUp])
        #expect(items.map(\.label) == ["Consult", "Before", "Service", "Wrap-up"])
        #expect(items.map(\.number) == [1, 2, 3, 4])
    }

    @Test func railStatesTrackProgress() {
        // At before-photos (progress 2): consult done, before active, rest idle.
        let before = ProSessionFlow.stepItems(effectiveStep: .beforePhotos)
        #expect(before.map(\.state) == [.done, .active, .idle, .idle])

        // In service (progress 3).
        let service = ProSessionFlow.stepItems(effectiveStep: .serviceInProgress)
        #expect(service.map(\.state) == [.done, .done, .active, .idle])

        // Wrap-up (progress 4).
        let wrap = ProSessionFlow.stepItems(effectiveStep: .afterPhotos)
        #expect(wrap.map(\.state) == [.done, .done, .done, .active])

        // Done → every step reads done.
        let done = ProSessionFlow.stepItems(effectiveStep: .done)
        #expect(done.allSatisfy { $0.state == .done })
    }

    // MARK: - closeout checklist

    @Test func closeoutBlockedUntilEverythingDone() {
        let checklist = ProSessionCloseout.checklist(
            ProSessionCloseoutInput(
                afterCount: 0,
                hasAfterPhoto: false,
                hasAftercareDraft: false,
                hasFinalizedAftercare: false,
                hasPaymentCollected: false,
                hasCheckoutClosed: false,
                hasConsultationApproved: false,
            )
        )

        #expect(checklist.canComplete == false)
        #expect(checklist.helpText == ProSessionCloseout.blockedHelpText)
        #expect(checklist.items.map(\.key) == [.afterPhotos, .aftercare, .payment, .checkout, .consultation])
        #expect(checklist.items.allSatisfy { !$0.done })
    }

    @Test func closeoutReadyWhenAllRequirementsMet() {
        let checklist = ProSessionCloseout.checklist(
            ProSessionCloseoutInput(
                afterCount: 3,
                hasAfterPhoto: true,
                hasAftercareDraft: true,
                hasFinalizedAftercare: true,
                hasPaymentCollected: true,
                hasCheckoutClosed: true,
                hasConsultationApproved: true,
            )
        )

        #expect(checklist.canComplete == true)
        #expect(checklist.helpText == ProSessionCloseout.readyHelpText)
        #expect(checklist.items.first?.subtitle == "3 photos captured")
        #expect(checklist.items.allSatisfy { $0.done })
    }
}
