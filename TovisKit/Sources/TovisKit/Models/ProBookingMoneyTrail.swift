import Foundation

// Booking "money trail" — the read side of the Phase 2.5 refund inspector. One
// trustworthy view of everything money that ever happened to a booking (the
// final-bill charge, the up-front deposit, the one-time discovery fee, any
// no-show / late-cancel fee, and every refund row) plus the capability flags the
// inspector uses to gate its refund / waive actions.
//
// 1:1 with the web `BookingMoneyTrail` (tovis-app `lib/booking/moneyTrail.ts`)
// served by `GET /api/v1/bookings/{id}/money-trail`. Amounts are integer CENTS
// (`Int`); instants are ISO-8601 UTC strings resolved to a timezone only at the
// view edge (mirrors the web `lib/time` rule). Server enum values stay raw
// `String` and are compared case-insensitively in the view — the same idiom
// `ProBookingDetail` uses — so a new server value never fails decoding.

/// `GET /api/v1/bookings/{id}/money-trail` → `{ ok, trail }`.
public struct ProBookingMoneyTrailResponse: Decodable, Sendable {
    public let trail: ProBookingMoneyTrail
}

/// The assembled money trail for one booking. Read-only; the numbers are DISPLAY
/// numbers — the refund service re-derives the authoritative refundable amount, so
/// `capabilities.refundableRemainingCents` is a safe hint, never a promise.
public struct ProBookingMoneyTrail: Decodable, Sendable {
    public let bookingId: String
    /// Lowercase ISO currency code (e.g. "usd").
    public let currency: String
    /// "STRIPE" | "MANUAL".
    public let paymentProvider: String
    public let bill: Bill
    /// The final-bill Stripe charge — nil for a MANUAL/cash booking with no charge.
    public let finalCharge: FinalCharge?
    /// The up-front deposit — nil when no deposit was ever required.
    public let deposit: Deposit?
    /// The one-time platform discovery fee — nil when none applied.
    public let discoveryFee: DiscoveryFee?
    /// The no-show / late-cancel fee — nil when none was ever assessed.
    public let noShowFee: NoShowFee?
    public let refunds: [Refund]
    public let summary: Summary
    public let capabilities: Capabilities

    public struct Bill: Decodable, Sendable {
        public let totalCents: Int?
        public let serviceSubtotalCents: Int?
        public let tipCents: Int?
        public let taxCents: Int?
        public let discountCents: Int?
        /// "NOT_READY" | "READY" | "PARTIALLY_PAID" | "PAID" | "WAIVED" | "AWAITING_CONFIRMATION".
        public let checkoutStatus: String
        /// "CASH" | "CARD_ON_FILE" | "TAP_TO_PAY" | … — nil until a method is chosen.
        public let selectedPaymentMethod: String?
        public let collectedAt: String?
    }

    public struct FinalCharge: Decodable, Sendable {
        /// Stripe payment status: "SUCCEEDED" | "DISPUTED" | "PROCESSING" | ….
        public let status: String
        public let capturedCents: Int
        public let applicationFeeCents: Int?
        public let paidAt: String?
    }

    public struct Deposit: Decodable, Sendable {
        /// "NONE" | "PENDING" | "PAID" | "REFUNDED" | "FAILED".
        public let status: String
        public let amountCents: Int?
        public let paidAt: String?
        public let creditedAt: String?
        public let refundedCents: Int
        /// Set when the deposit charge is under (or lost) a Stripe dispute — Stripe
        /// has pulled the funds even though `status` still reads PAID (the deposit
        /// rides its own PaymentIntent). Cleared if the dispute is WON. A disputed
        /// deposit must not render as money safely received. See web M4.
        public let disputedAt: String?
    }

    public struct DiscoveryFee: Decodable, Sendable {
        public let amountCents: Int
        public let refundedAt: String?
    }

    public struct NoShowFee: Decodable, Sendable {
        /// "SKIPPED" | "CHARGED" | "FAILED" | "WAIVED" | "REFUNDED".
        public let status: String
        /// "NO_SHOW" | "LATE_CANCEL" — nil defensively.
        public let reason: String?
        public let amountCents: Int?
        public let chargedAt: String?
        public let markedAt: String?
        /// Stripe's cumulative refund on the fee's OWN PaymentIntent (integer cents).
        /// A FULL refund also flips `status` to REFUNDED; a sub-fee partial stays
        /// CHARGED and only accumulates here. See web M15 GAP B.
        public let refundedCents: Int
        /// Set while the fee charge is under (or lost) a Stripe dispute — the fee
        /// rides its own PI, so a chargeback never touches the booking's payment
        /// status. Cleared if the dispute is WON. A disputed fee must not render as
        /// money safely collected.
        public let disputedAt: String?
    }

    public struct Refund: Decodable, Sendable, Identifiable {
        public let id: String
        public let amountCents: Int
        /// Lowercase ISO currency code for this refund row.
        public let currency: String
        /// "PENDING" | "SUCCEEDED" | "FAILED" | "CANCELED".
        public let status: String
        /// "AUTO_CANCELLATION" | "DISCRETIONARY".
        public let trigger: String
        public let reason: String?
        /// "CLIENT" | "PRO" | "ADMIN" — nil for a system-initiated refund.
        public let initiatedByRole: String?
        public let failureMessage: String?
        public let createdAt: String
    }

    public struct Summary: Decodable, Sendable {
        public let capturedCents: Int
        public let refundedCents: Int
        public let pendingRefundCents: Int
        public let netCents: Int
    }

    public struct Capabilities: Decodable, Sendable {
        public let canRefund: Bool
        public let refundableRemainingCents: Int
        public let canWaiveNoShowFee: Bool
    }
}
