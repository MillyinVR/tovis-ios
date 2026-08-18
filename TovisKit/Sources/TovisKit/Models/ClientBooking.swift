import Foundation

// Wire models for the client bookings screen — GET /api/v1/client/bookings.
// Mirrors `ClientBookingDTO` + the bucketed response in lib/dto/clientBooking.ts
// and app/api/v1/client/bookings/route.ts. As elsewhere, only the rendered
// subset is modeled; nullable fields are Swift optionals and unknown keys are
// ignored.

/// Envelope for `GET /api/v1/client/bookings` → `{ ok, buckets, meta }`.
struct ClientBookingsResponse: Decodable, Sendable {
    let buckets: ClientBookingBuckets
}

public struct ClientBookingBuckets: Decodable, Sendable {
    public let upcoming: [ClientBooking]
    public let pending: [ClientBooking]
    public let prebooked: [ClientBooking]
    public let past: [ClientBooking]
    public let waitlist: [BookingWaitlistEntry]
}

// MARK: - Pro name display (honors the pro's nameDisplay toggle)

/// Matches the `ProNameDisplay` Prisma enum. Unknown values fall back so the app
/// never fails to decode if the backend adds a mode.
public enum ProNameDisplay: String, Decodable, Sendable {
    case businessName = "BUSINESS_NAME"
    case realName = "REAL_NAME"
    case handle = "HANDLE"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProNameDisplay(rawValue: raw) ?? .unknown
    }
}

/// The richer professional reference carried by bookings (has the real-name
/// fields + the display toggle, unlike the leaner `HomeProfessional`).
public struct BookingProfessional: Decodable, Sendable, Identifiable, ProPublicNameSource {
    public let id: String
    public let businessName: String?
    public let firstName: String?
    public let lastName: String?
    public let handle: String?
    public let nameDisplay: ProNameDisplay?
    public let location: String?
    public let timeZone: String?

    /// The pro's public name — "Your pro" when they have no usable name token
    /// (this is a booking the viewer owns, so the possessive reads right).
    public var displayName: String { publicDisplayName(fallback: "Your pro") }
}

// MARK: - Booking

public struct ClientBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String?
    public let source: String?
    /// When this booking is a rebook, the id of the appointment it was booked off
    /// of (the RebookChain source). Optional so pre-field responses still decode.
    public let rebookOfBookingId: String?
    public let sessionStep: String?

    public let scheduledFor: String
    public let totalDurationMinutes: Int
    public let bufferMinutes: Int

    public let timeZone: String?
    public let locationType: String?
    /// Human label for the place — an address, a salon name, or a city. Display
    /// only: it is NOT safe to hand a maps app, which is what `locationAddress`
    /// is for.
    public let locationLabel: String?
    /// The appointment's actual street address — the pro's location for SALON,
    /// the CLIENT's for MOBILE. Optional so pre-field responses still decode.
    public let locationAddress: String?
    /// Coordinates for that address, when the booking's snapshot captured them.
    public let locationLat: Double?
    public let locationLng: Double?

    public let professional: BookingProfessional?
    public let bookedLocation: BookingLocation?

    public let display: ClientBookingDisplay
    public let checkout: ClientBookingCheckout
    public let items: [ClientBookingItem]
    public let productSales: [ClientBookingProductSale]
    public let consultation: ClientBookingConsultation?

    public let hasUnreadAftercare: Bool
    public let hasPendingConsultationApproval: Bool
    /// The pro proposed a next appointment the client hasn't confirmed/declined yet.
    public let hasPendingRebookConfirmation: Bool
    /// The pro-proposed next-appointment instant (ISO) when a confirmation is pending.
    public let rebookProposedFor: String?
    /// Whether the client has allowed the pro to feature this session's photos/video
    /// publicly (portfolio/Looks). Toggle via POST /client/bookings/{id}/media-consent.
    public let mediaUseConsent: Bool

    /// The no-show / late-cancel fee policy the client AGREED to at booking (M15),
    /// formatted for display, or nil if none applied. This is what they agreed to
    /// (the booking's own snapshot), not the pro's possibly-since-edited settings.
    /// Optional so pre-field responses still decode.
    public let cancellationPolicy: String?

    /// The pro's accepted payment methods (with off-platform handles) + tip config
    /// + payment note for this booking's native checkout. Optional so pre-field
    /// responses still decode; nil is treated as "no options loaded" by the checkout.
    public let paymentOptions: ClientBookingPaymentOptions?

    /// "Before you go" — the pro's checklist, their note, this client's ticks and
    /// the countdown. Optional and ABSENT unless the server loaded it, which it
    /// only does for a booking that can still be prepared for; nil therefore means
    /// "nothing to prep here", not "failed to load".
    public let prep: ClientBookingPrep?

    /// Boards this client has handed to the pro FOR THIS BOOKING (a scoped grant —
    /// `Board.visibility` is never touched, so a private board shared here stays
    /// private everywhere else). nil means the payload can't say; [] means nothing
    /// is shared.
    public let sharedBoardIds: [String]?

    /// The client's own view of K11's confirmation state — the SAME badge, from
    /// the same helper, that the pro sees.
    ///
    /// 🔴 Its PRESENCE is the cue to offer the in-app answer: web suppresses the
    /// field outright while `ENABLE_CLIENT_CONFIRMATION_LOOP` is off, even for a
    /// row carrying stamps from an earlier trial, because the answer route
    /// refuses then and a control the server will reject must not be drawn. So
    /// the app draws the card exactly when this is present and renderable, and
    /// never infers "they must have been asked" from anything else.
    public let clientConfirmation: ProClientConfirmation?

    /// The confirmation question this booking is waiting on, or nil when there
    /// is nothing to answer (nobody asked, the loop is off, or the state is one
    /// this build doesn't know).
    public var clientConfirmationDisplay: ProClientConfirmation.Display? {
        guard let display = clientConfirmation?.display, display.significant else { return nil }
        return display
    }

    /// True when this is an aftercare-sourced next appointment still PENDING because
    /// its approval is coupled to the previous appointment's off-platform payment —
    /// the pro approves it by confirming that payment (§10). Drives the "pending —
    /// your pro will confirm after payment" label on the booking detail.
    public var isCoupledRebookAwaitingPaymentConfirmation: Bool {
        status?.uppercased() == "PENDING"
            && source?.uppercased() == "AFTERCARE"
            && rebookOfBookingId != nil
    }
}

