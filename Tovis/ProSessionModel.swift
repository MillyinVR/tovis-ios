// The PRO footer center button's brain — a native port of the web
// `useProSession` hook (`tovis-app/app/_components/ProSessionFooter`).
//
// The SERVER is the source of truth for the button's state: we GET /pro/session,
// render exactly the label/action it returns, and on tap POST start/finish then
// navigate to the href it hands back. We never re-derive the flow locally — this
// is purely transport + presentation, so web and iOS behave identically.
import SwiftUI
import TovisKit

@MainActor
@Observable
final class ProSessionModel {
    private let client: TovisClient

    private(set) var mode: ProSessionMode = .idle
    private(set) var booking: ProSessionBooking?
    private(set) var eligibleBookings: [ProSessionBooking] = []
    private(set) var center: ProSessionCenter = ProSessionCenter(label: "Start", action: .none, href: nil)

    private(set) var loading = false
    /// `start` / `nav` while a tap is in flight (drives the button label).
    private(set) var actionLoading: ActionKind?
    var error: String?

    /// The booking picker sheet (UPCOMING_PICKER with >1 eligible).
    var pickerOpen = false

    /// A navigation request the shell consumes: the booking whose session screen
    /// to present. Set by START/FINISH/NAVIGATE/CAPTURE; cleared once routed.
    private(set) var navTarget: String?

    enum ActionKind { case start, nav }

    init(client: TovisClient) {
        self.client = client
    }

    // MARK: - Derived

    /// Whether the center is in a live state (pulse + CTA gradient), mirroring
    /// the web `centerIsLive`.
    var isLive: Bool {
        !centerDisabled && (mode == .active || mode == .upcoming || mode == .upcomingPicker)
    }

    var showsCamera: Bool {
        center.action == .captureBefore || center.action == .captureAfter
    }

    /// Eligible-booking count badge when picking (web `pickerCount`).
    var pickerCount: Int {
        mode == .upcomingPicker && eligibleBookings.count > 1 ? eligibleBookings.count : 0
    }

    /// The label shown on the coin (clamped to 8 chars like the web).
    var label: String {
        let raw: String
        switch actionLoading {
        case .start: raw = "Starting…"
        case .nav: raw = "Opening…"
        case nil: raw = center.label.isEmpty ? "Start" : center.label
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Start" }
        return trimmed.count <= 8 ? trimmed : String(trimmed.prefix(8)) + "…"
    }

    /// Port of `canClickCenter`: when the button is tappable.
    var centerDisabled: Bool {
        if actionLoading != nil { return true }
        switch center.action {
        case .none, .unknown:
            return true
        case .start, .finish:
            return booking?.id == nil
        case .pickBooking:
            return eligibleBookings.count <= 1
        case .navigate, .captureBefore, .captureAfter:
            return center.href == nil && booking?.id == nil
        }
    }

    // MARK: - Load

    func load(silent: Bool = false) async {
        if !silent { loading = true; error = nil }
        defer { if !silent { loading = false } }
        do {
            let payload = try await client.proSession.session()
            mode = payload.mode
            booking = payload.booking
            eligibleBookings = payload.eligibleBookings ?? []
            center = payload.center
            if mode != .upcomingPicker { pickerOpen = false }
        } catch let err as APIError {
            if !silent { error = err.userMessage }
        } catch {
            if !silent { self.error = "Couldn’t load your session." }
        }
    }

    // MARK: - Actions

    func handleCenterClick() async {
        guard !centerDisabled else { return }
        error = nil

        switch center.action {
        case .pickBooking:
            pickerOpen = true

        case .start:
            guard let id = booking?.id else { return }
            await run(.start) { try await self.client.proSession.start(bookingId: id) }

        case .finish:
            guard let id = booking?.id else { return }
            await run(.nav) { try await self.client.proSession.finish(bookingId: id) }

        case .navigate, .captureBefore, .captureAfter:
            // Pure navigation: go to the resolved href (or the booking's hub).
            navTarget = bookingId(from: center.href) ?? booking?.id

        case .none, .unknown:
            break
        }
    }

    /// Start a specific booking from the picker sheet.
    func startSelected(_ bookingId: String) async {
        error = nil
        pickerOpen = false
        await run(.start) { try await self.client.proSession.start(bookingId: bookingId) }
    }

    func clearNavTarget() { navTarget = nil }

    // MARK: - Helpers

    /// Run a start/finish POST, then refetch and route to the next screen. The
    /// server's `nextHref` (or the refreshed center href) decides where to land.
    private func run(_ kind: ActionKind, _ action: @escaping () async throws -> String?) async {
        actionLoading = kind
        defer { actionLoading = nil }
        do {
            let nextHref = try await action()
            await load(silent: true)
            navTarget = bookingId(from: nextHref) ?? bookingId(from: center.href) ?? booking?.id
        } catch let err as APIError {
            error = err.userMessage
            await load(silent: true)
        } catch {
            self.error = "Something went wrong."
            await load(silent: true)
        }
    }

    /// Pull the booking id out of a `/pro/bookings/{id}/session…` href.
    private func bookingId(from href: String?) -> String? {
        guard let href else { return nil }
        let parts = href.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? href
        let segs = parts.split(separator: "/").map(String.init)
        guard let i = segs.firstIndex(of: "bookings"), i + 1 < segs.count else { return nil }
        return segs[i + 1]
    }
}
