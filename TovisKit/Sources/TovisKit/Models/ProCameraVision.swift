import Foundation

// Wire models for the Claude-vision camera endpoints (tovis-app PR #454):
// POST /api/v1/pro/camera/look-brief + /api/v1/pro/camera/set-critique.
// The server proxies Claude (the Anthropic key never ships in the app);
// images are analyzed in-flight and never stored. Both calls are consent-
// gated in the UI — a photo leaves the device ONLY through these requests.

/// A downscaled image inlined in a request body (base64 JPEG, ≤ ~1 MB —
/// unlike session media, which always goes presign→PUT→confirm, these are
/// transient analysis payloads that never enter the media pipeline).
public struct ProCameraVisionImage: Encodable, Sendable {
    public let base64: String
    /// "image/jpeg" | "image/png" | "image/webp".
    public let mediaType: String

    public init(base64: String, mediaType: String = "image/jpeg") {
        self.base64 = base64
        self.mediaType = mediaType
    }
}

// MARK: - Look brief (Match a look, AI-enhanced)

/// POST /pro/camera/look-brief request.
public struct ProLookBriefRequest: Encodable, Sendable {
    public let image: ProCameraVisionImage
    /// The booking's base service name, for context.
    public let serviceName: String?
    /// What the on-device analyzer already measured (so Claude adds to the
    /// brief instead of repeating it).
    public let measuredSummary: String?

    public init(image: ProCameraVisionImage, serviceName: String?,
                measuredSummary: String?) {
        self.image = image
        self.serviceName = serviceName
        self.measuredSummary = measuredSummary
    }
}

/// `{ ok, brief }` → the enhanced reference brief. Inline shape; decode-only.
public struct ProLookBriefResponse: Decodable, Sendable {
    public let brief: ProLookBrief
}

public struct ProLookBrief: Decodable, Sendable {
    /// One-line read of the look's vibe.
    public let summary: String
    /// Extra pose rules in the SAME wire vocabulary as shot packs — reuses
    /// `ProShotPackPoseRule`, so unknown kinds decode fine and are dropped at
    /// guide-build time (forward-compat, like packs).
    public let poseRules: [ProShotPackPoseRule]
    /// Spoken/shown direction lines, in coaching order.
    public let directionLines: [String]
}

// MARK: - Set critique (wrap-up photographer's review)

/// POST /pro/camera/set-critique request.
public struct ProSetCritiqueRequest: Encodable, Sendable {
    public struct Photo: Encodable, Sendable {
        /// Media asset id — the server keys its notes back to this.
        public let id: String
        /// "BEFORE" | "AFTER".
        public let phase: String
        public let image: ProCameraVisionImage

        public init(id: String, phase: String, image: ProCameraVisionImage) {
            self.id = id
            self.phase = phase
            self.image = image
        }
    }

    public let photos: [Photo]
    public let serviceName: String?

    public init(photos: [Photo], serviceName: String?) {
        self.photos = photos
        self.serviceName = serviceName
    }
}

/// `{ ok, critique }` → the photographer's review. Inline shape; decode-only.
public struct ProSetCritiqueResponse: Decodable, Sendable {
    public let critique: ProSetCritique
}

public struct ProSetCritique: Decodable, Sendable {
    /// The set in a sentence or two: what to publish, what to reshoot.
    public let overall: String
    /// 2–4 things the set does well.
    public let strengths: [String]
    /// Per-photo notes, in the request's photo order (photos the reviewer
    /// returned nothing for are simply absent).
    public let photos: [ProSetCritiquePhotoNote]
}

public struct ProSetCritiquePhotoNote: Decodable, Sendable, Identifiable {
    /// The request's photo id (media asset id).
    public let id: String
    /// "portfolio" | "keep" | "retake" — a plain string so future verdicts
    /// decode on old builds (render unknowns neutrally).
    public let verdict: String
    public let note: String
    /// Concrete fix, present only when verdict is "retake".
    public let retakeTip: String?
}
