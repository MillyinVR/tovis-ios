// Where a client's name/avatar leads on a PRO-facing screen.
//
// The native mirror of tovis-app's `clientIdentityHref`
// (lib/profiles/profileHrefs.ts) — one rule, three outcomes:
//
//   1. the pro-only CHART, when the server exposed a ClientProfile id
//   2. else the client's PUBLIC profile, when the server exposed a handle
//   3. else NOWHERE — render the name as plain, untappable text
//
// The two inputs are independent axes and the server has already decided both:
// an id means "this pro may open the private chart", a handle means "a
// world-readable /u/{handle} page exists". Neither is derived on device, so a
// screen can't widen its own access by getting the precedence wrong.
//
// 🔴 Case 2 is the one that was missing. W5 narrowed chart access to an
// active/recent booking, so a client outside that window arrives with no id —
// and every pro screen rendered them as dead text, including clients whose
// profile anyone on the internet can read. On the calendar's waitlist rows that
// was every single client, because joining a waitlist creates a message thread
// and nothing else (the CONTACT_ONLY tier), which never grants a chart.
//
// Case 3 is a REAL state, not a fallback: a client who never opted into a public
// profile has no public page BY DESIGN (the W-series privacy work), so there is
// genuinely nothing to open and nothing should look tappable.
//
// This lives in TovisKit rather than inline in each view so the rule is stated
// once and can be tested without a running app — the three screens that use it
// (ProClientsView, ProCalendarManagementSheet, ProBookingDetailView) had three
// copies of the same `if let … else if let … else` before.
import Foundation

public enum ClientIdentityDestination: Equatable, Sendable {
    /// The pro-only client chart, keyed by ClientProfile id.
    case chart(clientId: String)
    /// The client's public `/u/{handle}` creator profile.
    case publicProfile(handle: String)
    /// Nowhere to go — render the name as plain text, with no tap target.
    case none

    /// True when the identity should render as a tappable control. Drives
    /// chevrons and link styling, so they can't promise a destination that
    /// `resolve` would refuse (or hide one it would allow).
    public var isTappable: Bool { self != .none }

    /// Resolve the destination from the two server-decided fields.
    ///
    /// - Parameters:
    ///   - clientProfileId: non-nil only when this pro may open the chart.
    ///   - publicProfileHandle: non-nil only when a public profile exists.
    ///
    /// Blank strings are treated as absent — a whitespace handle would build
    /// `/u/` and land on a page that isn't this client's.
    public static func resolve(
        clientProfileId: String?,
        publicProfileHandle: String?
    ) -> ClientIdentityDestination {
        if let id = clientProfileId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return .chart(clientId: id)
        }
        if let handle = publicProfileHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !handle.isEmpty {
            return .publicProfile(handle: handle)
        }
        return .none
    }
}

public extension ClientIdentityDestination {
    /// Same rule for the roster reads (`GET /pro/clients`, `/pro/clients/search`),
    /// whose DTO carries the id ALWAYS and gates it with a separate
    /// `canViewClient` flag rather than by nulling the id.
    ///
    /// Routing through the same resolver — instead of a second `if` at the call
    /// site — is what keeps the roster from disagreeing with the calendar and
    /// the booking detail about where a given client's name goes.
    static func resolve(
        clientId: String,
        canViewClient: Bool,
        publicProfileHandle: String?
    ) -> ClientIdentityDestination {
        resolve(
            clientProfileId: canViewClient ? clientId : nil,
            publicProfileHandle: publicProfileHandle
        )
    }
}
