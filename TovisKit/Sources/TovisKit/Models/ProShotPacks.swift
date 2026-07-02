import Foundation

// Wire models for the trending camera shot packs — GET /api/v1/pro/camera/
// shot-packs (tovis-app PR #453). Server-driven pose/shot recipes: the trend
// CONTENT lives on the server (refreshed without an app release); the app owns
// the fixed vocabulary of measurable pose-rule kinds and drops kinds it
// doesn't recognize (so the server can ship new vocabulary ahead of old
// builds — `kind` decodes as a plain string here for exactly that reason).

/// `GET /api/v1/pro/camera/shot-packs` → `{ ok, version, packs }`.
public struct ProShotPacksResponse: Decodable, Sendable {
    /// Content version — bump = new trend drop; clients may cache against it.
    public let version: Int
    /// Trending packs, hottest first.
    public let packs: [ProShotPack]
}

public struct ProShotPack: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// One-line seller shown under the pack name in the picker.
    public let tagline: String
    /// Lowercased keywords matched against the booking's base service name.
    public let serviceKeywords: [String]
    /// Editorial ranking, higher = hotter.
    public let trendScore: Int
    public let steps: [ProShotPackStep]
}

public struct ProShotPackStep: Decodable, Sendable {
    public let title: String
    public let hint: String
    /// SF Symbol name for the guide bar.
    public let icon: String
    /// "required" | "absent" | "either" — whether the face belongs in shot.
    public let face: String
    /// Target subject-fill band (both-or-neither).
    public let fillBandMin: Double?
    public let fillBandMax: Double?
    public let isDetail: Bool
    public let allowsClosedEyes: Bool
    public let pose: [ProShotPackPoseRule]
}

public struct ProShotPackPoseRule: Decodable, Sendable {
    /// Rule vocabulary id — the app maps known kinds to evaluators and DROPS
    /// unknown ones (deliberately a plain string, not an enum).
    public let kind: String
    /// Kind-specific numeric parameters.
    public let params: [String: Double]?
    /// The directive the coach shows/speaks while the rule is unmet.
    public let tip: String
}
