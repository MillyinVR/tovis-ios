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

    /// The event-date payoff line for this board, or nil when its type takes no
    /// date (only bridal/prom do) — port of the web `BoardEventCountdown` card's
    /// state machine. `now` is injectable for tests.
    public func eventCountdown(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BoardEventCountdownState? {
        BoardEventCountdownState.resolve(
            type: type, eventDate: eventDate, now: now, calendar: calendar
        )
    }
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
    public var caption: String? { lookPost?.caption?.trimmedOrNil }
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

/// `GET /api/v1/boards` → `{ ok, boards: [...] }`. The list DTO carries no `slug`
/// (unlike the detail/create `board`), so it can't decode into `Board`; the
/// Save-to-board picker only needs each board's id/name/visibility, so it decodes
/// into `LooksBoard` and ignores the rest.
struct BoardsListResponse: Decodable, Sendable {
    let boards: [LooksBoard]
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

/// `PATCH /api/v1/boards/{id}` body for the event-date editor ("the wedding date
/// moves" is the spec's canonical edit case). `nil` CLEARS the date.
struct UpdateBoardEventDateRequest: Encodable, Sendable {
    /// `YYYY-MM-DD`, or nil to clear.
    let eventDate: String?

    private enum CodingKeys: String, CodingKey { case eventDate }

    /// Hand-written because the synthesized encoder uses `encodeIfPresent`, which
    /// would OMIT a nil `eventDate` — and an absent key means "nothing to update"
    /// to the route (400 `NOTHING_TO_UPDATE`), not "clear it". The clear is an
    /// explicit `eventDate: null`, exactly what the web card PATCHes.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let eventDate {
            try container.encode(eventDate, forKey: .eventDate)
        } else {
            try container.encodeNil(forKey: .eventDate)
        }
    }
}

// MARK: - Event date

/// Calendar-date helpers for a board's `eventDate` — the `YYYY-MM-DD` wire format
/// shared by the create flow, the detail editor, and the countdown. Also the
/// serializer for every other date-only pick sent from an unpinned picker
/// (license expiry in ProSignupView/ProVerificationView).
///
/// An event date is a CALENDAR date, not an instant: the wire string carries no
/// timezone, and the backend stores it as a `@db.Date` (`parseBoardEventDateYmd`
/// → UTC midnight, read back via `boardEventDateToYmd`). So every conversion here
/// runs in the VIEWER'S calendar, matching web — where `<input type="date">`
/// yields the literal date the user picked and `daysUntilEvent` counts from
/// `today.getFullYear()/getMonth()/getDate()` (local). Formatting a picked date in
/// UTC instead shifts it a day for any viewer whose offset crosses midnight.
public enum BoardEventDate {
    /// Strict `YYYY-MM-DD` — mirrors the web `BOARD_EVENT_DATE_REGEX`. Computed,
    /// not stored: `Regex` isn't `Sendable`, so a static constant trips Swift 6's
    /// global-concurrency check.
    private static var pattern: Regex<(Substring, Substring, Substring, Substring)> {
        /^(\d{4})-(\d{2})-(\d{2})$/
    }

    /// The `YYYY-MM-DD` a picked `Date` falls on in the viewer's calendar.
    public static func ymd(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// Midnight on `ymd` in the viewer's calendar — the DatePicker's selection.
    /// Returns nil for anything malformed or impossible (`2026-02-30`), mirroring
    /// `parseBoardEventDateYmd`: a calendar would silently ROLL those over, so the
    /// components are read back and compared.
    public static func date(fromYmd ymd: String, calendar: Calendar = .current) -> Date? {
        guard let match = ymd.wholeMatch(of: pattern),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              let parsed = calendar.date(
                  from: DateComponents(year: year, month: month, day: day)
              )
        else { return nil }

        let parts = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return parsed
    }

    /// Whole calendar days from `now` to `eventYmd` — the "42 days until prom"
    /// number. Negative once the event has passed; nil when `eventYmd` is
    /// malformed. Port of `daysUntilEvent` (lib/boards/context.ts).
    public static func daysUntil(
        eventYmd: String,
        from now: Date,
        calendar: Calendar = .current
    ) -> Int? {
        guard let event = date(fromYmd: eventYmd, calendar: calendar) else { return nil }
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: event
        ).day
    }
}

/// What the board detail's event-date card says right now — the three states of
/// the web `BoardEventCountdown` card, resolved off the board's type + date.
public enum BoardEventCountdownState: Equatable, Sendable {
    /// The payoff line: "42 days until your wedding".
    case countdown(String)
    /// The date is in the past — warm, and never a nag.
    case passed(String)
    /// No date captured yet; the card asks for one.
    case prompt(String)

    /// The line to render.
    public var text: String {
        switch self {
        case let .countdown(text), let .passed(text), let .prompt(text): text
        }
    }

    /// Only the live countdown is the emphasized payoff; the other two are
    /// secondary copy (web renders them in `text-textSecondary`).
    public var isEmphasized: Bool {
        if case .countdown = self { return true }
        return false
    }

    /// nil when this board type takes no event date, so the card hides entirely.
    /// A malformed/unparseable stored date reads as "no date" rather than
    /// rendering a broken countdown.
    public static func resolve(
        type: String,
        eventDate: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BoardEventCountdownState? {
        guard BoardCatalog.wantsEventDate(for: type) else { return nil }
        let noun = BoardCatalog.eventNoun(for: type) ?? BoardCatalog.fallbackEventNoun

        guard let eventDate,
              let days = BoardEventDate.daysUntil(eventYmd: eventDate, from: now, calendar: calendar)
        else {
            return .prompt("Add the date of \(noun) to get a countdown and better timing.")
        }

        switch days {
        case ..<0: return .passed("Hope \(noun) was everything you wanted.")
        case 0: return .countdown("Today’s the day — it’s \(noun)!")
        case 1: return .countdown("1 day until \(noun)")
        default: return .countdown("\(days) days until \(noun)")
        }
    }
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
    public var wantsEventDate: Bool { BoardCatalog.wantsEventDate(for: value) }
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

    /// Board types whose flow captures an event date — port of
    /// `EVENT_DATE_BOARD_TYPES` / `boardTypeWantsEventDate` (bridal/prom only).
    /// The single source of truth for both the create picker and the countdown.
    public static func wantsEventDate(for type: String) -> Bool {
        eventNouns[type.uppercased()] != nil
    }

    /// What a board's countdown counts down TO ("42 days until **prom**") — port
    /// of `BOARD_EVENT_NOUNS`. nil for a type that takes no date.
    public static func eventNoun(for type: String) -> String? {
        eventNouns[type.uppercased()]
    }

    /// Mirrors the web card's `?? 'the big day'`. Unreachable while every
    /// event-dated type has a noun (the two lists are the same map here), kept so
    /// a future dated type can't render an empty phrase.
    public static let fallbackEventNoun = "the big day"

    /// `BOARD_EVENT_NOUNS`. Keying `wantsEventDate` off this map — rather than a
    /// second list of type values — makes the two impossible to drift apart.
    private static let eventNouns: [String: String] = [
        "BRIDAL": "your wedding",
        "PROM": "prom",
    ]

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
