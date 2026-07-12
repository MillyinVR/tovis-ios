import Foundation

/// GET /api/v1/public/claim/{token} — public read of a client claim link's
/// booking context (the web /claim/[token] page is RSC-only, so native reads it
/// here). Mirrors `ClaimPublicViewResponseDTO` in lib/dto/claimPublic.ts.
///
/// `state` is one of "ready" | "revoked" | "already_claimed". A 404 (missing /
/// malformed token) is surfaced by `ClaimService.claimContext` as `nil`.
public struct ClaimContextResponse: Codable, Sendable {
    public let state: String
    /// The name/contact the pro put on file for this claim (invite snapshot).
    public let invitedName: String?
    public let invitedEmail: String?
    public let invitedPhone: String?
    /// Pro's public display name (resolved from the booking OR the invite's own
    /// pro); nil for a pro-less claim (a cold self-serve orphan).
    public let professionalName: String?
    /// Booking context, or nil for a booking-less claim (a directory-created /
    /// migration-imported client with no appointment).
    public let booking: ClaimContextBooking?

    public init(
        state: String,
        invitedName: String?,
        invitedEmail: String?,
        invitedPhone: String?,
        professionalName: String?,
        booking: ClaimContextBooking?
    ) {
        self.state = state
        self.invitedName = invitedName
        self.invitedEmail = invitedEmail
        self.invitedPhone = invitedPhone
        self.professionalName = professionalName
        self.booking = booking
    }
}

public struct ClaimContextBooking: Codable, Sendable {
    public let serviceName: String?
    /// Pro's public display name (respects nameDisplay); never null.
    public let professionalName: String
    /// ISO-8601 instant, or nil when the booking has no scheduled time.
    public let scheduledFor: String?
    /// IANA timezone the appointment should render in; the client formats it.
    public let timeZone: String
    public let locationLabel: String?

    public init(
        serviceName: String?,
        professionalName: String,
        scheduledFor: String?,
        timeZone: String,
        locationLabel: String?
    ) {
        self.serviceName = serviceName
        self.professionalName = professionalName
        self.scheduledFor = scheduledFor
        self.timeZone = timeZone
        self.locationLabel = locationLabel
    }
}

/// Well-known `ClaimContextResponse.state` values.
public enum ClaimContextState {
    public static let ready = "ready"
    public static let revoked = "revoked"
    public static let alreadyClaimed = "already_claimed"
}
