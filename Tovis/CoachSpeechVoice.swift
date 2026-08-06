// Which AVSpeechSynthesisVoice actually speaks the coach — separate from
// CoachVoice (which personality's WORDS get said). The stock default-quality
// voice iOS falls back to when nothing better is installed is the single
// biggest reason spoken coaching reads as "robotic": Apple ships genuinely
// natural Enhanced/Premium voices, but only the ones a person has downloaded
// (Settings → Accessibility → Spoken Content → Voices) are ever available to
// pick at runtime — there is no way to ship one in the app bundle.
import AVFoundation

enum CoachSpeechVoice {
    /// The best-quality voice actually installed for the device's current
    /// language, computed once (installed voices don't change mid-session).
    /// Premium (Siri-grade neural) beats Enhanced beats the always-present
    /// Default. `nil` only if `AVSpeechSynthesisVoice` can't resolve a voice
    /// for the language at all — `AVSpeechUtterance` degrades to its own
    /// built-in default in that case, never silently drops the utterance.
    static let best: AVSpeechSynthesisVoice? = bestVoice()

    /// Human-readable quality name for the resolved voice, for a settings
    /// footnote or debug HUD — the "get a better voice" nudge only makes
    /// sense to show once someone can see what they currently have.
    static var bestQualityDescription: String {
        switch best?.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Default (system)"
        default: return "Default (system)"
        }
    }

    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let installed = AVSpeechSynthesisVoice.speechVoices()

        // Exact language match ("en-US") first; if the pro's device locale
        // has no exact-match voice installed, widen to the base language
        // ("en") so a British "en-GB" Enhanced voice still beats falling all
        // the way back to the bundled default on an "en-US" device.
        let base = String(language.prefix(2))
        let exact = installed.filter { $0.language == language }
        let sameLanguage = exact.isEmpty ? installed.filter { $0.language.hasPrefix(base) } : exact

        let ranked = sameLanguage.sorted { rank($0.quality) > rank($1.quality) }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }

    private static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 2
        case .enhanced: return 1
        case .default: return 0
        @unknown default: return 0
        }
    }
}
