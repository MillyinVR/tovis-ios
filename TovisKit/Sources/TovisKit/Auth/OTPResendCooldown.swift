import Foundation

/// Resend-cooldown state for the SMS one-time-code auth surfaces (post-signup
/// phone verification + passwordless phone login). The native counterpart of
/// web's `app/(auth)/_components/otpCooldown.ts`, which both web callers share
/// for exactly the same reason: keep the two screens behaviour-identical and
/// testable without a view.
///
/// ## Why a deadline, not a countdown
/// Web ticks a seconds counter down once a second. That's fine in a tab, but a
/// phone suspends timers the moment the app backgrounds, so a decrementing
/// counter would resume where it left off and under-count the wait — offering
/// "Resend" while the server still refuses. Storing the *deadline* and deriving
/// the remainder from the clock is immune to that: time passes whether or not
/// anything is ticking. The timer then only drives redraws, never the state.
///
/// Every reader takes an explicit `now`, so the tests pin behaviour against a
/// fixed clock instead of sleeping. This is a duration, not a calendar date —
/// there is deliberately no `DateFormatter` here (see `BoardEventDate` for the
/// calendar-date case, which is the one that needs a timezone).
public struct OTPResendCooldown: Sendable, Equatable {
    /// Client-side cooldown applied after a code is sent successfully, matching
    /// web's `RESEND_COOLDOWN_SECONDS`. A successful send returns no hint of its
    /// own — the server only tells us to wait once we've already hit the limit —
    /// so this is the optimistic guard that keeps a user off it.
    public static let defaultSeconds = 60

    /// When the cooldown expires. `nil` = not cooling down.
    public private(set) var deadline: Date?

    public init(deadline: Date? = nil) {
        self.deadline = deadline
    }

    /// Start (or extend) the cooldown. Never shortens an active one: a 429's
    /// `retryAfterSeconds` can be far longer than our optimistic default (the
    /// `auth:email:send` bucket is 5 per 15 min, so it can ask for ~15 minutes),
    /// and a later, shorter send must not hand the button back early.
    public mutating func start(seconds: Int, now: Date) {
        guard seconds > 0 else { return }
        let next = now.addingTimeInterval(TimeInterval(seconds))
        if let deadline, deadline >= next { return }
        deadline = next
    }

    /// Begin the optimistic post-send cooldown.
    public mutating func startDefault(now: Date) {
        start(seconds: Self.defaultSeconds, now: now)
    }

    /// Clear the cooldown (e.g. the user switched to a different number, which
    /// is rate-limited under its own key).
    public mutating func reset() {
        deadline = nil
    }

    /// Whole seconds left, rounded up so a partial second still reads as ≥1 and
    /// the label never shows `0:00` while the button is still disabled.
    public func remainingSeconds(now: Date) -> Int {
        guard let deadline else { return 0 }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return max(1, Int(remaining.rounded(.up)))
    }

    public func isActive(now: Date) -> Bool {
        remainingSeconds(now: now) > 0
    }

    /// Seconds → `m:ss`. Mirrors web's `formatCooldown`.
    public static func format(seconds: Int) -> String {
        let safe = max(0, seconds)
        return "\(safe / 60):\(String(format: "%02d", safe % 60))"
    }

    /// `m:ss` left, or `nil` when the cooldown isn't running — so a view can
    /// pick its label with `if let`.
    public func remainingLabel(now: Date) -> String? {
        let remaining = remainingSeconds(now: now)
        guard remaining > 0 else { return nil }
        return Self.format(seconds: remaining)
    }

    /// The cooldown a failed request is asking for, or `nil` if it isn't a
    /// rate-limit refusal we can time.
    ///
    /// Only `.serverDetails` carries the hint, and only for callers that pass
    /// `captureErrorDetails: true` — the send calls in `AuthService` do.
    public static func retryAfterSeconds(from error: Error) -> Int? {
        guard let api = error as? APIError,
              case let .serverDetails(status, _, _, details) = api,
              status == 429
        else { return nil }
        return details.retryAfterSeconds
    }
}
