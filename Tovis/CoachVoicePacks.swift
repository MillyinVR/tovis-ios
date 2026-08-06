// The four launch personality packs — see docs/design/camera-personality-packs.md
// §3 for the sample copy this ports (Too dark / Tilt correction / Hold-still /
// Great-shot celebration / Backlit warning) and §2.6 for the rest of the
// `CoachMoment` case list each pack extrapolates to full coverage.
//
// Every `phrase(for:ctx:)` below only chooses WORDS. None of them can see a
// `FrameContext`, a score, or a `CoachTuning` threshold — that's what makes
// "tone only" true here rather than just promised.
import Foundation

/// Picks one line at random from a personality's variants for a moment — the
/// sample copy is deliberately 3–5 lines each so the voice doesn't feel like
/// a tape loop. `lines` is never empty at a call site below.
private func pick(_ lines: [String]) -> String { lines.randomElement()! }

// MARK: - Hype Bestie

/// High energy, celebratory. Chattiness `.expressive` — why rides along, and
/// celebration moments get the flourish.
struct HypeBestieVoice: CoachVoice {
    let id: CoachPersonality = .hypeBestie
    let displayName = "Hype Bestie"
    let chattiness: CoachChattiness = .expressive

    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String? {
        switch moment {
        case .lightingBacklit:
            return pick([
                "Bestie the light's behind them, spin them around!",
                "Backlit! Turn toward that window, chase the glow!",
                "Too much light behind — let's flip the script!",
            ])
        case .lightingTooDark:
            return pick([
                "Ooh it's giving shadow realm — walk them toward that light!",
                "Bestie it's too dark, let's find some glow!",
                "A lil dark! Chase the light with me!",
                "We need more light on that face, let's gooo!",
            ])
        case .lightingBlownOut:
            return pick([
                "Whoa, we're blown out — turn away from that light, bestie!",
                "Too much glow, we lost the details — spin away from it!",
                "Blown out! Let's dodge that light a little!",
            ])
        case .compositionTooFar:
            return pick(["Get in there — fill that frame, bestie!",
                        "Closer, closer — we want ALL of them in this shot!"])
        case .compositionTooClose:
            return pick(["Whoa, too tight — step back a touch!",
                        "We're cropping the good stuff, back up a hair!"])
        case .compositionFaceRequired:
            return pick(["Bestie, we need that face in the shot — frame it up!",
                        "Where's the face?! Get it in frame for this one!"])
        case .compositionOffFrame:
            return pick(["They stepped out of the money zone — center them up!",
                        "Outside the crop! Bring them back to the middle!"])
        case .compositionNoHeadroom:
            return pick(["Give them room to breathe — lower the camera a touch!",
                        "We're cramping their style — a little headroom, bestie!"])
        case .compositionTooLow:
            return pick(["They're sinking! Raise that camera up!",
                        "Too much empty sky — lift it up, bestie!"])
        case .compositionRecenter:
            return pick(["Center them up, we want that balance!",
                        "A little left, a little right — let's find the center!"])
        case .sharpnessHoldSteady:
            return pick(["Hold it steady, this shot's looking soft!",
                        "Freeze! We need this crisp, not blurry!"])
        case .sharpnessTapToFocus:
            return pick(["Just a touch soft — tap to focus, bestie!",
                        "Almost there, give it a tap!"])
        case .backgroundBusy:
            return pick(["Ooh busy background, let's find a cleaner spot!",
                        "Too much going on back there — clean backdrop, bestie!"])
        case .poseClipped:
            return pick(["We're clipping them! Pull back a bit!",
                        "Give them room — back up so nothing gets cut!"])
        case .levelTilted:
            return pick([
                "We're tilting! Straighten up, we almost had it!",
                "So close to level — just a nudge!",
                "Level it out and it's PERFECT.",
            ])
        case .levelAlmostLevel:
            return pick(["Almost level, bestie — just a hair more!",
                        "So close! Straighten up just a touch!"])
        case .colorMixed:
            return pick(["Mixed light alert — kill those overheads!",
                        "Two lights fighting each other — pick one, bestie!"])
        case .colorGreenish:
            return pick(["It's giving fluorescent green — switch that light up!",
                        "Greenish glow, let's find a cleaner source!"])
        case .colorWarm:
            return pick(["Too warm, too yellow — daylight is calling!",
                        "We're basically a candle right now — find some daylight!"])
        case .goodLighting: return "Light is SERVING."
        case .goodColor: return "Color is TRUE, we love it."
        case .goodLevel: return "Level and iconic."
        case .goodFraming: return "Framed to perfection, bestie."
        case .goodSharpness: return "Crisp crisp crisp!"
        case .goodBackground: return "Background is clean, no notes."
        case .goodPose: return "Pose is giving everything!"
        case .laneHoldShooting:
            return pick([
                "Hold it… hold it… YES, capturing!",
                "Don't move, don't move — this is the one!",
                "Steady steady steady — we're shooting!",
            ])
        case .laneSetComplete:
            return pick([
                "OKAY that's the full set, we ATE.",
                "Every. Single. Shot. A whole keeper. Let's gooo!",
                "That's a wrap and it's iconic.",
                "Full set, full glow — we're done, we're legendary.",
            ])
        case .laneCalibrationDrift:
            return pick(["Bestie the light moved — let's re-scan that card!",
                        "Light's different now, quick re-scan and we're back!"])
        case .dimensionCleared:
            let noun = ctx.subjectNoun ?? "That"
            return pick(["\(noun) — we got it, YES!",
                        "\(noun) is fixed, bestie, look at that!"])
        }
    }
}

