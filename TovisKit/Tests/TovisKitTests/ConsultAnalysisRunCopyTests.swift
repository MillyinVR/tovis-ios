import Foundation
import Testing

@testable import TovisKit

/// P4b: the waiting-screen copy, which is the only thing the client sees for
/// the minute or two the analysis takes.
struct ConsultAnalysisRunCopyTests {
    private func run(
        status: ConsultAnalysisRunStatus = .running,
        stage: ConsultAnalysisRunStage = .readingPhotos,
        photoCount: Int = 4,
        retryable: Bool = false,
        failureCode: String? = nil
    ) throws -> ConsultAnalysisRun {
        let json = """
        {
          "runId": "run_1",
          "status": "\(status.rawValue)",
          "stage": "\(stage.rawValue)",
          "photoCount": \(photoCount),
          "attemptCount": 1,
          "maxAttempts": 3,
          "queuedAt": "2026-09-04T10:00:00.000Z",
          "startedAt": "2026-09-04T10:00:01.000Z",
          "finishedAt": null,
          "failureCode": \(failureCode.map { "\"\($0)\"" } ?? "null"),
          "retryable": \(retryable)
        }
        """
        return try JSONDecoder().decode(
            ConsultAnalysisRun.self,
            from: Data(json.utf8)
        )
    }

    @Test("names the number of photos it is actually reading")
    func photoCount() throws {
        #expect(
            ConsultAnalysisRunCopy.progress(for: try run(photoCount: 4)).headline
                == "Reading your 4 photos…"
        )
        // A partial pack is a supported state, so the singular has to exist.
        #expect(
            ConsultAnalysisRunCopy.progress(for: try run(photoCount: 1)).headline
                == "Reading your photo…"
        )
        // Zero is not a number to show a client.
        #expect(
            ConsultAnalysisRunCopy.progress(for: try run(photoCount: 0)).headline
                == "Reading your photos…"
        )
    }

    @Test("walks the three stages the client was promised, in order")
    func stages() throws {
        #expect(
            ConsultAnalysisRunCopy.progress(for: try run(stage: .understandingReference))
                .headline == "Understanding your reference…"
        )
        #expect(
            ConsultAnalysisRunCopy.progress(for: try run(stage: .buildingPlan))
                .headline == "Building your plan…"
        )
    }

    @Test("never moves the bar backwards as the run advances")
    func monotonic() throws {
        // A bar that jumps back reads as broken. Asserted over the real
        // sequence rather than spot-checked, so a stage inserted in the middle
        // cannot break the ordering silently.
        let order: [ConsultAnalysisRunStage] = [
            .queued, .readingPhotos, .understandingReference,
            .buildingPlan, .finalizing, .done,
        ]
        let fractions = order.map { ConsultAnalysisRunCopy.fraction(for: $0) }
        #expect(fractions == fractions.sorted())
        #expect(fractions.first! > 0)
        #expect(fractions.last! == 1)
    }

    @Test("offers the way out on a failed run, and leaks nothing about why")
    func failure() throws {
        let failed = ConsultAnalysisRunCopy.progress(
            for: try run(
                status: .failed,
                stage: .buildingPlan,
                retryable: true,
                failureCode: "ANALYSIS_UNAVAILABLE"
            )
        )
        #expect(failed.headline == "We couldn’t finish your plan.")
        #expect(failed.detail?.contains("try again") == true)
        // 🔴 No failure code, no provider name, no error text reaches the
        // client. The code exists for THIS app to branch on, not to render.
        let shown = "\(failed.headline) \(failed.detail ?? "")"
        #expect(!shown.contains("ANALYSIS_UNAVAILABLE"))
        #expect(!shown.lowercased().contains("provider"))
    }

    @Test("counts only QUEUED and RUNNING as still worth polling")
    func liveness() throws {
        #expect(try run(status: .queued).status.isLive)
        #expect(try run(status: .running).status.isLive)
        #expect(!(try run(status: .completed).status.isLive))
        #expect(!(try run(status: .failed).status.isLive))
    }
}
