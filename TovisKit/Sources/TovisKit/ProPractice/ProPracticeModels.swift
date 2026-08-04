import Foundation

/// A shot the pro took with the STANDALONE camera — the pro footer's centre
/// button when no session is live.
///
/// Deliberately not a session photo and not a portfolio asset: it has no
/// booking and no service, so nothing is owed on it and it appears in no
/// gallery. It becomes real media only when the pro attaches it (see
/// `ProPracticeService.attach`), which is when a service is actually known.
public struct ProPracticeShot: Identifiable, Decodable, Sendable, Equatable {
    public let id: String
    public let mediaType: MediaType
    public let caption: String?
    public let createdAt: String
    public let focalX: Double?
    public let focalY: Double?
    /// Non-nil once this shot has been attached to a booking or published as a
    /// look. The shot stays in the library either way — a "used" marker, not a
    /// tombstone.
    public let attachedMediaId: String?
    public let attachedAt: String?
    /// Short-lived signed URL to render from. Nil when signing failed.
    public let renderUrl: String?

    /// Whether this shot has already been promoted into real media.
    public var isAttached: Bool { attachedMediaId != nil }

    public init(
        id: String,
        mediaType: MediaType,
        caption: String?,
        createdAt: String,
        focalX: Double?,
        focalY: Double?,
        attachedMediaId: String?,
        attachedAt: String?,
        renderUrl: String?
    ) {
        self.id = id
        self.mediaType = mediaType
        self.caption = caption
        self.createdAt = createdAt
        self.focalX = focalX
        self.focalY = focalY
        self.attachedMediaId = attachedMediaId
        self.attachedAt = attachedAt
        self.renderUrl = renderUrl
    }
}

struct ProPracticeListResponse: Decodable, Sendable {
    let items: [ProPracticeShot]
}

struct ProPracticeCreateResponse: Decodable, Sendable {
    let shot: ProPracticeShot
}

/// `POST /pro/practice` — the confirm body. The storage pointer is NOT here on
/// purpose: the server reads it back from the upload session it minted, so a
/// client can never assert someone else's object.
struct ProPracticeConfirmRequest: Encodable, Sendable {
    let uploadSessionId: String
    let mediaType: String
    let caption: String?
    let focalX: Double?
    let focalY: Double?
}

/// Where an attach-later sends the shot.
public enum ProPracticeAttachTarget: Sendable, Equatable {
    /// Onto one of the pro's own bookings, as private session media.
    ///
    /// ⚠️ The server's booking write boundary refuses media on a COMPLETED or
    /// cancelled booking — so this reaches a client's ACTIVE work, not their
    /// history. The refusal comes back as the boundary's own sentence.
    case booking(bookingId: String)
    /// Published (or drafted) as a public look. `serviceIds` must be non-empty —
    /// a look always routes to "book this".
    case look(serviceIds: [String], primaryServiceId: String?, publish: Bool)
}

struct ProPracticeAttachRequest: Encodable, Sendable {
    let target: String
    let bookingId: String?
    let serviceIds: [String]?
    let primaryServiceId: String?
    let publish: Bool?
    let caption: String?

    init(target: ProPracticeAttachTarget, caption: String?) {
        switch target {
        case let .booking(bookingId):
            self.target = "BOOKING"
            self.bookingId = bookingId
            self.serviceIds = nil
            self.primaryServiceId = nil
            self.publish = nil
        case let .look(serviceIds, primaryServiceId, publish):
            self.target = "LOOK"
            self.bookingId = nil
            self.serviceIds = serviceIds
            self.primaryServiceId = primaryServiceId
            self.publish = publish
        }
        self.caption = caption
    }
}

/// `POST /pro/practice/{id}/attach` → the shot, re-read with its `attachedMediaId`
/// populated. The created media itself is modeled only as far as the library
/// needs it (the shot's own marker is what the grid re-renders from).
public struct ProPracticeAttachResult: Decodable, Sendable, Equatable {
    public let target: String
    public let shot: ProPracticeShot
}