// MARK: - Straight Shooter

/// Terse, corrections only. Chattiness `.minimal` — why is skipped by
/// default (the `CoachVoice` extension's rule), and there's no flourish.
struct StraightShooterVoice: CoachVoice {
    let id: CoachPersonality = .straightShooter
    let displayName = "Straight Shooter"
    let chattiness: CoachChattiness = .minimal

    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String? {
        switch moment {
        case .lightingBacklit:
            return pick(["Backlit. Turn to light.", "Light's behind. Reposition.", "Flip toward the source."])
        case .lightingTooDark:
            return pick(["Too dark. Move to light.", "Face needs light.", "More light, face side."])
        case .lightingBlownOut:
            return pick(["Blown out. Turn away.", "Too bright. Reposition."])
        case .compositionTooFar: return "Move closer."
        case .compositionTooClose: return "Too tight. Back up."
        case .compositionFaceRequired: return "Need the face."
        case .compositionOffFrame: return "Outside crop. Center."
        case .compositionNoHeadroom: return "No headroom. Lower camera."
        case .compositionTooLow: return "Too low. Raise camera."
        case .compositionRecenter: return "Off-center. Center it."
        case .sharpnessHoldSteady: return "Soft. Hold steady."
        case .sharpnessTapToFocus: return "Touch soft. Tap to focus."
        case .backgroundBusy: return "Busy background. Clean it up."
        case .poseClipped: return "Clipped. Pull back."
        case .levelTilted:
            return pick(["Tilted. Straighten.", "Level it.", "Off-level."])
        case .levelAlmostLevel: return "Almost level. Straighten."
        case .colorMixed: return "Mixed light. Kill overheads."
        case .colorGreenish: return "Green cast. Switch source."
        case .colorWarm: return "Too warm. Go daylight."
        case .goodLighting: return "Light good."
        case .goodColor: return "Color true."
        case .goodLevel: return "Level."
        case .goodFraming: return "Framed."
        case .goodSharpness: return "Sharp."
        case .goodBackground: return "Background clean."
        case .goodPose: return "Pose good."
        case .laneHoldShooting:
            return pick(["Hold.", "Steady.", "Don't move."])
        case .laneSetComplete:
            return pick(["Set complete.", "Done. Good set.", "All seven. Good."])
        case .laneCalibrationDrift: return "Light changed. Re-scan."
        case .dimensionCleared:
            let noun = ctx.subjectNoun ?? "Fixed"
            return "\(noun). Fixed."
        }
    }
}

// MARK: - Editorial Director

/// Fashion-shoot vibe, composed. Chattiness `.standard` — same footing as
/// Calm Mentor: why rides along, no extra flourish beyond the line itself.
struct EditorialDirectorVoice: CoachVoice {
    let id: CoachPersonality = .editorialDirector
    let displayName = "Editorial Director"
    let chattiness: CoachChattiness = .standard

    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String? {
        switch moment {
        case .lightingBacklit:
            return pick([
                "They're backlit — turn them into the light source.",
                "Too much light behind the subject. Reposition toward the window.",
                "Flip them — we need the light on the face, not behind it.",
            ])
        case .lightingTooDark:
            return pick([
                "We're losing the face in shadow — bring them into the light.",
                "Light needs to hit the face. Reposition toward the source.",
                "Too much shadow on the subject — move them into the light.",
            ])
        case .lightingBlownOut:
            return pick(["We're blowing out the highlights — turn away from the light.",
                        "Too much light on the face. Move off the source."])
        case .compositionTooFar: return "Bring them in — fill the frame."
        case .compositionTooClose: return "Too tight. Give the frame room to breathe."
        case .compositionFaceRequired: return "This shot needs the face in frame."
        case .compositionOffFrame: return "They're outside the published crop — center them."
        case .compositionNoHeadroom: return "Cramped at the top — lower the camera for headroom."
        case .compositionTooLow: return "Too much dead space above — raise the camera."
        case .compositionRecenter: return "Off the mark — center the subject."
        case .sharpnessHoldSteady: return "This is soft. Hold the frame steady."
        case .sharpnessTapToFocus: return "A touch soft — tap to lock focus."
        case .backgroundBusy: return "The background is competing with the subject — clean it up."
        case .poseClipped: return "We're clipping the frame — pull back."
        case .levelTilted:
            return pick([
                "The horizon's off — straighten the frame.",
                "Almost level. Tighten the line.",
                "Level the camera before we lock this shot.",
            ])
        case .levelAlmostLevel: return "Nearly level — just tighten the line."
        case .colorMixed: return "Mixed sources — kill the overheads."
        case .colorGreenish: return "Fluorescent cast reading through — switch the source."
        case .colorWarm: return "Too warm — daylight reads true here."
        case .goodLighting: return "Light's reading clean."
        case .goodColor: return "Color's true."
        case .goodLevel: return "Level."
        case .goodFraming: return "Framed on brand."
        case .goodSharpness: return "Tack sharp."
        case .goodBackground: return "Background's clean."
        case .goodPose: return "Pose is reading well."
        case .laneHoldShooting:
            return pick([
                "Hold the frame. We're taking it.",
                "Steady… locking focus… now.",
                "Hold — this is the shot.",
            ])
        case .laneSetComplete:
            return pick([
                "That's the set. Clean, consistent, done.",
                "Full set, every frame on brand. Beautiful.",
                "That's a wrap — this set is publication-ready.",
            ])
        case .laneCalibrationDrift: return "The light's shifted since calibration — re-scan the card."
        case .dimensionCleared:
            let noun = ctx.subjectNoun ?? "That"
            return "\(noun) — clean. Moving on."
        }
    }
}

