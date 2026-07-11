import Foundation

// Wire models for the client account settings — GET/PATCH /api/v1/client/settings.
// Mirrors the (DTO-less) inline shape in app/api/v1/client/settings/route.ts, which
// serializes the same profile the web Settings → Profile card (ClientProfileSettings)
// reads and edits. The route also returns `addresses` alongside `profile`; that list
// is served by AddressesService (GET /api/v1/client/addresses) and decoded via
// ClientAddress, so it is intentionally NOT re-modeled here (unknown keys are ignored).

/// Envelope for `GET`/`PATCH /api/v1/client/settings` → `{ ok, profile, addresses }`.
struct ClientSettingsResponse: Decodable, Sendable {
    let profile: ClientSettingsProfile
}

/// The client's editable account/identity details. `firstName`/`lastName` are always
/// strings server-side (the route falls back to `''`); `phone`, `avatarUrl`, and
/// `dateOfBirth` are nullable. `dateOfBirth` is a date-only `YYYY-MM-DD` string.
public struct ClientSettingsProfile: Decodable, Sendable, Equatable {
    public let id: String
    public let email: String?
    public let firstName: String
    public let lastName: String
    public let phone: String?
    public let avatarUrl: String?
    public let dateOfBirth: String?
}

/// PATCH body for a profile update. Mirrors the web form, which always sends all five
/// keys and uses **explicit `null`** on the nullable ones to clear them (an *absent*
/// key means "no change" server-side, so nil is encoded as JSON null — not omitted —
/// to keep the "cleared the field" case working like the web).
struct ClientProfileUpdateRequest: Encodable, Sendable {
    let firstName: String
    let lastName: String
    let phone: String?
    let avatarUrl: String?
    let dateOfBirth: String?

    enum CodingKeys: String, CodingKey {
        case firstName, lastName, phone, avatarUrl, dateOfBirth
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(firstName, forKey: .firstName)
        try c.encode(lastName, forKey: .lastName)
        try encodeNullable(&c, phone, forKey: .phone)
        try encodeNullable(&c, avatarUrl, forKey: .avatarUrl)
        try encodeNullable(&c, dateOfBirth, forKey: .dateOfBirth)
    }

    /// Emit the key as an explicit JSON `null` when nil (clear), else the value.
    private func encodeNullable(
        _ c: inout KeyedEncodingContainer<CodingKeys>,
        _ value: String?,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try c.encode(value, forKey: key)
        } else {
            try c.encodeNil(forKey: key)
        }
    }
}
