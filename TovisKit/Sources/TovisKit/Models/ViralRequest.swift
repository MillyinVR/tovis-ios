import Foundation

/// A viral-look request the signed-in client just submitted —
/// `POST /api/v1/viral-service-requests` (201).
///
/// The server returns its full row (status, moderation, admin notes, timestamps…);
/// this models only the part the app has a use for. The submitted row lands as
/// `REQUESTED` and reappears on the next `GET /client/home` under `viralPending`,
/// which is what the Viral Looks band's "Your request" pipeline renders — so the
/// caller refreshes home rather than trying to splice this row into the band.
public struct ViralRequestSubmission: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// `REQUESTED` on creation. Deliberately a String, never a Swift enum: an
    /// unknown future status must not throw and make a request the server
    /// actually recorded look like a failure to the person who submitted it.
    public let status: String?

    public init(id: String, name: String, status: String?) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// The create envelope — `{ ok: true, request: { … } }`.
struct ViralRequestCreateResponse: Decodable, Sendable {
    let request: ViralRequestSubmission
}

/// A photo or video the submitter picked to send with their look.
///
/// Lives in TovisKit, not the view, so `swift test` can reach the cap and the
/// content-type rules — the same reason `ViralLookDraft` does.
public struct ViralLookAttachment: Sendable, Equatable {
    /// The signing route's own cap (`UPLOAD_MAX_BYTES`, 30MB). Checked at pick
    /// time so the person learns before the upload, not after a 400.
    public static let maxBytes = 30 * 1024 * 1024
    public static let maxLabel = "30MB"

    public let data: Data
    /// Sent as-is and validated server-side: `image/*` or `video/*` only.
    public let contentType: String
    /// Extension for the stored object's name. The server sanitizes it again.
    public let fileExtension: String

    public init(data: Data, contentType: String, fileExtension: String) {
        self.data = data
        self.contentType = contentType
        self.fileExtension = fileExtension
    }

    public var isVideo: Bool { contentType.hasPrefix("video/") }
    public var isOverCap: Bool { data.count > Self.maxBytes }
}

/// `POST /api/v1/viral-service-requests/upload` → where to PUT the submitter's
/// file.
///
/// Its own type rather than `MediaUploadInit`/`PublicUploadInit`: this route mints
/// no UploadSession, and `publicUrl` is REQUIRED here — it is the value the attach
/// PATCH persists, so a response without one must fail to decode rather than
/// quietly upload bytes nothing will ever point at.
struct ViralRequestUploadInit: Decodable, Sendable {
    let bucket: String
    let path: String
    let token: String
    let publicUrl: String
}

/// The upload-signing payload. `size` lets the server refuse an over-cap file
/// before any bytes move.
struct ViralRequestUploadInitRequest: Encodable, Sendable {
    let requestId: String
    let fileName: String
    let contentType: String
    let size: Int
}

/// `PATCH /api/v1/viral-service-requests/{id}` — records an upload on the
/// submitter's own request.
///
/// 🔴 This is EVIDENCE for the review queue, not a published picture: only an
/// admin sets the cover a look is shown by. The server accepts nothing but a URL
/// it minted for this very request.
struct ViralRequestAttachMediaRequest: Encodable, Sendable {
    let mediaUrl: String
}

/// The create payload. `sourceUrl` is optional and, when nil, is OMITTED from the
/// body rather than sent as `null` or `""` — the same shape the web form puts on
/// the wire (`sourceUrl: trimmedSourceUrl || undefined`). Swift's synthesized
/// `Encodable` uses `encodeIfPresent` for optionals, which is exactly that.
struct ViralRequestCreateRequest: Encodable, Sendable {
    let name: String
    let sourceUrl: String?
}

/// The client-side draft behind the submit form, and the validation web's
/// `SubmitViralLookForm` applies before it will POST.
///
/// This lives in TovisKit, not in the view, so `swift test` can reach it — the
/// house rule the round-3 audit raised against `statusDisplayLabel` and friends.
///
/// Web's rules, mirrored exactly:
/// - the name is required (web refuses with its own copy before fetching);
/// - the name is capped at 160 characters — web gets this free from the input's
///   `maxLength={160}`, which iOS has no equivalent for, so `clampedName` does it;
/// - `sourceUrl` is optional and free-form. It is NOT validated here on purpose:
///   the server owns URL validation and answers with user-readable copy
///   ("sourceUrl must be a valid URL." / "…must use http or https."), so a
///   client-side guess would only drift from it.
public struct ViralLookDraft: Sendable, Equatable {
    /// Matches the web input's `maxLength={160}` and the server's own cap
    /// ("Viral request name must be 160 characters or fewer.").
    public static let nameLimit = 160

    public var name: String
    public var sourceUrl: String

    public init(name: String = "", sourceUrl: String = "") {
        self.name = name
        self.sourceUrl = sourceUrl
    }

    /// The name trimmed to the server's limit — applied as the field is typed so
    /// the person sees the cap instead of discovering it in a 400.
    public static func clampedName(_ value: String) -> String {
        value.count > nameLimit ? String(value.prefix(nameLimit)) : value
    }

    /// The trimmed name, or nil when blank — the one field the server requires.
    public var trimmedName: String? { name.trimmedOrNil }

    /// The trimmed source URL, or nil when blank. Nil means "omit the key".
    public var trimmedSourceUrl: String? { sourceUrl.trimmedOrNil }

    /// Web's gate: a non-blank name is the only precondition for POSTing.
    public var canSubmit: Bool { trimmedName != nil }
}
