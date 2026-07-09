import TovisKit

/// Identifiable + Hashable wrapper so a resolved `MessageThread` can drive a
/// `navigationDestination(item:)` push. `MessageThread` is `Identifiable` (so it
/// works with `.sheet(item:)`) but not `Hashable` (its wire nested types aren't),
/// which `navigationDestination(item:)` requires — hence this thin wrapper keyed
/// on the thread id. Shared by every surface that pushes into `ThreadView`
/// (ProProfileView / ProBookingDetailView / ProClientChartView).
struct MessageThreadNav: Identifiable, Hashable {
    let thread: MessageThread
    var id: String { thread.id }
    static func == (lhs: MessageThreadNav, rhs: MessageThreadNav) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
