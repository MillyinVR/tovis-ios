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

/// POST /api/v1/pro/invites/{token}/accept — success body. `bookingId` is
/// TOP-level (the route's `jsonOk` spreads the object) and is null for a
/// booking-less claim, which is why it stays optional here.
public struct ClaimAcceptResponse: Codable, Sendable {
    public let bookingId: String?

    public init(bookingId: String?) {
        self.bookingId = bookingId
    }
}

/// The server's authoritative answer to an accept attempt. Mirrors
/// `AcceptClientClaimFromLinkResult` (lib/clients/clientClaim.ts), which the
/// route maps onto an HTTP status + a top-level `code`.
///
/// ⚠️ **Key on `code`, never on the status** — the status is ambiguous: 404 is
/// `NOT_FOUND` *or* `CLIENT_NOT_FOUND`, and 409 is `ALREADY_CLAIMED` *or*
/// `CLIENT_MISMATCH` *or* `CONFLICT`. Verified verbatim against the live route.
public enum ClaimAcceptOutcome: Equatable, Sendable {
    /// 200 — claimed. `bookingId` is nil for a booking-less claim.
    case claimed(bookingId: String?)
    /// 404 `NOT_FOUND` — the token no longer resolves.
    case notFound
    /// 410 `REVOKED`.
    case revoked
    /// 409 `ALREADY_CLAIMED`. Also what a REPLAYED successful claim returns.
    case alreadyClaimed
    /// 404 `CLIENT_NOT_FOUND` — the acting client identity vanished mid-request.
    case clientNotFound
    /// 409 `CLIENT_MISMATCH` — the link belongs to a different client identity.
    case clientMismatch
    /// 409 `CONFLICT` — a concurrent claim won the race; nothing was destroyed.
    case conflict
    /// 403 `WORKSPACE_MISMATCH` — a non-client session tried to claim.
    case notAClient
}

/// Who is looking at the claim screen. Native resolves this **locally** from
/// `SessionModel` (its `state` + `activeRole`); web resolves the same facts
/// server-side from the cookie session. Nothing here needs a wire field — see
/// `ClaimScreenState` for why the one fact native *can't* know locally
/// (whether the signed-in client owns this link) is answered by the accept POST.
public enum ClaimViewer: Equatable, Sendable {
    case signedOut
    /// Signed in, but the session is still `VERIFICATION` — it cannot claim yet.
    case needsVerification
    /// Signed in as a professional; a claim must come from a client account.
    case professional
    case client
}

/// What the native claim screen should render — the port of web's
/// `ClaimPageState` plus the sub-branches web nests inside its `ready` state.
///
/// ## Why native resolves this differently from web
/// Web computes `isMatchingClient` server-side (it has the cookie session *and*
/// `invite.client.id` in the same render) and can therefore show `client-mismatch`
/// **before** the viewer acts. Native reads the claim over the **public,
/// unauthenticated** `GET /public/claim/{token}`, which deliberately does not
/// expose the invite's client id — so native cannot pre-empt a mismatch and
/// instead lets the accept POST answer it. Same states, one extra tap; the POST
/// is the authoritative check on both platforms regardless.
public enum ClaimScreenState: Equatable, Sendable {
    /// Offer signup / sign-in — nobody is signed in to claim with.
    case signedOut
    /// Signed in, but not as a client.
    case notAClient
    /// Signed in as a client whose session still needs verifying.
    case needsVerification
    /// Signed in as a verified client — offer the in-app claim.
    case readyToClaim
    /// The claim succeeded. `bookingId` is nil for a booking-less claim.
    case claimed(bookingId: String?)
    case alreadyClaimed
    case revoked
    case clientMismatch
    case conflict
    case notFound

    /// Resolve what to render from the three inputs the screen has.
    ///
    /// Precedence: an `outcome`, when present, always wins — it is the server's
    /// direct answer to the action the viewer just took, and is strictly fresher
    /// than the context fetched before the tap. Otherwise the link's own state
    /// (revoked / already-claimed) short-circuits, exactly as web's page does,
    /// and only then does the viewer decide the branch.
    public static func resolve(
        contextState: String,
        viewer: ClaimViewer,
        outcome: ClaimAcceptOutcome? = nil
    ) -> ClaimScreenState {
        if let outcome {
            switch outcome {
            case let .claimed(bookingId): return .claimed(bookingId: bookingId)
            case .notFound: return .notFound
            case .revoked: return .revoked
            case .alreadyClaimed: return .alreadyClaimed
            case .clientMismatch: return .clientMismatch
            case .conflict: return .conflict
            case .notAClient: return .notAClient
            // The acting client identity vanished mid-request, so there is
            // nothing signed-in to claim with — web redirects this case to
            // signup, and `.signedOut` is the state that offers exactly that.
            case .clientNotFound: return .signedOut
            }
        }

        switch contextState {
        case ClaimContextState.revoked: return .revoked
        case ClaimContextState.alreadyClaimed: return .alreadyClaimed
        default: break
        }

        switch viewer {
        case .signedOut: return .signedOut
        case .needsVerification: return .needsVerification
        case .professional: return .notAClient
        case .client: return .readyToClaim
        }
    }
}
