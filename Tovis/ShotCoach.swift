// The on-device "AI photographer" coach model. Each `ShotCoach` judges ONE aspect
// of the live frame (lighting, composition, …) and returns a 0–1 score + a plain-
// language fix. The engine aggregates them into a readiness value + the single
// most important tip. Pure + Sendable so they run on the camera's frame queue.
//
// Phase B1 ships Lighting + Composition; sharpness/background/pose are next. The
// `FrameContext` carries pre-computed signals so coaches don't each re-scan.
import CoreGraphics

enum CoachCategory: String, Sendable {
    case lighting, composition, sharpness, background, pose
}

/// One coach's read on the current frame. `score` is 0 (bad) … 1 (great);
/// `message` is the corrective tip, present only when there's something to fix.
struct CoachSignal: Sendable {
    let score: Double
    let message: String?
}

/// A prioritized tip surfaced to the pro (chip / voice).
struct CoachNudge: Sendable, Equatable {
    let category: CoachCategory
    let message: String
}

/// The aggregated result for one analyzed frame.
struct CoachResult: Sendable {
    let readiness: Double         // 0…1 overall
    let nudge: CoachNudge?        // the single most important fix, if any
}

/// Pre-computed, orientation-corrected signals for the current frame. Coordinates
/// are normalized with origin TOP-LEFT (UIKit-style) so composition math is simple.
struct FrameContext: Sendable {
    /// Average luma of the whole frame, 0…1.
    let avgLuma: Double
    /// Largest detected face, normalized (top-left origin). Nil if none.
    let faceBounds: CGRect?
    /// Average luma inside the face region, if a face was found.
    let faceLuma: Double?
}

protocol ShotCoach: Sendable {
    var category: CoachCategory { get }
    func evaluate(_ ctx: FrameContext) -> CoachSignal
}

// MARK: - Lighting

/// Judges exposure + backlighting. The strongest, most reliable on-device signal.
struct LightingCoach: ShotCoach {
    let category: CoachCategory = .lighting

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        let luma = ctx.avgLuma

        // Backlit: subject noticeably darker than the overall scene.
        if let faceLuma = ctx.faceLuma, faceLuma < luma * 0.6, faceLuma < 0.4 {
            return CoachSignal(score: 0.35, message: "Subject’s backlit — turn them toward the light")
        }
        if luma < 0.22 {
            return CoachSignal(score: 0.3, message: "Too dark — find more light")
        }
        if luma > 0.82 {
            return CoachSignal(score: 0.4, message: "Too bright — ease off the light")
        }
        // Ideal band 0.35–0.7; score falls off smoothly outside it.
        let ideal = 0.5
        let dist = abs(luma - ideal)
        let score = max(0.6, 1.0 - dist * 1.6)
        return CoachSignal(score: score, message: nil)
    }
}

// MARK: - Composition

/// Judges subject placement when a face is present (centering + headroom). Stays
/// neutral when there's no face so non-portrait services aren't nagged (pose +
/// saliency coaches cover those later).
struct CompositionCoach: ShotCoach {
    let category: CoachCategory = .composition

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let face = ctx.faceBounds else {
            return CoachSignal(score: 1.0, message: nil)
        }

        let centerX = face.midX
        let topY = face.minY
        let midY = face.midY

        // Headroom: face too high (cramped top) or sitting too low.
        if topY < 0.04 {
            return CoachSignal(score: 0.45, message: "Leave a little headroom — lower the camera")
        }
        if midY > 0.72 {
            return CoachSignal(score: 0.5, message: "Raise the camera — subject’s too low")
        }
        // Horizontal placement: comfortable near center or a third.
        let nearCenter = abs(centerX - 0.5) < 0.16
        let nearThird = abs(centerX - 0.33) < 0.1 || abs(centerX - 0.67) < 0.1
        if !nearCenter && !nearThird {
            return CoachSignal(score: 0.55, message: "Center your subject")
        }

        // Reward good framing; small deviation → small penalty.
        let dx = min(abs(centerX - 0.5), abs(centerX - 0.33), abs(centerX - 0.67))
        let score = max(0.7, 1.0 - dx)
        return CoachSignal(score: score, message: nil)
    }
}
