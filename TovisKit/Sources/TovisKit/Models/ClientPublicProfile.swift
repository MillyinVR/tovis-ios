import Foundation

// Wire models for the signed-in client's OWN editable public-creator identity —
// GET/PATCH /api/v1/client/profile. Mirrors the (DTO-less) `clientPublicProfileSelect`
// in app/api/v1/client/profile/route.ts, the exact shape the web
// app/client/(gated)/settings/ClientPublicProfileSettings.tsx card reads and edits.
//
// Distinct from ProClientPublicProfile / PublicClientService, which decode SOMEONE
// ELSE's public profile (`/u/{handle}`, `/pro/clients/{id}/public-profile`) for
// display. This is the owner's private settings view of their public identity —
// handle, the public toggle, and the bio — so it's a separate, small model.
//
// `handle` and `publicBio` are nullable server-side (unset). They decode as optional
// and the editor treats nil as "" (matching the web form's `?? ''`).

/// Envelope for `GET`/`PATCH /api/v1/client/profile`. GET returns `{ profile }`;
/// PATCH returns `{ ok, profile }`. Both carry `profile`, so one envelope serves both.
struct ClientPublicProfileResponse: Decodable, Sendable {
    let profile: ClientPublicProfileSettings
}

/// The client's editable public-creator identity: `@handle`, the public toggle, and
/// the public bio. `isPublicProfile` is always a boolean server-side; `handle` and
/// `publicBio` are null until set. Decoded defensively (`decodeIfPresent`) so a
/// partial/older payload still decodes cleanly.
public struct ClientPublicProfileSettings: Decodable, Sendable, Equatable {
    public let id: String
    public let handle: String?
    public let isPublicProfile: Bool
    public let publicBio: String?

    public init(id: String, handle: String?, isPublicProfile: Bool, publicBio: String?) {
        self.id = id
        self.handle = handle
        self.isPublicProfile = isPublicProfile
        self.publicBio = publicBio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        isPublicProfile = try c.decodeIfPresent(Bool.self, forKey: .isPublicProfile) ?? false
        publicBio = try c.decodeIfPresent(String.self, forKey: .publicBio)
    }

    private enum CodingKeys: String, CodingKey { case id, handle, isPublicProfile, publicBio }
}

/// PATCH body for a public-profile update. Mirrors the web form, which always sends
/// all three keys as `{ handle, isPublicProfile, publicBio }`. Unlike the
/// `/client/settings` PATCH (which clears via explicit JSON `null`), THIS route
/// clears `handle`/`publicBio` via an **empty string** — the server trims each and
/// treats "" as "clear this field" — so both are plain, always-present strings.
struct ClientPublicProfileUpdateRequest: Encodable, Sendable {
    let handle: String
    let isPublicProfile: Bool
    let publicBio: String
}
