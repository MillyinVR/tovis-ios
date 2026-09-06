import Foundation

/// P4b: what the client reads while her plan is being built.
///
/// A pure function of the run, so the waiting screen has no state of its own
/// and the copy is testable without a view.
///
/// The stages are named for what the client can picture, not for what the code
/// is doing: "reading your photos" is a storage fetch plus a verification pass,
/// "understanding your reference" is the inspiration vision call, "building
/// your plan" is the two analysis calls. She does not need the architecture;
/// she needs to know it is moving and roughly how far along it is.
///
/// ⚠️ The web flow carries its own copy of these strings
/// (tovis-app `lib/consult/analysisRunCopy.ts`). They are duplicated across a
/// repo boundary because there is no shared module — a change here is a change
/// there.
public struct ConsultAnalysisRunProgress: Equatable, Sendable {
    /// The line under the spinner.
    public let headline: String
    /// A quieter second line, or nil when the headline says enough.
    public let detail: String?
    /// 0...1, for a determinate bar.
    public let fraction: Double
}

public enum ConsultAnalysisRunCopy {
    /// How often to poll a live run.
    public static let pollInterval: Duration = .seconds(5)

    /// Deliberately coarse and monotonic.
    ///
    /// A bar that creeps and then jumps backwards reads as broken, and the
    /// honest per-stage durations are wildly uneven (the direction call alone
    /// ranged 29s to over 90s in measurement, against ~5s for the reference
    /// read). So each stage claims a fixed slice, and the bar never goes
    /// backwards because a stage never does.
    static func fraction(for stage: ConsultAnalysisRunStage) -> Double {
        switch stage {
        case .queued: return 0.05
        case .readingPhotos: return 0.2
        case .understandingReference: return 0.4
        case .buildingPlan: return 0.75
        case .finalizing: return 0.95
        case .done: return 1
        }
    }

    /// P2e — what a FAILED run says, by what actually failed.
    ///
    /// Before this, every failure produced the same sentence. On 2026-09-06 a
    /// production run failed six times across two runs on a reference the
    /// server had already refused and would refuse every time, and the client
    /// was told only that the plan could not be finished — nothing about which
    /// picture was the problem or what would change the outcome.
    ///
    /// The codes are the server's own analysis vocabulary; `failureCode` is a
    /// code the client maps to its own copy, never a message to render.
    ///
    /// ⚠️ Mirrors `failureCopy` in tovis-app `lib/consult/analysisRunCopy.ts`.
    /// A change here is a change there.
    static let referenceFailureCodes: Set<String> = [
        "INSPIRATION_OBJECT_INVALID",
        "INSPIRATION_IMAGE_UNREADABLE",
        "INSPIRATION_ANALYSIS_UNREADABLE",
    ]

    static let photoFailureCodes: Set<String> = ["CAPTURE_OBJECT_INVALID"]

    static func failureCopy(_ failureCode: String?) -> (headline: String, detail: String) {
        if let failureCode, referenceFailureCodes.contains(failureCode) {
            return (
                "We couldn’t read your inspiration photo.",
                "Everything else you’ve added is saved. Swap in a different picture and we’ll pick this back up."
            )
        }
        if let failureCode, photoFailureCodes.contains(failureCode) {
            return (
                "We couldn’t read one of your photos.",
                "Everything else you’ve added is saved. Retake that one and we’ll pick this back up."
            )
        }
        return (
            "We couldn’t finish your plan.",
            "Your photos and answers are still saved — you can try again from here."
        )
    }

    static func photosPhrase(_ photoCount: Int) -> String {
        guard photoCount > 0 else { return "your photos" }
        return photoCount == 1 ? "your photo" : "your \(photoCount) photos"
    }

    public static func progress(for run: ConsultAnalysisRun) -> ConsultAnalysisRunProgress {
        switch run.status {
        case .completed:
            return ConsultAnalysisRunProgress(
                headline: "Your plan is ready.",
                detail: nil,
                fraction: 1
            )
        case .failed:
            let copy = failureCopy(run.failureCode)
            return ConsultAnalysisRunProgress(
                headline: copy.headline,
                detail: copy.detail,
                fraction: fraction(for: run.stage)
            )
        case .queued, .running:
            break
        }

        let value = fraction(for: run.stage)
        switch run.stage {
        case .queued:
            return ConsultAnalysisRunProgress(
                headline: "Getting started…",
                detail: "This usually takes a minute or two.",
                fraction: value
            )
        case .readingPhotos:
            return ConsultAnalysisRunProgress(
                headline: "Reading \(photosPhrase(run.photoCount))…",
                detail: "This usually takes a minute or two.",
                fraction: value
            )
        case .understandingReference:
            return ConsultAnalysisRunProgress(
                headline: "Understanding your reference…",
                detail: "Looking at the picture you brought.",
                fraction: value
            )
        case .buildingPlan:
            return ConsultAnalysisRunProgress(
                headline: "Building your plan…",
                detail: "This is the longest part. Hang tight.",
                fraction: value
            )
        case .finalizing:
            return ConsultAnalysisRunProgress(
                headline: "Almost there…",
                detail: nil,
                fraction: value
            )
        case .done:
            return ConsultAnalysisRunProgress(
                headline: "Your plan is ready.",
                detail: nil,
                fraction: 1
            )
        }
    }
}
