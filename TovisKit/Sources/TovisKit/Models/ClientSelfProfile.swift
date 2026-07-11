import Foundation

// Wire models + chip catalog for the client's personalization self-profile —
// GET/PATCH /api/v1/client/self-profile. Mirrors app/api/v1/client/self-profile/route.ts,
// which serializes the validated ClientSelfProfile the web
// app/client/(gated)/settings/ClientSelfProfileSettings.tsx card reads and edits.
//
// Everything here is explicit + user-entered (personalization spec §6.6, guardrail #5):
// nothing is ever inferred, every field is optional and clearable. The server
// (lib/personalization/selfProfile.ts) is the authoritative validator — it stores only
// values that are one of a question's option values — so the catalog below is only for
// RENDERING the chips; a drifted or hand-edited value can never round-trip through it.

/// A single-choice self-profile field. The raw value is the snake_case JSON key the
/// route reads/writes (matching SELF_PROFILE_FIELD_KEYS in the web lib).
public enum SelfProfileFieldKey: String, CaseIterable, Sendable {
    case hairType = "hair_type"
    case hairLength = "hair_length"
    case hairColor = "hair_color"
    case skinType = "skin_type"
    case skinConcern = "skin_concern"
}

/// One chip option — the `value` is stored, the `label` is shown. Values match the
/// web lib 1:1 (so board answers can write through unchanged, per spec §7.3).
public struct SelfProfileOption: Sendable, Equatable, Identifiable {
    public let value: String
    public let label: String
    public var id: String { value }

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// A single-choice chip question: its field key, prompt, and options.
public struct SelfProfileQuestion: Sendable, Equatable, Identifiable {
    public let key: SelfProfileFieldKey
    public let label: String
    public let options: [SelfProfileOption]
    public var id: String { key.rawValue }

    public init(key: SelfProfileFieldKey, label: String, options: [SelfProfileOption]) {
        self.key = key
        self.label = label
        self.options = options
    }
}

/// The static chip catalog — a faithful port of SELF_PROFILE_QUESTIONS +
/// SELF_PROFILE_INTEREST_OPTIONS in lib/personalization/selfProfile.ts. The server
/// stays SSOT for validation; this only drives the UI.
public enum SelfProfileCatalog {
    /// Multi-select category interests (the cold-start onboarding chips, spec §2.1).
    public static let interestOptions: [SelfProfileOption] = [
        SelfProfileOption(value: "hair", label: "Hair"),
        SelfProfileOption(value: "hair-color", label: "Hair color"),
        SelfProfileOption(value: "makeup", label: "Makeup"),
        SelfProfileOption(value: "nails", label: "Nails"),
        SelfProfileOption(value: "skincare", label: "Skincare"),
        SelfProfileOption(value: "brows", label: "Brows / lashes"),
    ]

    /// Single-choice chip questions (hair type/length/color, skin type/concern).
    public static let questions: [SelfProfileQuestion] = [
        SelfProfileQuestion(key: .hairType, label: "Your hair type?", options: [
            SelfProfileOption(value: "straight", label: "Straight"),
            SelfProfileOption(value: "wavy", label: "Wavy"),
            SelfProfileOption(value: "curly", label: "Curly"),
            SelfProfileOption(value: "coily", label: "Coily"),
        ]),
        SelfProfileQuestion(key: .hairLength, label: "How long is your hair?", options: [
            SelfProfileOption(value: "short", label: "Short"),
            SelfProfileOption(value: "medium", label: "Medium"),
            SelfProfileOption(value: "long", label: "Long"),
        ]),
        SelfProfileQuestion(key: .hairColor, label: "Your current hair color?", options: [
            SelfProfileOption(value: "blonde", label: "Blonde"),
            SelfProfileOption(value: "brunette", label: "Brunette"),
            SelfProfileOption(value: "black", label: "Black"),
            SelfProfileOption(value: "red", label: "Red"),
            SelfProfileOption(value: "gray", label: "Gray / silver"),
            SelfProfileOption(value: "other", label: "Something else"),
        ]),
        SelfProfileQuestion(key: .skinType, label: "How would you describe your skin?", options: [
            SelfProfileOption(value: "oily", label: "Oily"),
            SelfProfileOption(value: "dry", label: "Dry"),
            SelfProfileOption(value: "combination", label: "Combination"),
            SelfProfileOption(value: "sensitive", label: "Sensitive"),
            SelfProfileOption(value: "normal", label: "Normal"),
        ]),
        SelfProfileQuestion(key: .skinConcern, label: "What matters most for your skin?", options: [
            SelfProfileOption(value: "acne", label: "Breakouts"),
            SelfProfileOption(value: "aging", label: "Fine lines"),
            SelfProfileOption(value: "dullness", label: "Dullness"),
            SelfProfileOption(value: "redness", label: "Redness"),
            SelfProfileOption(value: "texture", label: "Texture"),
        ]),
    ]
}

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

/// Envelope for `GET`/`PATCH /api/v1/client/self-profile` → `{ selfProfile, updatedAt }`
/// (PATCH also carries `ok`, ignored). `selfProfile` is null when the client hasn't
/// entered anything yet, so it decodes as optional.
struct ClientSelfProfileResponse: Decodable, Sendable {
    let selfProfile: ClientSelfProfile?
}

/// The validated self-profile: the five single-choice fields + declared interests.
/// Each field is nil until chosen; `interests` defaults to empty when absent. Decoded
/// via the snake_case keys the route emits.
public struct ClientSelfProfile: Decodable, Sendable, Equatable {
    public var hairType: String?
    public var hairLength: String?
    public var hairColor: String?
    public var skinType: String?
    public var skinConcern: String?
    public var interests: [String]