// MARK: - Appointment prep ("Before you go")

/// One row of the pro's prep checklist. Ticking is a per-booking write:
/// POST /client/bookings/{id}/prep { prepItemId, checked }.
public struct ClientBookingPrepItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let text: String
}

/// How the countdown hero reads. Unknown values fall back so a new tone on the
/// backend can never fail a whole bookings decode.
public enum PrepCountdownTone: String, Decodable, Sendable {
    /// Today or tomorrow — the emphasised hero.
    case urgent
    /// Inside a fortnight — the standard hero.
    case near
    /// Beyond a fortnight — one quiet line, and the board card is promoted above
    /// the checklist (six weeks out, sending your looks is the useful thing).
    case far
    /// The appointment has already happened.
    case past
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PrepCountdownTone(rawValue: raw) ?? .unknown
    }
}

/// "Tomorrow" / "In 3 days" / "In 6 weeks".
///
/// 🔴 Rendered from the SERVER's `label`, never recomputed here. The rule is
/// calendar days in the APPOINTMENT's zone, not 24h blocks — 11pm Monday to 9am
/// Wednesday is "in 2 days", which a naive hours/24 calls "tomorrow". One
/// implementation, on the backend, is the whole point.
public struct ClientBookingPrepCountdown: Decodable, Sendable {
    public let days: Int
    public let tone: PrepCountdownTone
    public let label: String
}

/// The client's prep bundle for one booking. Fields past `items` are defensively
/// optional: a decode failure in here would fail the whole booking, and then the
/// whole bucket list, over a supplementary section.
public struct ClientBookingPrep: Decodable, Sendable {
    public let items: [ClientBookingPrepItem]
    /// Ids of `items` this client has already ticked.
    public let checkedItemIds: [String]
    public let note: String?
    /// Whether a tick would be ACCEPTED right now — the server's own answer, from
    /// the same predicate its write path re-checks. Defaults to false when absent
    /// so a control the server would refuse is never drawn.
    public let writable: Bool
    public let countdown: ClientBookingPrepCountdown?

    private enum CodingKeys: String, CodingKey {
        case items, checkedItemIds, note, writable, countdown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([ClientBookingPrepItem].self, forKey: .items) ?? []
        checkedItemIds = try c.decodeIfPresent([String].self, forKey: .checkedItemIds) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        writable = try c.decodeIfPresent(Bool.self, forKey: .writable) ?? false
        countdown = try c.decodeIfPresent(ClientBookingPrepCountdown.self, forKey: .countdown)
    }

