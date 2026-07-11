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

/// `POST /api/v1/boards` body. `visibility`/`type` are always sent; `eventDate`,
/// `answers`, and `writeThroughSelfProfile` are omitted when nil (the synthesized
/// encoder uses `encodeIfPresent`) so a text-only create body stays byte-identical.
/// `answers` is the per-type chip answers (question key → option value, spec §7.3);
/// `writeThroughSelfProfile: true` opts the person-describing subset into the
/// self-profile (the backend keys on `=== true`).
struct CreateBoardRequest: Encodable, Sendable {
    let name: String
    let visibility: String
    let type: String
    let eventDate: String?
    let answers: [String: String]?
    let writeThroughSelfProfile: Bool?
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

/// One chip option for a board creation-context question — a faithful port of a
/// `BoardQuestionOption` (lib/boards/context.ts). `value` is the stored answer
/// (validated server-side by `normalizeBoardAnswers`); `label` is display only.
public struct BoardQuestionOption: Identifiable, Sendable, Equatable {
    public let value: String
    public let label: String
    public var id: String { value }

    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// A per-type creation-context question (spec §7.3) — a stable snake_case key, the
/// question copy, and its single-select chip options. Port of `BoardQuestionDef`.
public struct BoardQuestion: Identifiable, Sendable, Equatable {
    public let key: String
    public let label: String
    public let options: [BoardQuestionOption]
    public var id: String { key }
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

    /// The per-type chip questions asked once at creation (spec §7.3) — a faithful
    /// port of `BOARD_QUESTION_SETS`. GENERAL (and any unknown type) has none. The
    /// event-date question for bridal/prom is handled separately (a date picker).
    public static func questions(for type: String) -> [BoardQuestion] {
        questionSets[type.uppercased()] ?? []
    }

    /// Board answer keys that describe the PERSON (not the occasion), matching
    /// `BOARD_ANSWER_WRITE_THROUGH` — answering any offers the "save to my
    /// profile" opt-in. Option values match the self-profile 1:1 by construction.
    public static let writeThroughAnswerKeys: Set<String> = [
        "hair_length", "current_color", "skin_type", "main_concern",
    ]

    private static let hairLength = BoardQuestion(
        key: "hair_length",
        label: "How long is your hair right now?",
        options: [.init("short", "Short"), .init("medium", "Medium"), .init("long", "Long")]
    )

    private static let questionSets: [String: [BoardQuestion]] = [
        "GENERAL": [],
        "BRIDAL": [
            hairLength,
            BoardQuestion(key: "trial_timeline", label: "When would you want a trial?", options: [
                .init("6-8-weeks-before", "6–8 weeks before"),
                .init("2-4-weeks-before", "2–4 weeks before"),
                .init("no-trial", "No trial needed"),
            ]),
        ],
        "PROM": [
            BoardQuestion(key: "dress_color", label: "What color is your dress?", options: [
                .init("red", "Red"), .init("pink", "Pink"), .init("blue", "Blue"),
                .init("green", "Green"), .init("black", "Black"), .init("white", "White"),
                .init("metallic", "Gold / silver"), .init("undecided", "Still deciding"),
            ]),
            hairLength,
        ],
        "SKINCARE": [
            BoardQuestion(key: "skin_type", label: "How would you describe your skin?", options: [
                .init("oily", "Oily"), .init("dry", "Dry"), .init("combination", "Combination"),
                .init("sensitive", "Sensitive"), .init("normal", "Normal"),
            ]),
            BoardQuestion(key: "main_concern", label: "What matters most to you?", options: [
                .init("acne", "Breakouts"), .init("aging", "Fine lines"),
                .init("dullness", "Dullness"), .init("redness", "Redness"),
                .init("texture", "Texture"),
            ]),
            BoardQuestion(key: "had_facial_before", label: "Ever had a facial before?", options: [
                .init("yes", "Yes"), .init("no", "First time"),
            ]),
        ],
        "PERMANENT_MAKEUP": [
            BoardQuestion(key: "had_it_before", label: "Have you had it done before?", options: [
                .init("yes", "Yes"), .init("no", "First time"),
            ]),
            BoardQuestion(
                key: "confidence_topic",
                label: "What do you want to feel confident about before booking?",
                options: [
                    .init("healing-process", "The healing process"),
                    .init("pain-level", "How it feels"),
                    .init("natural-look", "It looking natural"),
                    .init("cost", "Cost"),
                ]
            ),
            BoardQuestion(key: "brow_situation", label: "Your brows today?", options: [
                .init("sparse", "Sparse"), .init("over-plucked", "Over-plucked"),
                .init("patchy", "Patchy"), .init("full-but-undefined", "Full but undefined"),
            ]),
        ],
        "COLOR_TRANSFORMATION": [
            BoardQuestion(key: "current_color", label: "Your current color?", options: [
                .init("blonde", "Blonde"), .init("brunette", "Brunette"),
                .init("black", "Black"), .init("red", "Red"),
                .init("gray", "Gray / silver"), .init("other", "Something else"),
            ]),
            BoardQuestion(key: "dream_color", label: "Your dream color?", options: [
                .init("blonde", "Blonde"), .init("brunette", "Brunette"),
                .init("black", "Black"), .init("red", "Red"),
                .init("fantasy", "Fantasy / vivid"), .init("not-sure", "Not sure yet"),
            ]),
            BoardQuestion(key: "change_scale", label: "How big a change are you after?", options: [
                .init("subtle", "Subtle"), .init("noticeable", "Noticeable"),
                .init("total", "Total transformation"),
            ]),
        ],
        "NAILS": [
            BoardQuestion(key: "length_preference", label: "What length do you like?", options: [
                .init("short", "Short"), .init("medium", "Medium"),
                .init("long", "Long"), .init("extra-long", "Extra long"),
            ]),
            BoardQuestion(key: "occasion", label: "What are these for?", options: [
                .init("everyday", "Everyday"), .init("event", "An event"),
                .init("vacation", "Vacation"),
            ]),
        ],
    ]
}
