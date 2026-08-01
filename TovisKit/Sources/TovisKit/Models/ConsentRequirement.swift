import Foundation

/// K15's unsigned-consent mark, on the pro calendar's BOOKING events: this
/// client owes a signature on a form the pro requires for one of this
/// appointment's services.
///
/// 🔴 It WARNS, it never BLOCKS. Nothing on device may refuse to open, start or
/// edit a booking because of this field — the pro decides whether to send the
/// link, take a paper copy, or carry on. Web made the same call at its banner
/// and says so in the copy ("this is a reminder, not a block").
///
/// 🔴 It is a TEXT CHIP, not a colour and not a glyph. K7's channel budget
/// spends fill+border on status, the stripe on service and the corner glyph on
/// client confirmation, and the warning SHAPE already belongs to the conflict
/// triangle — a second amber triangle meaning something else is the disease B10
/// cured, in glyph form.
///
/// Decoding is non-throwing, exactly like `ProPaymentBadge` /
/// `ProRelationshipBadge` / `ProClientConfirmation`: an unknown future `kind`, a
/// malformed value or a missing subfield must never fail the WHOLE calendar
/// decode. It degrades to `display == nil` — the chip simply hides.
public struct ProConsentRequirement: Decodable, Sendable, Equatable {
    /// Every kind web's helper can emit today — exactly one, which is the point.
    /// The field answers "is a signature outstanding", not "which sort of form":
    /// a booking can owe several forms of different kinds at once and the chip
    /// prints one phrase (`describeUnsigned` counts them instead). A value
    /// outside this set is a FUTURE mark this build cannot describe, so
    /// `display` hides it rather than printing a warning it can't vouch for.
    public enum Kind: String, Sendable, CaseIterable {
        case unsignedConsent = "UNSIGNED_CONSENT"
    }

    /// DERIVED from `Kind`, never hand-listed beside it (the K11/K13 rule) — a
    /// second case added to the enum is known here the moment it exists.
    public static let knownKinds: Set<String> = Set(Kind.allCases.map(\.rawValue))

    public let kind: String?
    /// The short words a chip prints ("Form due"). Deliberately kind-neutral
    /// server-side: a patch test is not a "waiver".
    public let label: String?
    /// The plain-words expansion, NAMING the form ("Corrective colour waiver not
    /// signed"). Rides the accessibility label ALWAYS — the chip prints an
    /// abbreviation and "which form?" is the pro's very next question (the
    /// K5/K9-A words-not-shapes rule).
    public let description: String?
    /// Web Badge tone vocabulary — "warn" today, mapped by the one
    /// `wireBadgeTone` table rather than a hue chosen here.
    public let tone: String?
    /// 🔴 False for an appointment that is already OVER (started, or finished).
    ///
    /// A pro who binds their first form today would otherwise light up every
    /// past appointment for that service in amber — warnings about visits nobody
    /// can act on. The DECISION lives in web's `deriveConsentRequirementBadge`;
    /// no surface here re-derives it.
    ///
    /// ⚠️ This gate belongs to the CALENDAR and to nothing else. The session
    /// hub's list (`ProUnsignedConsentForm`) is deliberately ungated, because at
    /// session start `scheduledFor <= now` is true by definition — the same gate
    /// would blank the warning at the exact moment it is worth the most.
    public let significant: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, label, description, tone, significant
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        label = (try? container?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        description = (try? container?.decodeIfPresent(String.self, forKey: .description)) ?? nil
        tone = (try? container?.decodeIfPresent(String.self, forKey: .tone)) ?? nil
        significant = (try? container?.decodeIfPresent(Bool.self, forKey: .significant)) ?? nil
    }

    public init(kind: String?, label: String?, description: String?, tone: String?, significant: Bool?) {
        self.kind = kind
        self.label = label
        self.description = description
        self.tone = tone
        self.significant = significant
    }

