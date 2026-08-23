// The trigger-bound look script (tovis-app #974) — the two things worth
// pinning are the wire→script build rules (unknown/blank/duplicate handling)
// and the moment→trigger mapping that decides which coaching moments speak
// the look's own words. Pure type, no camera, no engine.
import Testing
import TovisKit
@testable import Tovis

@Suite struct LookDirectionScriptTests {
    private func script(_ wire: [(String, String)]) -> LookDirectionScript {
        LookDirectionScript(wire: wire.map { ProLookBriefDirection(trigger: $0.0, line: $0.1) })
    }

    // MARK: - Building from the wire

    @Test func buildsATriggerKeyedScript() {
        let s = script([("opening", "Soft smile"), ("ready", "Hold it — shooting now")])
        #expect(!s.isEmpty)
        #expect(s.line(for: .opening) == "Soft smile")
        #expect(s.line(for: .ready) == "Hold it — shooting now")
        #expect(s.line(for: .subjectTooFar) == nil)
    }

    /// Unknown server vocabulary drops at script build — decode already let it
    /// through as a plain string (the pose-rule forward-compat contract).
    @Test func dropsUnknownTriggers() {
        let s = script([("someFutureTrigger", "From a newer server")])
        #expect(s.isEmpty)
    }

    @Test func dropsBlankLinesAndKeepsTheFirstPerTrigger() {
        let s = script([
            ("poseUnmet", "   "),
            ("opening", "First opening"),
            ("opening", "Second opening is ignored"),
        ])
        #expect(s.line(for: .poseUnmet) == nil)
        #expect(s.line(for: .opening) == "First opening")
    }

    @Test func emptyWireIsEmpty() {
        #expect(LookDirectionScript.empty.isEmpty)
        #expect(script([]).isEmpty)
    }

    // MARK: - Which coaching moments the look replaces

    @Test func fillBandMomentsMapToFarAndClose() {
        let s = script([("subjectTooFar", "Bring them in"), ("subjectTooClose", "Give them room")])
        let far = CoachNudge(category: .composition, message: "Step closer", moment: .compositionTooFar)
        let close = CoachNudge(category: .composition, message: "Step back", moment: .compositionTooClose)
        #expect(s.line(replacing: far) == "Bring them in")
        #expect(s.line(replacing: close) == "Give them room")
    }

    @Test func faceRequiredMapsToFaceMissing() {
        let s = script([("faceMissing", "Turn them back to the lens")])
        let nudge = CoachNudge(category: .composition, message: "Face the camera",
                               moment: .compositionFaceRequired)
        #expect(s.line(replacing: nudge) == "Turn them back to the lens")
    }

    /// A brief pose-rule tip is a `.pose` nudge with NO moment — that is the
    /// `poseUnmet` state. `.poseClipped` (body cut off at the frame edge) is
    /// a different problem and keeps its generic line.
    @Test func momentlessPoseNudgeMapsToPoseUnmet() {
        let s = script([("poseUnmet", "Chin toward the shoulder, like the photo")])
        let ruleTip = CoachNudge(category: .pose, message: "Bring their hand up")
        let clipped = CoachNudge(category: .pose, message: "They're cut off", moment: .poseClipped)
        #expect(s.line(replacing: ruleTip) == "Chin toward the shoulder, like the photo")
        #expect(s.line(replacing: clipped) == nil)
    }

    /// States the model wrote no line for — and dimensions triggers never
    /// cover (lighting, level…) — keep the generic coaching.
    @Test func unmappedMomentsKeepTheGenericLine() {
        let s = script([("opening", "Soft smile")])
        let lighting = CoachNudge(category: .lighting, message: "Face the window",
                                  moment: .lightingTooDark)
        let tooFarWithNoLine = CoachNudge(category: .composition, message: "Step closer",
                                          moment: .compositionTooFar)
        #expect(s.line(replacing: lighting) == nil)
        #expect(s.line(replacing: tooFarWithNoLine) == nil)
    }

    @Test func anEmptyScriptNeverReplaces() {
        let nudge = CoachNudge(category: .composition, message: "Step closer",
                               moment: .compositionTooFar)
        #expect(LookDirectionScript.empty.line(replacing: nudge) == nil)
    }
}
