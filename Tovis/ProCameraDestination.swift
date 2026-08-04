// Where the camera's shots go.
//
// The AI-photographer camera — preview, coach, guide, auto-capture, calibration,
// best-shot harvest, the byte vault — is ONE camera. What changes between "I'm
// with a client" and "I'm practising" is not how it shoots; it's what it owes.
// This type is that difference, and nothing else:
//
//   .session  — anchored to a booking + phase. The phase owes one photo
//               (ProSessionPhotoRequirement), shots land as private session
//               media, and leaving without that photo is worth a sentence.
//   .practice — anchored to nothing. No booking, no client, nothing owed. Shots
//               land in the pro's practice library and can be attached to a
//               booking or published as a look later, when a service is known.
//
// Keeping it a value type (rather than two camera screens, or a Bool threaded
// through forty call sites) is the whole point: there is no second camera to
// keep in sync, and every coach/tuning fix reaches both by construction.
import Foundation
import TovisKit

enum ProCameraDestination: Equatable, Hashable {
    case session(bookingId: String, phase: MediaPhase)
    case practice

    // MARK: - Session identity

    /// The booking this shoot belongs to, or nil when practising.
    var bookingId: String? {
        switch self {
        case let .session(bookingId, _): return bookingId
        case .practice: return nil
        }
    }

    /// The phase being shot. Practice has no before/after — its shots are
    /// `.other`, which is also what the server records.
    var phase: MediaPhase {
        switch self {
        case let .session(_, phase): return phase
        case .practice: return .other
        }
    }

    var isPractice: Bool { self == .practice }

    // MARK: - Custody namespace

    /// The key the durable byte vault, the clip vault, and the per-shoot
    /// UserDefaults (white balance, card calibration) namespace themselves on.
    ///
    /// ⚠️ Practice gets its OWN namespace, not a booking's. A stranded practice
    /// photo swept up later must not be re-offered to a booking's upload queue,
    /// and a card calibration solved in the pro's kitchen must not silently
    /// re-colour a client's before/after.
    var custodyScope: String {
        switch self {
        case let .session(bookingId, _): return bookingId
        case .practice: return "practice"
        }
    }

    // MARK: - What is owed

    /// Whether this shoot owes a photo at all.
    ///
    /// A session phase owes exactly one (`ProSessionPhotoRequirement`). Practice
    /// owes nothing — that is the entire point of it — so the requirement card,
    /// the accented Done, and the exit sentence about a missing photo all stay
    /// out of the way.
    var owesAPhoto: Bool {
        switch self {
        case .session: return true
        case .practice: return false
        }
    }

    /// Whether the requirement is satisfied, given what this shoot has captured.
    /// Always true for practice.
    func requirementMet(captured: Int) -> Bool {
        guard owesAPhoto else { return true }
        return ProSessionPhotoRequirement.isMet(captured: captured)
    }

    /// The guide sheet's note about what's actually required. Practice says
    /// plainly that nothing is.
    func guideNote(requirementMet met: Bool) -> String {
        switch self {
        case let .session(_, phase):
            return met
                ? ProSessionPhotoRequirement.metDetail(phase)
                : ProSessionPhotoRequirement.guideNote(phase)
        case .practice:
            return "Practice shots aren’t attached to anyone. Shoot as many as you like — you can attach one to a client or a look later."
        }
    }

    /// The exit dialog's title when nothing is at risk but the shoot is short of
    /// what it owes. Never reached for practice (`owesAPhoto` is false).
    var leavingWithoutTitle: String {
        switch self {
        case let .session(_, phase):
            return ProSessionPhotoRequirement.leavingWithoutTitle(phase)
        case .practice:
            return "Leave the camera?"
        }
    }

    /// The one sentence naming the outstanding photo. Empty for practice.
    var outstandingSentence: String {
        switch self {
        case let .session(_, phase):
            return ProSessionPhotoRequirement.outstandingSentence(phase)
        case .practice:
            return ""
        }
    }
}