// MARK: - Drag Queen Bestie

/// Campy, fabulous, confident and affectionate — never mean. Chattiness
/// `.expressive`.
struct DragQueenBestieVoice: CoachVoice {
    let id: CoachPersonality = .dragQueenBestie
    let displayName = "Drag Queen Bestie"
    let chattiness: CoachChattiness = .expressive

    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String? {
        switch moment {
        case .lightingBacklit:
            return pick([
                "The light's sneaking up behind you, baby — turn and face your glow!",
                "You're backlit, gorgeous — spin toward that light source!",
                "That light's behind you like a bad ex — turn around and claim it!",
            ])
        case .lightingTooDark:
            return pick([
                "Mama, the shadows are eating your face — strut toward that light!",
                "It's giving dark room energy, and not the fun kind — find your light, honey!",
                "The light is not hitting right — turn toward the glow, gorgeous.",
                "We need illumination on that face card, baby — chase the light!",
            ])
        case .lightingBlownOut:
            return pick([
                "Honey, you're washed out — step back from that light, it's too much!",
                "We're overexposed, baby — ease off that glow before it eats your face!",
            ])
        case .compositionTooFar: return "Come closer, baby — give us that frame-filling glamour!"
        case .compositionTooClose: return "Ooh too close, honey — step back and give us room to see you!"
        case .compositionFaceRequired: return "Where's that face, gorgeous? Get it in the shot!"
        case .compositionOffFrame: return "You wandered off the runway, baby — center yourself back up!"
        case .compositionNoHeadroom: return "We're cramped at the top, honey — lower that camera for some breathing room!"
        case .compositionTooLow: return "You're sinking, baby — raise that camera and let her rise!"
        case .compositionRecenter: return "A little off-center, gorgeous — let's find your mark!"
        case .sharpnessHoldSteady: return "Hold it, baby, this shot's blurry as a Tuesday night!"
        case .sharpnessTapToFocus: return "Just a touch soft, honey — tap and lock it in!"
        case .backgroundBusy: return "That background is UPSTAGING you, baby — find a cleaner backdrop!"
        case .poseClipped: return "We're cutting off the good parts — pull back, honey!"
        case .levelTilted:
            return pick([
                "The camera's tipping like it had one too many — level it, honey!",
                "Ooh, we're leaning! Straighten up like you're walking the runway.",
                "Almost level, baby — just a hair more and it's flawless.",
            ])
        case .levelAlmostLevel: return "So close to level, baby — just a hair more!"
        case .colorMixed: return "Two lights fighting for attention, baby — kill the overheads!"
        case .colorGreenish: return "We're reading a little swampy, honey — switch that light source!"
        case .colorWarm: return "Too much butter light, baby — daylight reads truer!"
        case .goodLighting: return "That light is SERVING, baby."
        case .goodColor: return "Color is reading true, gorgeous."
        case .goodLevel: return "Level, honey. Flawless."
        case .goodFraming: return "Framed like she owns the runway."
        case .goodSharpness: return "Sharp as your wit, baby."
        case .goodBackground: return "Background's clean, no shade thrown."
        case .goodPose: return "That pose is SERVING, honey."
        case .laneHoldShooting:
            return pick([
                "Hold that pose, don't you dare move — we're capturing greatness.",
                "Freeze, baby! This is the moment, hold it!",
                "Steady, steady… and captured. You better work.",
            ])
        case .laneSetComplete:
            return pick([
                "That is the full set and every single shot served. You better work!",
                "Category is: photographed to perfection. We are done, baby!",
                "That's a wrap, and honey, it was flawless from frame one.",
                "Full set, full fabulous — you ate that, no crumbs left!",
            ])
        case .laneCalibrationDrift: return "The light shifted on us, baby — re-scan that card real quick!"
        case .dimensionCleared:
            let noun = ctx.subjectNoun ?? "That"
            return "\(noun), honey — fixed and fabulous!"
        }
    }
}
