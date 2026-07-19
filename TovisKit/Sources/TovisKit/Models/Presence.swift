import Foundation

/// Presence signals — "N watching now" / "N on the waitlist" on the last-minute
/// opening claim path. The native counterpart of web's `PresenceSignals`
/// (app/(main)/offerings/[offeringId]/PresenceSignals.tsx) and the
/// `lib/presence/usePresenceSignals` hook that feeds it.
///
/// The whole point of this feature is the HONEST THRESHOLD, so the rule lives
/// here in ``PresenceDisplay`` where `swift test` can reach it, not in a view.

// MARK: - Wire

/// The resources presence can be tracked against. Only ever ENCODED (we send it;
/// the server never sends one back), so a strict enum is safe here — the
/// decode-as-String rule guards against unknown values arriving, which cannot
/// happen for a value we author.
public enum PresenceResourceType: String, Sendable {
    case opening
    case offering
}

/// Envelope for `GET /api/v1/presence/signals` → `{ ok, signals }`.
struct PresenceSignalsResponse: Decodable, Sendable {
    let signals: PresenceSignals
}

/// Envelope for `POST /api/v1/client/presence/heartbeat` → `{ ok, recorded }`.
struct PresenceHeartbeatResponse: Decodable, Sendable {
    let recorded: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Defensive: an older/newer backend that omits the flag is not a decode
        // failure — it just isn't telling us it recorded anything.
        recorded = try container.decodeIfPresent(Bool.self, forKey: .recorded) ?? false
    }

    private enum CodingKeys: String, CodingKey { case recorded }
}

/// Request body for the heartbeat. `clientId` is deliberately absent — the
/// server takes it from the session and IGNORES a `clientId` in the body
/// (driven 2026-07-19: a spoofed one changed nothing).
struct PresenceHeartbeatRequest: Encodable, Sendable {
    let resourceType: String
    let resourceId: String
}

/// The raw counts the server returns.
///
/// ⚠️ `watching` is `Int?` on purpose: the server answers `null` when Redis is
/// unavailable, which means **unknown**, not zero. Collapsing it to 0 would turn
/// "we can't tell" into "nobody is here" — the exact dishonesty the threshold
/// rule exists to prevent.
public struct PresenceSignals: Decodable, Sendable, Equatable {
    /// People whose heartbeat landed in the last 60s, or nil when Redis is down.
    /// **Includes the viewer themselves** once they have sent a heartbeat.
    public let watching: Int?
    /// ACTIVE `WaitlistEntry` rows for this pro (and service, when scoped).
    public let waitlisted: Int

    public init(watching: Int?, waitlisted: Int) {
        self.watching = watching
        self.waitlisted = waitlisted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeIfPresent` maps BOTH an absent key and an explicit null to nil,
        // which is what we want: both mean "unknown".
        watching = try container.decodeIfPresent(Int.self, forKey: .watching)
        waitlisted = try container.decodeIfPresent(Int.self, forKey: .waitlisted) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case watching
        case waitlisted
    }
}

// MARK: - The honest thresholds

/// What the UI is ALLOWED to say, after web's thresholds are applied. A count
/// that doesn't clear its threshold is absent here, not zero — so a view can
/// only ever render a number the server actually justified.
///
/// Thresholds are web's, verbatim (`PresenceSignals.tsx:17-18`, and identically
/// in `OpeningsFeedClient.tsx:165-166`):
/// ```
/// showWatching = typeof watching === 'number' && watching >= 2
/// showWaitlist = waitlisted >= 1
/// ```
///
/// **Why `watching >= 2` and not `>= 1`:** the viewer counts themselves — the
/// heartbeat adds them to the same set the count reads (driven 2026-07-19: one
/// heartbeat, then the read returned `watching:1`). Web's own comment says "only
/// show watching when there's more than just the current viewer". So 2 is the
/// first count that means *somebody else is here too*. This is also why this
/// client sends heartbeats rather than only reading: without them the viewer is
/// absent from the set and the identical threshold would quietly come to mean
/// "two OTHER people", i.e. a different feature wearing the same number.
public struct PresenceDisplay: Equatable, Sendable {
    /// Set only when at least ``PresenceThreshold/minWatching`` are watching.
    public let watching: Int?
    /// Set only when at least ``PresenceThreshold/minWaitlisted`` are waiting.
    public let waitlisted: Int?

    /// Nothing worth saying — below threshold, unknown, or not fetched yet.
    /// All three collapse to the same render (nothing), which is correct: none
    /// of them justifies putting a number in front of the user.
    public static let empty = PresenceDisplay(watching: nil, waitlisted: nil)

    public init(watching: Int?, waitlisted: Int?) {
        self.watching = watching
        self.waitlisted = waitlisted
    }

    /// Applies the thresholds to a set of raw counts. `nil` signals (no fetch
    /// yet, or a failed one) produce ``empty``.
    public init(signals: PresenceSignals?) {
        guard let signals else {
            self = .empty
            return
        }
        let watching = signals.watching
        self.watching = (watching ?? 0) >= PresenceThreshold.minWatching ? watching : nil
        self.waitlisted = signals.waitlisted >= PresenceThreshold.minWaitlisted
            ? signals.waitlisted
            : nil
    }

    public var isEmpty: Bool { watching == nil && waitlisted == nil }
}

public enum PresenceThreshold {
    /// The viewer counts themselves, so 2 is the first honest "someone else".
    public static let minWatching = 2
    public static let minWaitlisted = 1
}

// MARK: - Cadence

/// How often the claim screen re-reads presence, mirroring web's hook
/// (`lib/presence/usePresenceSignals.ts:12-15`): poll every 15s while the counts
/// are moving, back off to 30s once they have been identical for 3 rounds.
///
/// A failed round does NOT advance the stability counter — a poll that never
/// answered is not evidence that nothing changed.
public struct PresencePollSchedule: Equatable, Sendable {
    public static let activeInterval = Duration.seconds(15)
    public static let idleInterval = Duration.seconds(30)
    public static let idleAfterStableRounds = 3

    public private(set) var stableRounds = 0

    public init() {}

    /// Record the outcome of one successful poll.
    public mutating func record(unchanged: Bool) {
        stableRounds = unchanged ? stableRounds + 1 : 0
    }

    public var nextInterval: Duration {
        stableRounds >= Self.idleAfterStableRounds ? Self.idleInterval : Self.activeInterval
    }
}

public enum PresenceHeartbeat {
    /// Web's `HEARTBEAT_INTERVAL_MS` (`usePresenceSignals.ts:12`). Comfortably
    /// inside the server's 60s watching window, so a viewer sitting on the
    /// screen never flickers out of their own count.
    public static let interval = Duration.seconds(30)
}
