// Framework-agnostic, in-memory behavior consumed by CoachEngine.
//
// Persisted pro preferences adapt into this value, while another camera can
// opt into screen-only coaching without touching those preferences or the
// pro camera's destination/custody/upload state.
struct CoachRuntimeOptions: Sendable, Equatable {
    let speak: Bool
    let haptics: Bool
    let autoHarvest: Bool
    let personality: CoachPersonality

    /// No audio session, haptics, frame harvesting, or disk-backed tray.
    static let visualOnly = CoachRuntimeOptions(
        speak: false,
        haptics: false,
        autoHarvest: false,
        personality: .calmMentor
    )
}