    /// The mark a surface may render, or nil to show nothing: the kind must be
    /// one this build knows and the wire label must be non-blank (the words are
    /// server-composed and never rebuilt on device, so without them there is
    /// nothing truthful to print).
    ///
    /// `description` falls back to the label rather than to empty — it is the
    /// accessibility string, the one place this must not go silent.
    public var display: Display? {
        guard let kind, let known = Kind(rawValue: kind) else { return nil }
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let spelled = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readable = spelled.map { $0.isEmpty ? trimmed : $0 } ?? trimmed
        return Display(
            kind: known,
            label: trimmed,
            description: readable,
            tone: tone ?? "warn",
            significant: significant ?? true
        )
    }

    /// A validated, renderable mark — non-optional fields only.
    public struct Display: Sendable, Equatable {
        public let kind: Kind
        public let label: String
        public let description: String
        public let tone: String
        public let significant: Bool
    }
}

// MARK: - The session-start list

/// One consent form outstanding for a booking, as the session hub prints it —
/// `unsignedConsentForms` on `GET /api/v1/pro/bookings/{id}/session/state`
/// (K17-A) and on `GET /api/v1/pro/session`'s booking rows (#812).
///
/// 🔴 This is NOT the badge above, and the difference is the whole design.
/// The badge answers a CALENDAR's question ("is something outstanding on a tile
/// I'm scanning") and goes quiet once the appointment has started. This list
/// answers a SESSION's question ("what does the person in front of me still need
/// to sign"), which is asked precisely when the scheduled time has arrived — so
/// it carries no significance gate and nothing here may add one. It also names
/// each form individually, because the pro is about to act on them one at a
/// time.
///
/// Decoding is lenient in the same way the badges are, and for a sharper reason:
/// this rides on the session hub's state response, so one malformed element must
/// not blank the booking's entire session state. An element that cannot name
/// itself is dropped by `display`.
public struct ProUnsignedConsentForm: Decodable, Sendable, Equatable, Identifiable {
    public let formId: String?
    public let title: String?
    /// `kind` as words, from web's one label table ("Service waiver", "Patch
    /// test"). Rendered verbatim; never re-derived from a raw enum here.
    public let kindLabel: String?

    /// `Identifiable` needs a stable key even for a row that failed to name
    /// itself — such a row never reaches a list (see `display`), but the
    /// conformance must not trap on the way there.
    public var id: String { formId ?? title ?? "" }

    private enum CodingKeys: String, CodingKey {
        case formId, title, kindLabel
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        formId = (try? container?.decodeIfPresent(String.self, forKey: .formId)) ?? nil
        title = (try? container?.decodeIfPresent(String.self, forKey: .title)) ?? nil
        kindLabel = (try? container?.decodeIfPresent(String.self, forKey: .kindLabel)) ?? nil
    }

    public init(formId: String?, title: String?, kindLabel: String?) {
        self.formId = formId
        self.title = title
        self.kindLabel = kindLabel
    }

    /// The row a surface may render, or nil to drop it.
    ///
    /// A form needs an id (to send a link for) and a title (to name). Web
    /// already substitutes "Consent form" for a version with a blank title, so a
    /// blank one arriving here means the wire is broken rather than the pro
    /// having left it empty. `kindLabel` is genuinely optional — it is a
    /// qualifier beside the name, and a missing one costs the pro a nuance, not
    /// the warning.
    public var display: Display? {
        guard let formId = formId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !formId.isEmpty else { return nil }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let kind = kindLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Display(formId: formId, title: title, kindLabel: (kind?.isEmpty ?? true) ? nil : kind)
    }

    /// A validated, renderable row — non-optional fields only.
    public struct Display: Sendable, Equatable, Identifiable {
        public let formId: String
        public let title: String
        public let kindLabel: String?

        public var id: String { formId }

        /// What VoiceOver reads for one row: the form's name, then its kind,
        /// then the thing that is actually wrong. The visual row separates the
        /// first two with a middle dot, which is not a word.
        public var accessibilityLabel: String {
            guard let kindLabel else { return "\(title), not signed" }
            return "\(title), \(kindLabel), not signed"
        }
    }
}

public extension Array where Element == ProUnsignedConsentForm {
    /// The rows worth rendering, in wire order. A feed that names nothing yields
    /// an empty list, and a session-start banner over an empty list is a warning
    /// with no content — so the caller shows nothing at all.
    var displayable: [ProUnsignedConsentForm.Display] {
        compactMap(\.display)
    }
}
