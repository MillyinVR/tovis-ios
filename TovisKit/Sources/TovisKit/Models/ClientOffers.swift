import Foundation

// Wire models for the client's priority-offers surface — the native counterpart
// to the web /client/offers page (app/client/(gated)/offers). That page merges
// two feeds, each shipped verbatim here:
//
//   • Priority offers  — GET /api/v1/client/priority-offer  → the last-minute
//     openings this client is FIRST IN LINE for, each with a countdown window.
//     Claim it (accept, then book the slot) or pass. Mirrors OffersListClient.
//   • Waitlist offers  — GET /api/v1/client/waitlist-offers → specific times a
//     pro proposed to a waitlisted client. Confirm (books it) or decline.
//     Mirrors WaitlistOfferCards.
//
// Nullable fields are Swift optionals and unknown keys are ignored, so a partial
// payload never fails to decode. The countdown/expiry derivations are pure and
// tested; the view supplies `now`.

// MARK: - Priority offers (GET /api/v1/client/priority-offer)

/// Envelope for `GET /api/v1/client/priority-offer` → `{ ok, offers }`.
struct ClientPriorityOfferResponse: Decodable, Sendable {
    let offers: [ClientPriorityOffer]
}

/// One priority offer — a last-minute opening this client has an exclusive claim
/// window on. `recipientId` is the `LastMinuteRecipient` id used by accept/pass.
public struct ClientPriorityOffer: Decodable, Sendable, Identifiable {
    public let recipientId: String
    public let status: String
    /// ISO instant the priority window closes, or nil when the offer has no timer.
    public let expiresAt: String?
    /// Server's own expiry verdict at fetch time (the timer refines it live).
    public let expired: Bool
    public let proName: String
    public let proHref: String?
    /// The pro's profile id — used to resolve the offering and open its booking
    /// flow (the flat id the web PR added alongside `proHref`/`claimHref`).
    public let professionalId: String?
    public let avatarUrl: String?
    public let serviceLabel: String
    /// The primary service + offering ids the claim books (flat, added web-side).
    public let serviceId: String?
    public let offeringId: String?
    /// The `LastMinuteOpening.id` this offer is for, threaded into `finalize` so the
    /// claim consumes the opening + applies its tier incentive (parity with the
    /// openings feed / web's `claimHref`, which already carries `openingId`).
    /// Optional — added to the priority-offer route DTO in a paired web change, so it
    /// decodes to `nil` until that deploys.
    public let openingId: String?
    public let startAt: String
    public let endAt: String?
    public let timeZone: String?
    public let locationType: String?
    public let note: String?
    /// Human incentive copy ("20% off", "$15 off", …) when the offer carries one.
    public let incentiveLabel: String?
    /// Web claim link (`/offerings/{id}?scheduledFor=…`); kept for reference.
    public let claimHref: String?

    public var id: String { recipientId }
}

public extension ClientPriorityOffer {
    /// Seconds left on the claim window, clamped at zero; nil when there is no
    /// timer (`expiresAt` missing/unparseable). Parses the instant with TovisKit's
    /// shared ISO reader (`ProCalendarGrid.parseISO`) — no separate parser.
    func remaining(now: Date) -> TimeInterval? {
        guard let expiresAt, let expiry = ProCalendarGrid.parseISO(expiresAt) else { return nil }
        return max(0, expiry.timeIntervalSince(now))
    }

    /// True once the window has closed — either the server said so at fetch time
    /// or the live timer has run it out. Mirrors the web `expired || remaining<=0`.
    func isExpired(now: Date) -> Bool {
        if expired { return true }
        if let remaining = remaining(now: now) { return remaining <= 0 }
        return false
    }

    /// Whether to flag the countdown as urgent (≤ 5 minutes), mirroring the web
    /// `remainingMs <= 5*60*1000` accent.
    func isUrgent(now: Date) -> Bool {
        guard !isExpired(now: now), let remaining = remaining(now: now) else { return false }
        return remaining <= 5 * 60
    }

    /// Whether this offer can be claimed into a booking (has an offering to route
    /// to). The card still renders without it, but "Claim it" falls back to the
    /// pro's profile — mirroring the openings feed's non-bookable handling.
    var isBookable: Bool {
        (serviceId?.trimmedOrNil ?? offeringId?.trimmedOrNil) != nil
    }

    /// The claimable opening this offer refers to, found in the client's openings
    /// feed by `openingId`.
    ///
    /// WHY THIS EXISTS. An opening is ONE time. Claiming used to hand the offer to
    /// the generic booking flow, which builds its grid from GENERAL availability —
    /// but `finalize` throws `OPENING_NOT_AVAILABLE` unless the booked minute equals
    /// the opening's `startAt`, so every slot the picker offered was a guaranteed
    /// failure, and the exclusive window had already been spent accepting. #180
    /// fixed exactly this for the openings feed by routing to a single-slot claim
    /// screen; this resolves the same `ClientOpening` that screen takes, so the
    /// priority path reuses it rather than growing a second claim implementation.
    ///
    /// Only callable AFTER the offer is accepted: the openings feed excludes
    /// `PRIORITY_OFFERED` rows and admits them once accept flips them to `CLICKED`.
    /// Returns nil when the offer carries no `openingId`, when no row matches, or
    /// when the matched row is not bookable — every one of which is a caller's cue
    /// to fall back, never to reopen a free-choice picker.
    func claimableOpening(in openings: [ClientOpening]) -> ClientOpening? {
        guard let openingId = openingId?.trimmedOrNil else { return nil }
        return openings.first { $0.opening.id == openingId && $0.isBookable }
    }

    /// "m:ss" countdown for a remaining interval (e.g. 65s → "1:05", ≤0 → "0:00").
    /// Pure mirror of the web `formatCountdown`.
    static func countdownLabel(_ remaining: TimeInterval) -> String {
        if remaining <= 0 { return "0:00" }
        let total = Int(remaining)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

// MARK: - Waitlist offers (GET /api/v1/client/waitlist-offers)

/// Envelope for `GET /api/v1/client/waitlist-offers` → `{ ok, offers }`.
struct ClientWaitlistOfferResponse: Decodable, Sendable {
    let offers: [ClientWaitlistOffer]
}

/// One pro-proposed waitlist time awaiting the client's response (PENDING only).
/// `offerId` keys the confirm/decline POST.
public struct ClientWaitlistOffer: Decodable, Sendable, Identifiable {
    public let offerId: String
    public let status: String
    public let proName: String
    public let proHref: String?
    public let avatarUrl: String?
    public let serviceLabel: String
    public let startAt: String
    public let endAt: String?
    public let timeZone: String?
    public let locationType: String?
    public let expiresAt: String?

    public var id: String { offerId }
}

// MARK: - Waitlist-offer respond (POST /api/v1/client/waitlist-offers/{id})

/// The action body for a waitlist-offer response. CONFIRM materializes a booking;
/// DECLINE returns the entry to the pro's active waitlist.
struct WaitlistOfferActionRequest: Encodable, Sendable {
    let action: String
}

/// `{ ok, booking? }` — `booking` is present only on a CONFIRM (the new
/// appointment). Reuses `RebookedBooking` (`{ id, status, scheduledFor }`), the
/// same shape the aftercare-rebook confirm returns.
struct WaitlistOfferRespondResponse: Decodable, Sendable {
    let booking: RebookedBooking?
}
