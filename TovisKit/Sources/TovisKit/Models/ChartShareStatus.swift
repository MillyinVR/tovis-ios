import Foundation

/// W5 chart consent, as one value both sides of the pair read.
///
/// The pro asks (`ProClientChartShare`) and the client answers
/// (`ClientChartShare`); the row they are both looking at is the same row, so
/// the status is one type rather than two enums that can drift apart.
///
/// 🔴 `granted` is the ONLY value that opens a chart. `requested` grants
/// nothing — a pro asking is not a pro allowed.
///
/// Mirrors `ClientChartShareStatus` in prisma/schema.prisma.
public enum ChartShareStatus: String, Decodable, Sendable, CaseIterable {
    /// The pro asked; the client hasn't answered. Grants nothing.
    case requested = "REQUESTED"
    /// The client said yes. The only value that opens the chart.
    case granted = "GRANTED"
    /// The client said no. Distinct from `revoked` so a pro cannot re-ask by
    /// waiting out an absent row, and so "declined" isn't read as "never asked".
    case declined = "DECLINED"
    /// The client granted, then took it back. Re-askable after a cooldown.
    case revoked = "REVOKED"

    /// Whether this pro can read the chart right now.
    ///
    /// Written as an explicit switch, not `self == .granted`, so adding a fifth
    /// case is a compile error here rather than a silent "no" — and if a future
    /// state ever does open the chart, the compiler makes someone decide.
    public var grantsAccess: Bool {
        switch self {
        case .granted: return true
        case .requested, .declined, .revoked: return false
        }
    }

    /// The line the CLIENT reads for this state. Mirrors `STATUS_COPY` in
    /// app/client/(gated)/settings/ClientChartSharingSettings.tsx — the two
    /// clients describe the same row the same way.
    public var clientCopy: String {
        switch self {
        case .granted: return "Can see your chart"
        case .requested: return "Asked to see your chart"
        case .declined: return "You said no"
        case .revoked: return "You turned this off"
        }
    }
}
