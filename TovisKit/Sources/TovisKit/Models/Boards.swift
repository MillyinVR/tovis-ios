import Foundation

// Wire models for the client Boards feature — the native counterpart to the web
// `/client/boards/[boardId]` detail page + the create flow. Backed by:
//   • GET   /api/v1/boards/{id}  → { board }   (owner-scoped detail)
//   • POST  /api/v1/boards       → { board }   (create; 201)
//   • PATCH /api/v1/boards/{id}  → { board }   (visibility toggle — share)
// Mirrors `LooksBoardDetailDto` (lib/looks/types.ts). Only the rendered subset is
// modeled; nullable fields are Swift optionals and unknown keys are ignored.
//
// The BOARDS list itself already arrives inside the `/me` payload as
// `ClientMeBoard` (see ClientMe.swift) — this file adds the detail + create/share
// surface that the dead-end board card lacked.

/// Owner-scoped board detail — `LooksBoardDetailDto`.
public struct Board: Decodable, Sendable, Identifiable {
    public let id: String
    public let clientId: String
    public let name: String
    /// URL-safe slug for the public `/u/{handle}/boards/{slug}` share address.
    public let slug: String
    /// "PRIVATE" | "SHARED" — kept as a raw string (server-driven; a new value
    /// never fails decoding), matching iOS's checkout/notification convention.
    public let visibility: String
    /// BoardType raw ("GENERAL", "BRIDAL", …). See `BoardCatalog`.
    public let type: String
    /// `YYYY-MM-DD` the board counts down to (bridal/prom only); nil otherwise.
    public let eventDate: String?
    public let itemCount: Int
    public let items: [BoardItem]

    /// True when the board is public/shareable.
    public var isShared: Bool { visibility.uppercased() == "SHARED" }
}

/// One saved look on a board — `LooksBoardDetailItemDto`.
public struct BoardItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let lookPostId: String
    public let lookPost: BoardLookPost?

    /// The image to render for this saved look (prefer the thumb, else the full
    /// URL) — mirrors the web `boardImageUrl`.
    public var imageUrl: String? {
        lookPost?.primaryMedia?.thumbUrl ?? lookPost?.primaryMedia?.url
    }

    /// A short display caption; falls back to nil so the board name can stand in.
    public var caption: String? {
        let trimmed = lookPost?.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

public struct BoardLookPost: Decodable, Sendable {
    public let id: String
    public let caption: String?
    public let primaryMedia: BoardMedia?
}

public struct BoardMedia: Decodable, Sendable {
    public let id: String
    public let url: String?
    public let thumbUrl: String?
}

// MARK: - Envelopes

/// `GET`/`POST`/`PATCH /api/v1/boards[/{id}]` → `{ ok, board }`.
struct BoardDetailResponse: Decodable, Sendable {
    let board: Board
}

// MARK: - Request bodies

/// `POST /api/v1/boards` body. `visibility`/`type` are always sent; `eventDate`
/// is omitted when nil (the synthesized encoder uses `encodeIfPresent`), which
/// the backend reads as "no event date" — matching the web create form where an
/// absent date leaves the board undated.
struct CreateBoardRequest: Encodable, Sendable {
    let name: String
    let visibility: String
    let type: String
    let eventDate: String?
}

/// `PATCH /api/v1/boards/{id}` body for the share (visibility) toggle — the only
/// field the native share control changes. Other editable fields (name, type,
/// answers) aren't exposed on the board detail page (web parity).
struct UpdateBoardVisibilityRequest: Encodable, Sendable {
    let visibility: String
}

// MARK: - Board type catalog

/// A board-type chip option — a faithful port of a `BOARD_TYPE_VALUES` entry +
/// its `BOARD_TYPE_LABELS` label (lib/boards/context.ts). Rendering only; the
/// backend stays the authoritative validator (the HandleRules/SelfProfileCatalog
/// port pattern).
public struct BoardTypeOption: Identifiable, Sendable, Equatable {
    /// BoardType raw value ("GENERAL", "BRIDAL", …).
    public let value: String
    public let label: String

    public var id: String { value }

    /// Whether creating this type of board asks for an event date — mirrors
    /// `boardTypeWantsEventDate` (bridal/prom only).
    public var wantsEventDate: Bool {
        value == "BRIDAL" || value == "PROM"
    }
}

public enum BoardCatalog {
    /// The board types offered at creation, in the web chip order.
    public static let types: [BoardTypeOption] = [
        BoardTypeOption(value: "GENERAL", label: "Just collecting"),
        BoardTypeOption(value: "BRIDAL", label: "Wedding"),
        BoardTypeOption(value: "PROM", label: "Prom"),
        BoardTypeOption(value: "SKINCARE", label: "Facial / skincare"),
        BoardTypeOption(value: "PERMANENT_MAKEUP", label: "Brows / permanent makeup"),
        BoardTypeOption(value: "COLOR_TRANSFORMATION", label: "Color / transformation"),
        BoardTypeOption(value: "NAILS", label: "Nails"),
    ]

    /// The human label for a board type raw value, or nil for an unknown type
    /// (so callers can hide the chip rather than show a raw enum name).
    public static func label(for type: String) -> String? {
        let upper = type.uppercased()
        return types.first { $0.value == upper }?.label
    }
}
