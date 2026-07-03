import Foundation

// Wire model for the client's shareable referral link — their own
// CLIENT_REFERRAL card surfaced as /c/{shortCode}, riding the same
// Referral/TapIntent spine as a physical NFC card tap (tovis-app PR #476).
// Mirrors `ClientInviteLinkResponseDTO` (lib/dto/clientInviteLink.ts).

/// `GET /api/v1/client/referrals/invite-link` → `{ ok, cardId, shortCode,
/// shortCodeDisplay, path }` (flat envelope; minted server-side on first use).
public struct ClientInviteLink: Decodable, Sendable {
    public let cardId: String
    /// Raw short code (Crockford-ish Base32).
    public let shortCode: String
    /// TOV-XXXX-XXXX display form.
    public let shortCodeDisplay: String
    /// Root-relative share path (/c/{shortCode}); clients absolutize it.
    public let path: String
}
