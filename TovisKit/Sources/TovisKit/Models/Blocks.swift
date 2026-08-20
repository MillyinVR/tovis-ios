import Foundation

// Wire models for the person block (App Store guideline 1.2 — a UGC app must
// let a user block abusive users). Server: tovis-app `app/api/v1/blocks/`.
//
// ⚠️ These are NOT in `tovis-api.schema.json` and are deliberately absent from
// `scripts/contract/validate-fixtures.mjs`'s CHECKS list. The backend keeps the
// block DTOs out of `lib/dto/index.ts` — that barrel is the input to
// `gen:api-schema`, and adding to it reddens the WEB repo's CI until a matching
// iOS fixture PR merges. Keeping them out means neither side blocks the other.
// If contract coverage is wanted later, export them there and add a CHECKS
// entry in the SAME pair of PRs, iOS first.

/// Who to block. The server resolves either to one person — no client ever
/// learns a User id, so a target is named the way the surface already names it.
///
/// A look carries up to two people: the ORIGIN pro (`professional.id`, present
/// even on a client-authored look) and the publishing `clientAuthor.handle`.
/// "Block whoever posted this" therefore means the client author when there is
/// one, else the pro — see `LooksFeedItem.blockTarget`.
public enum BlockTarget: Sendable, Hashable {
    case professional(id: String)
    case handle(String)

    /// The POST body the server expects. Exactly one key is sent.
    var requestBody: [String: String] {
        switch self {
        case let .professional(id): return ["professionalId": id]
        case let .handle(handle): return ["handle": handle]
        }
    }
}

/// POST /api/v1/blocks. Idempotent — a re-block returns the EXISTING row id
/// rather than an error, so the caller can always render Unblock afterwards.
public struct BlockCreatedResponse: Decodable, Sendable {
    /// The `UserBlock` row id — the key DELETE /api/v1/blocks/{blockId} takes.
    public let blockId: String
    public let handle: String
    public let displayName: String
    public let blocked: Bool
}

/// One account the viewer has blocked. Carries no User id by design.
public struct BlockedAccount: Decodable, Sendable, Identifiable, Hashable {
    public let blockId: String
    /// The target's current public handle, or "" if they hold none.
    public let handle: String
    public let displayName: String
    public let avatarUrl: String?

    public var id: String { blockId }

    /// `displayName` already reads as "@handle" for a client author, so showing
    /// the handle underneath would print it twice.
    public var handleLabel: String? {
        guard !handle.isEmpty, "@\(handle)" != displayName else { return nil }
        return "@\(handle)"
    }
}

public struct BlocksListResponse: Decodable, Sendable {
    public let blocks: [BlockedAccount]
}

/// DELETE /api/v1/blocks/{blockId}. Idempotent, and deliberately does not
/// distinguish "not yours" from "already gone".
public struct BlockRemovedResponse: Decodable, Sendable {
    public let blockId: String
    public let blocked: Bool
}
