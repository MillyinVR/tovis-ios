// Smoke coverage for CoachSpeechVoice — mostly useful as a way to SEE what
// quality tier is actually resolved wherever this runs (simulator vs a real
// device with Enhanced/Premium voices downloaded), since that's the one part
// of the naturalness pass that isn't verifiable from source alone.
import Testing
@testable import Tovis

@Suite struct CoachSpeechVoiceTests {
    @Test func resolvesToARealInstalledVoice() {
        #expect(CoachSpeechVoice.best != nil, "no voice at all resolved for this runtime's language")
    }

    @Test func reportsAQualityDescription() {
        let quality = CoachSpeechVoice.bestQualityDescription
        #expect(!quality.isEmpty)
        print("CoachSpeechVoice resolved: \(CoachSpeechVoice.best?.name ?? "nil") — quality: \(quality)")
    }
}