    public init(
        hairType: String? = nil,
        hairLength: String? = nil,
        hairColor: String? = nil,
        skinType: String? = nil,
        skinConcern: String? = nil,
        interests: [String] = []
    ) {
        self.hairType = hairType
        self.hairLength = hairLength
        self.hairColor = hairColor
        self.skinType = skinType
        self.skinConcern = skinConcern
        self.interests = interests
    }

    private enum CodingKeys: String, CodingKey {
        case hairType = "hair_type"
        case hairLength = "hair_length"
        case hairColor = "hair_color"
        case skinType = "skin_type"
        case skinConcern = "skin_concern"
        case interests
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hairType = try c.decodeIfPresent(String.self, forKey: .hairType)
        hairLength = try c.decodeIfPresent(String.self, forKey: .hairLength)
        hairColor = try c.decodeIfPresent(String.self, forKey: .hairColor)
        skinType = try c.decodeIfPresent(String.self, forKey: .skinType)
        skinConcern = try c.decodeIfPresent(String.self, forKey: .skinConcern)
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? []
    }

    /// The chosen value for a single-choice field key, if any.
    public func value(for key: SelfProfileFieldKey) -> String? {
        switch key {
        case .hairType: return hairType
        case .hairLength: return hairLength
        case .hairColor: return hairColor
        case .skinType: return skinType
        case .skinConcern: return skinConcern
        }
    }
}

/// PATCH body for a self-profile update. Mirrors the web form
/// (ClientSelfProfileSettings.onSave), which sends **all five field keys every time**
/// — the chosen option value, or an explicit JSON `null` to clear an unselected field —
/// plus the full `interests` array (an empty array clears every interest). An *absent*
/// key means "no change" server-side, so nil fields are encoded as JSON null, never
/// omitted (the same explicit-null clear semantics as the /client/settings PATCH).
struct ClientSelfProfileUpdateRequest: Encodable, Sendable {
    let fields: [SelfProfileFieldKey: String]
    let interests: [String]

    private enum CodingKeys: String, CodingKey {
        case hairType = "hair_type"
        case hairLength = "hair_length"
        case hairColor = "hair_color"
        case skinType = "skin_type"
        case skinConcern = "skin_concern"
        case interests
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeField(&c, .hairType, forKey: .hairType)
        try encodeField(&c, .hairLength, forKey: .hairLength)
        try encodeField(&c, .hairColor, forKey: .hairColor)
        try encodeField(&c, .skinType, forKey: .skinType)
        try encodeField(&c, .skinConcern, forKey: .skinConcern)
        try c.encode(interests, forKey: .interests)
    }

    /// Emit the chosen value, or an explicit JSON `null` to clear an unselected field.
    private func encodeField(
        _ c: inout KeyedEncodingContainer<CodingKeys>,
        _ field: SelfProfileFieldKey,
        forKey key: CodingKeys
    ) throws {
        if let value = fields[field] {
            try c.encode(value, forKey: key)
        } else {
            try c.encodeNil(forKey: key)
        }
    }
}
