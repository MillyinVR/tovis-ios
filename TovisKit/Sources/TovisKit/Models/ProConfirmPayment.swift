import Foundation

// Wire model for the PRO confirm-payment action —
// POST /api/v1/pro/bookings/[id]/checkout/confirm-payment.
// Mirrors the inline `ConfirmPaymentSuccessBody` built in
// `app/api/v1/pro/bookings/[id]/checkout/confirm-payment/route.ts` (there is NO
// typed backend DTO — decode-only, so no contract-schema entry).
//
// The pro confirms receipt of an off-platform payment the client attested to
// (checkoutStatus AWAITING_CONFIRMATION → PAID). Confirming also auto-approves any
// aftercare-sourced next appointment that was coupled to this payment
// (PENDING → ACCEPTED); their ids come back in `meta.approvedNextAppointmentBookingIds`.

/// `POST …/checkout/confirm-payment` → `{ ok, booking, meta }` (envelope's `ok` ignored).
public struct ProConfirmPaymentResponse: Decodable, Sendable {
    public let booking: ProConfirmPaymentBooking
    public let meta: ProConfirmPaymentMeta
}

public struct ProConfirmPaymentBooking: Decodable, Sendable {
    public let id: String
    public let checkoutStatus: String
    public let paymentCollectedAt: String?
    public let status: String
    public let sessionStep: String?
}

public struct ProConfirmPaymentMeta: Decodable, Sendable {
    public let mutated: Bool
    public let noOp: Bool
    public let completedBooking: Bool
    /// Aftercare-sourced next appointments approved (PENDING → ACCEPTED) because
    /// they were coupled to this off-platform payment.
    public let approvedNextAppointmentBookingIds: [String]

    /// Whether confirming this payment also approved a coupled next appointment.
    public var approvedANextAppointment: Bool { !approvedNextAppointmentBookingIds.isEmpty }
}