    /// Something for the client to look at — rows, a note, or a countdown worth
    /// showing. An empty bundle still renders the "nothing to prep" state, so the
    /// caller gates on the booking being preparable, not on this.
    public var hasContent: Bool {
        !items.isEmpty || (note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
}

public struct BookingLocation: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let formattedAddress: String?
    public let city: String?
    public let state: String?
    public let timeZone: String?
}

public struct ClientBookingDisplay: Decodable, Sendable {
    public let title: String
    public let baseName: String
    public let addOnNames: [String]
    public let addOnCount: Int
}

public struct ClientBookingCheckout: Decodable, Sendable {
    public let subtotalSnapshot: String?
    public let serviceSubtotalSnapshot: String?
    public let productSubtotalSnapshot: String?
    public let tipAmount: String?
    public let taxAmount: String?
    public let discountAmount: String?
    public let totalAmount: String?
    public let checkoutStatus: String?
    public let selectedPaymentMethod: String?
    public let paymentAuthorizedAt: String?
    public let paymentCollectedAt: String?
    /// Discovery-deposit lifecycle: NONE · PENDING · PAID · REFUNDED · FAILED.
    /// A deposit is owed-and-unpaid exactly when this is "PENDING".
    public let depositStatus: String?
    /// Formatted deposit amount (e.g. "$25"), or null when no deposit applies.
    public let depositAmount: String?
    /// Final-bill refund/dispute truth (server-computed). `paymentCollectedAt` /
    /// `checkoutStatus` are monotonic and never reverse on a refund/dispute, so a
    /// card must consult these before showing a green "paid" (M11 display-truth).
    /// Optional so older responses/fixtures still decode (default false / 0).
    public let paymentDisputed: Bool?
    public let paymentRefundedCents: Int?
    public let paymentFullyRefunded: Bool?
    /// The discovery deposit charge is under (or lost) a Stripe dispute.
    public let depositDisputed: Bool?
    /// Cumulative cents already refunded against the DEPOSIT charge (0 when
    /// none). A PARTIAL deposit refund leaves `depositStatus` on PAID and only
    /// accumulates here, so the status alone over-states what the deposit still
    /// covers — `CheckoutMoney.depositCreditApplied` nets this out exactly as
    /// web's `deriveNetDepositHeldCents` does. Optional so older responses and
    /// fixtures still decode (absent → 0, i.e. nothing refunded).
    public let depositRefundedCents: Int?
}

// MARK: - Client checkout payment options

/// One accepted payment method for the client checkout. `handle` carries the
/// pro's off-platform handle (Venmo @, Zelle/Apple Cash contact, PayPal) for the
/// deep-link/copy affordance; nil for on-platform / handle-free methods. Mirrors
/// `ClientBookingPaymentMethodDTO`.
public struct ClientBookingPaymentMethod: Decodable, Sendable, Identifiable {
    /// Lowercase method key: cash · card_on_file · tap_to_pay · venmo · zelle ·
    /// apple_cash · paypal · apple_pay · stripe_card.
    public let key: String
    public let label: String
    public let handle: String?

    public var id: String { key }

    public init(key: String, label: String, handle: String?) {
        self.key = key
        self.label = label
        self.handle = handle
    }
}

/// The pro's accepted methods + tip config + payment note for a committed
/// booking's checkout. Mirrors `ClientBookingPaymentOptionsDTO`. Handles are
/// gated to the client's own booking.
public struct ClientBookingPaymentOptions: Decodable, Sendable {
    public let methods: [ClientBookingPaymentMethod]
    public let tipsEnabled: Bool
    public let allowCustomTip: Bool
    /// Whole-percent tip presets on the services subtotal; the client prepends 0%.
    public let tipSuggestions: [Int]
    public let paymentNote: String?
    /// "AT_BOOKING" | "AFTER_SERVICE" (or nil when the pro has no settings row).
    public let collectPaymentAt: String?

    public init(
        methods: [ClientBookingPaymentMethod],
        tipsEnabled: Bool,
        allowCustomTip: Bool,
        tipSuggestions: [Int],
        paymentNote: String?,
        collectPaymentAt: String?
    ) {
        self.methods = methods
        self.tipsEnabled = tipsEnabled
        self.allowCustomTip = allowCustomTip
        self.tipSuggestions = tipSuggestions
        self.paymentNote = paymentNote
        self.collectPaymentAt = collectPaymentAt
    }
}

public struct ClientBookingItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let type: String  // "BASE" | "ADD_ON"
    public let serviceId: String
    public let name: String
    public let price: String
    public let durationMinutes: Int
    public let parentItemId: String?
    public let sortOrder: Int

    public var isAddOn: Bool { type.uppercased() == "ADD_ON" }
}

public struct ClientBookingProductSale: Decodable, Sendable, Identifiable {
    public let id: String
    public let productId: String?
    public let name: String
    public let unitPrice: String
    public let quantity: Int
    public let lineTotal: String
}

public struct ClientBookingConsultation: Decodable, Sendable {
    public let consultationNotes: String?
    public let consultationPrice: String?
    public let consultationConfirmedAt: String?
    public let approvalStatus: String?
    public let approvalNotes: String?
    public let proposedTotal: String?
    public let approvedAt: String?
    public let rejectedAt: String?
    /// The proposal's line items, decoded from the free-form `proposedServicesJson`
    /// blob. Nil when the blob is absent, null, or not the expected shape.
    public let proposedServices: ClientBookingProposedServices?

