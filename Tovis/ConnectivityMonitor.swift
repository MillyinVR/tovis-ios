// Watches for the device coming back online — the offline→online EDGE
// specifically, not "is currently online". Polling the latter would race the
// queue it exists to unblock, and firing on every path update (rather than
// just the transition into `.satisfied`) would re-trigger a retry pass on
// every wifi/cellular handoff even when nothing failed.
//
// Deliberately dumb about anything past that edge: a connection that stays
// reported as "satisfied" but times out anyway (flaky salon wifi) never
// shows up here at all — that case is `UploadRetryScheduler`'s own backoff
// timer to catch, not this monitor's.
import Foundation
import Network

@MainActor
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private var wasSatisfied: Bool?
    private var started = false

    /// Fires once per offline→online transition. Set before calling `start()`.
    var onReconnect: (() -> Void)?

    /// Idempotent — `NWPathMonitor.start` traps if called twice on the same
    /// instance, and this can be invoked more than once across a `.task`
    /// re-fire (e.g. a nested sheet round-trip) on the same view identity.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if satisfied, self.wasSatisfied == false { self.onReconnect?() }
                self.wasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "tovis.connectivity-monitor"))
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }
}
