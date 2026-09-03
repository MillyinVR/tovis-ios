import Foundation
import TovisKit

/// The capture step's framing, derived from the SERVED shot pack rather than
/// written for the hair pack. "Seven daylight views / Four hair views and three
/// face views … all seven" was true for one of the three packs the server can
/// serve; a nails consult (area pack, three shots) read it and waited for four
/// more slots that would never appear. The native twin of the web's
/// lib/consult/captureCopy.ts — same slots, same words.
enum ConsultCaptureCopy {
    private static let countWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    ]

    static func countWord(_ count: Int) -> String {
        countWords.indices.contains(count) ? countWords[count] : String(count)
    }

    static func title(_ pack: ConsultCaptureShotPack) -> String {
        if pack.areaViewCount > 0 { return "Take guided photos of the area and your face" }
        if pack.hairViewCount > 0 { return "Take guided photos of your hair and face" }
        return "Take guided photos of your face"
    }

    /// "Four hair views and three face views. Each photo is checked …"
    static func intro(_ pack: ConsultCaptureShotPack) -> String {
        let views: String
        if pack.areaViewCount > 0 {
            views = "The area you’d like treated, and your face"
        } else if pack.hairViewCount > 0 {
            views = "\(countWord(pack.hairViewCount).capitalized) hair views and \(countWord(pack.faceViewCount)) face views"
        } else {
            views = "\(countWord(pack.faceViewCount).capitalized) face views"
        }
        return "\(views). Each photo is checked right away, and if one can’t be used you’ll see why. You can run the analysis without all \(countWord(pack.shots.count)) — anything the missing photos would have shown just comes back as unknown."
    }
}