    private enum CodingKeys: String, CodingKey {
        case consultationNotes, consultationPrice, consultationConfirmedAt
        case approvalStatus, approvalNotes, proposedTotal, approvedAt, rejectedAt
        case proposedServicesJson
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        consultationNotes = try c.decodeIfPresent(String.self, forKey: .consultationNotes)
        consultationPrice = try c.decodeIfPresent(String.self, forKey: .consultationPrice)
        consultationConfirmedAt = try c.decodeIfPresent(String.self, forKey: .consultationConfirmedAt)
        approvalStatus = try c.decodeIfPresent(String.self, forKey: .approvalStatus)
        approvalNotes = try c.decodeIfPresent(String.self, forKey: .approvalNotes)
        proposedTotal = try c.decodeIfPresent(String.self, forKey: .proposedTotal)
        approvedAt = try c.decodeIfPresent(String.self, forKey: .approvedAt)
        rejectedAt = try c.decodeIfPresent(String.self, forKey: .rejectedAt)
        // `proposedServicesJson` is an untyped Json column on the backend, so a row
        // that isn't `{ items: [...] }` must degrade to "no line items" rather than
        // fail the whole booking's decode (mirrors the web card's `asItems`).
        proposedServices = try? c.decodeIfPresent(
            ClientBookingProposedServices.self, forKey: .proposedServicesJson
        )
    }
}

/// The `proposedServicesJson` blob a pro's consultation proposal is stored as —
/// written by `buildProposalJson` in the web `consultation-proposal` route as
/// `{ currency, items: [...] }`.
public struct ClientBookingProposedServices: Decodable, Sendable {
    public let currency: String?
    public let items: [ClientBookingProposedServiceItem]
}

/// One proposed line item. Only the fields the client is shown are modeled; the
/// blob also carries the ids/duration/sort metadata the pro's form round-trips.
public struct ClientBookingProposedServiceItem: Decodable, Sendable {
    public let label: String?
    public let categoryName: String?
    /// Decimal-dollars string, e.g. "45.00" — feed it to `Wire.money`.
    public let price: String?

    private enum CodingKeys: String, CodingKey {
        case label, categoryName, price
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        categoryName = try? c.decodeIfPresent(String.self, forKey: .categoryName)
        // The backend always writes `price` as a decimal string, but the column is
        // untyped — accept a bare number too, as `ProReferralRewardSettings` does.
        if let text = try? c.decodeIfPresent(String.self, forKey: .price) {
            price = text
        } else if let number = try? c.decodeIfPresent(Double.self, forKey: .price) {
            price = String(number)
        } else {
            price = nil
        }
    }
}

// MARK: - Waitlist (the bookings endpoint returns raw waitlist rows)

public struct BookingWaitlistEntry: Decodable, Sendable, Identifiable {
    public let id: String
    public let createdAt: String
    public let status: String
    public let preferenceType: String
    public let notes: String?
    public let service: HomeServiceRef?
    public let professional: BookingProfessional?
}

// MARK: - Consultation decision

/// The client's response to a pro's proposed consultation plan.
public enum ConsultationDecision: Sendable {
    case approve
    case reject

    var wire: String { self == .approve ? "APPROVE" : "REJECT" }
}

/// POST /api/v1/client/bookings/{id}/consultation — request body.
struct ConsultationDecisionRequest: Encodable, Sendable {
    let action: String  // "APPROVE" | "REJECT"
}

// MARK: - Rebook confirmation (POST /api/v1/client/bookings/{id}/aftercare-rebook)

struct RebookDecisionRequest: Encodable, Sendable {
    let action: String  // "CONFIRM" | "DECLINE"
}

/// CONFIRM returns the newly created booking; DECLINE returns just `{ ok }`.
struct RebookDecisionResponse: Decodable, Sendable {
    let booking: RebookedBooking?
}

public struct RebookedBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let scheduledFor: String
}

// MARK: - Prep tick (POST /api/v1/client/bookings/{id}/prep)

struct PrepCheckRequest: Encodable, Sendable {
    let prepItemId: String
    let checked: Bool
}

/// The server's authoritative tick state after the write — adopt this rather
/// than assuming the tap landed, since the route can still refuse.
struct PrepCheckResponse: Decodable, Sendable {
    let checkedItemIds: [String]
}

// MARK: - Board hand-off (POST /api/v1/client/bookings/{id}/board)

struct BookingBoardShareRequest: Encodable, Sendable {
    let boardId: String
    let shared: Bool
}

struct BookingBoardShareResponse: Decodable, Sendable {
    let sharedBoardIds: [String]
}

// MARK: - Media-use consent (POST /api/v1/client/bookings/{id}/media-consent)

struct MediaConsentRequest: Encodable, Sendable {
    let granted: Bool
}

struct MediaConsentResponse: Decodable, Sendable {
    let mediaUseConsent: Bool
}
