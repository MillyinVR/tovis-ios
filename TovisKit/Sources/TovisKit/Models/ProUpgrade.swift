import Foundation

// "Offer services" — POST /api/v1/pro/upgrade: add a PRO workspace to an
// account that already exists as a client.
//
// The multi-workspace machinery has shipped for a while (one `User` may hold
// both profiles, `POST /workspace/switch` moves between them, and the switch row
// is already in both settings hubs). What was missing on the phone is the DOOR:
// the only place a ProfessionalProfile was ever created from native was pro
// SIGNUP, reachable by a brand-new account only. A client who decided to start
// taking bookings had to find a browser.
//
// The route asks for LESS than signup does, and that is the point: the person is
// already signed in and already verified, so their name and phone carry over
// server-side. What is left is only what the app cannot know about a client —
// what they do, where they do it, what licenses them, and what they trade under.

/// POST /api/v1/pro/upgrade — request body.
///
/// Mirrors the PRO branch of the register request, minus everything the account
/// already has. `nil` omits the key.
struct ProUpgradeRequest: Encodable, Sendable {
    let professionType: String
    let licenseState: String
    let signupLocation: SignupLocationPayload
    var businessName: String? = nil
    var handle: String? = nil
    var mobileRadiusMiles: Int? = nil
    var licenseNumber: String? = nil
    var licenseExpiry: String? = nil
}

/// POST /api/v1/pro/upgrade — response.
///
/// 🔴 `token` is a freshly minted ACTIVE session carrying the PRO acting role.
/// The upgrade flips the account's home role to PRO (it has to: switching INTO a
/// workspace you don't call home requires an APPROVED profile, so a pro whose
/// licence is still PENDING could not reach the studio at all otherwise), and
/// the old JWT still says CLIENT. Persist this or the app keeps acting as a
/// client until the old token expires.
public struct ProUpgradeResponse: Decodable, Sendable {
    public let professionalId: String
    public let token: String
    /// The new profile's verification status — PENDING for almost everyone. A
    /// pro is LISTED and BOOKABLE while it is pending; a verified licence is a
    /// badge, not a gate.
    public let verificationStatus: String?
    public let licenseVerified: Bool?
    /// True when the state's registry could not confirm the licence and a
    /// document has to be uploaded by hand — the Verification screen's job.
    public let needsManualLicenseUpload: Bool?
    public let manualLicensePendingReview: Bool?
}
