import Foundation

// Wire model for the PRO booking detail — GET /api/v1/pro/bookings/[id].
// Mirrors the inline shape built in `app/api/v1/pro/bookings/[id]/route.ts`
// (there is NO typed backend DTO yet — see docs/PRO-BACKEND-CONTRACTS.md; this
// fixture is decode-only until a `ProBookingDetailDTO` companion PR lands).
// Money fields are decimal strings ("50.00"); instants are ISO-8601 UTC.

/// `GET /api/v1/pro/bookings/[id]` → `{ ok, booking }` (envelope's `ok` ignored).
public struct ProBookingDetailResponse: Decodable, Sendable {
    public let booking: ProBookingDetail
}

public struct ProBookingDetail: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let scheduledFor: String
    public let endsAt: String
    public let locationId: String?
    public let locationType: String
    public let locationAddressSnapshot: String?
    public let locationLatSnapshot: Double?
    public let locationLngSnapshot: Double?
    public let bufferMinutes: Int
    public let durationMinutes: Int
    public let totalDurationMinutes: Int
    public let subtotalSnapshot: String?
    public let client: ProBookingClient
    public let timeZone: String?
    public let timeZoneSource: String?
    public let serviceItems: [ProBookingServiceItem]

    // Expanded fields (tovis-app PR #432). All optional so older fixtures decode.
    /// Session lifecycle (drives the Timing timeline + the action set).
    public let sessionStep: String?
    public let startedAt: String?
    public let finishedAt: String?
    // Payment breakdown.
    public let totalAmount: String?
    public let serviceSubtotalSnapshot: String?
    public let taxAmount: String?
    public let tipAmount: String?
    public let discountAmount: String?
    public let paymentCollectedAt: String?
    public let selectedPaymentMethod: String?
    public let stripePaymentStatus: String?
    public let stripeAmountTotal: Int?
    public let stripeCurrency: String?
    /// Checkout lifecycle (tovis-app §10 follow-up). AWAITING_CONFIRMATION means
    /// the client attested an off-platform payment and the pro must confirm
    /// receipt — drives the booking-detail "Confirm payment received" action.
    /// Optional so older fixtures / pre-deploy responses still decode.
    public let checkoutStatus: String?
    /// When this booking is a rebook, the id of the appointment it was booked off
    /// of (the RebookChain source). Optional; present on the client + pro reads.
    public let rebookOfBookingId: String?
    /// Aftercare snapshot card (null until a summary exists).
    public let aftercareSummary: ProAftercareSnapshot?

    /// The displayed total — totalAmount, else the subtotal snapshot, else 0.
    public var totalLabel: String { totalAmount ?? subtotalSnapshot ?? "0.00" }

    /// Collected (web: paymentCollectedAt set, or Stripe SUCCEEDED).
    public var isPaid: Bool {
        paymentCollectedAt != nil || stripePaymentStatus?.uppercased() == "SUCCEEDED"
    }

    /// Refund is offered while a captured Stripe payment exists (web canRefund).
    public var canRefund: Bool { stripePaymentStatus?.uppercased() == "SUCCEEDED" }

    /// The client attested an off-platform payment; the pro must confirm receipt to
    /// close it out (AWAITING_CONFIRMATION → PAID). Drives the booking-detail
    /// "Confirm payment received" action, mirroring the session wrap-up control.
    public var isAwaitingPaymentConfirmation: Bool {
        checkoutStatus?.uppercased() == "AWAITING_CONFIRMATION"
    }

    /// Base service item (the one whose name titles the booking), else the first.
    public var baseItem: ProBookingServiceItem? {
        serviceItems.first(where: { !$0.isAddOn }) ?? serviceItems.first
    }

    /// The booking title — the base service's name (matches the web detail header).
    public var title: String {
        baseItem?.serviceName ?? "Appointment"
    }

    private var statusUpper: String { status.uppercased() }

    public var isPending: Bool { statusUpper == "PENDING" }
    public var isAccepted: Bool { statusUpper == "ACCEPTED" }
    public var isInProgress: Bool { statusUpper == "IN_PROGRESS" }

    /// Cancellable while it's still actionable (PENDING or ACCEPTED), mirroring the
    /// backend's `allowedStatuses` on the cancel route.
    public var isCancellable: Bool { isPending || isAccepted }

    /// Terminal states can't be managed.
    public var isTerminal: Bool {
        ["CANCELLED", "COMPLETED", "NO_SHOW", "DECLINED", "EXPIRED"].contains(statusUpper)
    }
}

public struct ProAftercareSnapshot: Decodable, Sendable {
    public let notes: String?
    public let sentToClientAt: String?
    public let draftSavedAt: String?
    public let version: Int?

    public var isSent: Bool { sentToClientAt != nil }
    public var isDraft: Bool { !isSent && draftSavedAt != nil }
}

public struct ProBookingClient: Decodable, Sendable {
    public let fullName: String
    public let email: String?
    public let phone: String?
}

public struct ProBookingServiceItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let serviceId: String
    public let offeringId: String?
    public let itemType: String
    public let serviceName: String
    public let priceSnapshot: String?
    public let durationMinutesSnapshot: Int
    public let sortOrder: Int

    public var isAddOn: Bool { itemType.uppercased() == "ADD_ON" }
}
