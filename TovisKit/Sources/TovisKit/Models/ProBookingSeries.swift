import Foundation

/// K18–K20 (Phase 8) — a RECURRING APPOINTMENT, read back.
/// `GET /api/v1/pro/booking-series/{id}` → `ProBookingSeriesDetailDTO`.
///
/// Until K20 the series was invisible on device (K18-D/K19-D): the schema, the
/// materializer, the UI and the roll-forward all existed on web and the phone
/// had no fixture, no contract entry and no surface. A pro whose calendar was
/// half standing appointments could not see, on the device they actually carry,
/// which of them repeated or what would happen next.
///
/// Three things this model must NOT get wrong, all of them things web learned
/// the hard way:
///
///  1. 🔴 **The SKIPS are part of the answer.** A series can legitimately have
///     booked eleven of twelve dates, and a surface that renders only
///     `occurrences` tells the pro they got twelve
///     ([[an-always-empty-key-looks-like-an-export]]). `skipped` is not an error
///     channel; it rides the success body.
///  2. 🔴 **The PIN is what the client is charged.** `pricing.pinnedTotalCents`
///     is the money the client agreed to, and K20's roll-forward books every
///     later date at it. `currentListTotalCents` is the pro's CATALOG figure for
///     comparison only — never a prediction of the next bill. A surface that
///     showed the two without saying which is which would be worse than showing
///     one.
///  3. **`rollForward.willContinue` already accounts for the kill switch.** It
///     is false when the feature is off, so the device must render it as given
///     and never re-derive "is it active and unfinished" from status + counts
///     ([[verifiable-rail-still-needs-an-operator]]).
///
/// Decoding is non-throwing throughout, the K2/K6/K9 rule: a malformed
/// occurrence must not blank the whole series. Every optional degrades to a row
/// or a section that hides.
public struct ProBookingSeriesDetail: Decodable, Sendable, Equatable {
    public let seriesId: String?
    /// `ACTIVE` / `ENDED` / `CANCELLED`. Read through `statusDisplay`.
    public let status: String?
    /// The zone the PATTERN steps through — the LOCATION's, not the viewer's.
    /// "Every Friday 9am" is 9am there, so every date below must be rendered in
    /// this zone or the pro reads a different day near midnight.
    public let timeZone: String?
    public let anchorAt: String?
    public let intervalWeeks: Int?
    /// Planned total, or nil for an OPEN-ENDED series. nil is a real answer
    /// here, not a missing one.
    public let occurrenceCount: Int?
    public let nextOccurrenceIndex: Int?
    public let depositRequested: Bool?
    public let depositPerOccurrence: Bool?
    public let clientId: String?
    public let clientName: String?
    public let offeringId: String?
    public let serviceName: String?
    public let locationId: String?
    public let locationLabel: String?
    public let locationType: String?
    public let addOnNames: [String]?
    public let internalNotes: String?
    public let pricing: Pricing?
    public let rollForward: RollForward?
    public let occurrences: [Occurrence]?
    public let skipped: [Skipped]?

    private enum CodingKeys: String, CodingKey {
        case seriesId, status, timeZone, anchorAt, intervalWeeks, occurrenceCount
        case nextOccurrenceIndex, depositRequested, depositPerOccurrence
        case clientId, clientName, offeringId, serviceName, locationId
        case locationLabel, locationType, addOnNames, internalNotes
        case pricing, rollForward, occurrences, skipped
    }

    public init(from decoder: Decoder) {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        seriesId = (try? c?.decodeIfPresent(String.self, forKey: .seriesId)) ?? nil
        status = (try? c?.decodeIfPresent(String.self, forKey: .status)) ?? nil
        timeZone = (try? c?.decodeIfPresent(String.self, forKey: .timeZone)) ?? nil
        anchorAt = (try? c?.decodeIfPresent(String.self, forKey: .anchorAt)) ?? nil
        intervalWeeks = (try? c?.decodeIfPresent(Int.self, forKey: .intervalWeeks)) ?? nil
        occurrenceCount = (try? c?.decodeIfPresent(Int.self, forKey: .occurrenceCount)) ?? nil
        nextOccurrenceIndex = (try? c?.decodeIfPresent(Int.self, forKey: .nextOccurrenceIndex)) ?? nil
        depositRequested = (try? c?.decodeIfPresent(Bool.self, forKey: .depositRequested)) ?? nil
        depositPerOccurrence = (try? c?.decodeIfPresent(Bool.self, forKey: .depositPerOccurrence)) ?? nil
        clientId = (try? c?.decodeIfPresent(String.self, forKey: .clientId)) ?? nil
        clientName = (try? c?.decodeIfPresent(String.self, forKey: .clientName)) ?? nil
        offeringId = (try? c?.decodeIfPresent(String.self, forKey: .offeringId)) ?? nil
        serviceName = (try? c?.decodeIfPresent(String.self, forKey: .serviceName)) ?? nil
        locationId = (try? c?.decodeIfPresent(String.self, forKey: .locationId)) ?? nil
        locationLabel = (try? c?.decodeIfPresent(String.self, forKey: .locationLabel)) ?? nil
        locationType = (try? c?.decodeIfPresent(String.self, forKey: .locationType)) ?? nil
        addOnNames = (try? c?.decodeIfPresent([String].self, forKey: .addOnNames)) ?? nil
        internalNotes = (try? c?.decodeIfPresent(String.self, forKey: .internalNotes)) ?? nil
        pricing = (try? c?.decodeIfPresent(Pricing.self, forKey: .pricing)) ?? nil
        rollForward = (try? c?.decodeIfPresent(RollForward.self, forKey: .rollForward)) ?? nil
        occurrences = (try? c?.decodeIfPresent([Occurrence].self, forKey: .occurrences)) ?? nil
        skipped = (try? c?.decodeIfPresent([Skipped].self, forKey: .skipped)) ?? nil
    }

    // MARK: - Derived

    /// The cadence in words: "Every week" / "Every 4 weeks". Composed here
    /// rather than server-side because the server sends the NUMBER and this is
    /// the only phrasing on device; web says the same thing from the same field.
    public var cadenceLabel: String? {
        guard let weeks = intervalWeeks, weeks > 0 else { return nil }
        return weeks == 1 ? "Every week" : "Every \(weeks) weeks"
    }

    /// "12 planned" or "Open-ended". nil `occurrenceCount` is OPEN-ENDED, which
    /// is a fact, not a gap — the K20 roll-forward is what makes it truthful.
    public var plannedLabel: String {
        guard let total = occurrenceCount else { return "Open-ended" }
        return "\(total) planned"
    }

    /// The occurrences worth listing, in wire order, dropping any that cannot
    /// name themselves.
    public var occurrenceRows: [Occurrence.Display] {
        (occurrences ?? []).compactMap(\.display)
    }

    /// The skips worth listing. Same rule, and the same reason it matters more:
    /// this list is the difference between "you got twelve" and the truth.
    public var skippedRows: [Skipped.Display] {
        (skipped ?? []).compactMap(\.display)
    }

    /// "11 of 12 dates booked" — ATTEMPTED, not planned. An open-ended series
    /// that has materialized its first window has not failed to book the rest;
    /// it simply has not reached them, and K20's cron will.
    public var attemptedCount: Int { occurrenceRows.count + skippedRows.count }

    /// The status word a badge prints, or nil for a status this build does not
    /// know (a future value must not render as a made-up state).
    public var statusDisplay: Status? {
        guard let status else { return nil }
        return Status(rawValue: status)
    }

    public enum Status: String, Sendable, CaseIterable {
        case active = "ACTIVE"
        case ended = "ENDED"
        case cancelled = "CANCELLED"

        /// Words, not the raw enum — the B10 rule.
        public var label: String {
            switch self {
            case .active: return "Active"
            case .ended: return "Finished"
            case .cancelled: return "Stopped"
            }
        }
    }

    // MARK: - Pricing

    /// Price pinning (plan §Phase 8, decided in K20): the series is priced by
    /// what occurrence 0 was booked at, and every date the roll-forward adds is
    /// booked at the same figure. Drift is SURFACED, never applied.
    public struct Pricing: Decodable, Sendable, Equatable {
        /// Occurrence 0's booked subtotal, in cents. **This is what the client
        /// is charged**, including for dates not yet created.
        public let pinnedTotalCents: Int?
        /// The pro's CURRENT list price, in cents. A comparison the pro can act
        /// on — never a prediction of the next bill, because what a given client
        /// pays runs through a price-grace ramp this does not reproduce.
        public let currentListTotalCents: Int?
        public let occurrencesDisagree: Bool?
        public let listPriceMoved: Bool?

        private enum CodingKeys: String, CodingKey {
            case pinnedTotalCents, currentListTotalCents, occurrencesDisagree, listPriceMoved
        }

        public init(from decoder: Decoder) {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            pinnedTotalCents = (try? c?.decodeIfPresent(Int.self, forKey: .pinnedTotalCents)) ?? nil
            currentListTotalCents = (try? c?.decodeIfPresent(Int.self, forKey: .currentListTotalCents)) ?? nil
            occurrencesDisagree = (try? c?.decodeIfPresent(Bool.self, forKey: .occurrencesDisagree)) ?? nil
            listPriceMoved = (try? c?.decodeIfPresent(Bool.self, forKey: .listPriceMoved)) ?? nil
        }

        public init(
            pinnedTotalCents: Int?,
            currentListTotalCents: Int?,
            occurrencesDisagree: Bool?,
            listPriceMoved: Bool?
        ) {
            self.pinnedTotalCents = pinnedTotalCents
            self.currentListTotalCents = currentListTotalCents
            self.occurrencesDisagree = occurrencesDisagree
            self.listPriceMoved = listPriceMoved
        }

        /// Show the "your list price has moved" note? Only when the flag is set
        /// AND there is a figure to print — a note naming no number is noise.
        public var showsListPriceComparison: Bool {
            listPriceMoved == true && currentListTotalCents != nil
        }
    }

    // MARK: - Roll-forward (K20)

    /// Whether this series still GROWS, and how far ahead.
    public struct RollForward: Decodable, Sendable, Equatable {
        /// 🔴 Rendered as given, never re-derived. The server folds the
        /// recurring-appointments kill switch into this, so a device that
        /// recomputed it from `status` + counts would promise new dates while
        /// the operator was switched off.
        public let willContinue: Bool?
        /// Planned occurrences not yet attempted, or nil for an open-ended
        /// series (which has no total to count down from).
        public let pendingCount: Int?
        public let leadDays: Int?

        private enum CodingKeys: String, CodingKey {
            case willContinue, pendingCount, leadDays
        }

        public init(from decoder: Decoder) {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            willContinue = (try? c?.decodeIfPresent(Bool.self, forKey: .willContinue)) ?? nil
            pendingCount = (try? c?.decodeIfPresent(Int.self, forKey: .pendingCount)) ?? nil
            leadDays = (try? c?.decodeIfPresent(Int.self, forKey: .leadDays)) ?? nil
        }

        public init(willContinue: Bool?, pendingCount: Int?, leadDays: Int?) {
            self.willContinue = willContinue
            self.pendingCount = pendingCount
            self.leadDays = leadDays
        }

        /// The sentence the pro reads, or nil to say nothing at all.
        ///
        /// Absent when the series will not continue — silence is correct there,
        /// because "no more dates are coming" is already what the counts above
        /// say, and a second, negative sentence would read as a fault.
        public var sentence: String? {
            guard willContinue == true else { return nil }
            let lead = leadDays ?? 90
            let opening: String = {
                guard let pending = pendingCount else {
                    return "This series is open-ended."
                }
                guard pending > 0 else { return "" }
                let noun = pending == 1 ? "appointment is" : "appointments are"
                return "\(pending) more \(noun) still to come."
            }()
            let body =
                "Dates are added to your calendar automatically, "
                + "about \(lead) days ahead — you do not need to do anything."
            return opening.isEmpty ? body : "\(opening) \(body)"
        }
    }

    // MARK: - Occurrences

    /// One appointment the series actually produced.
    public struct Occurrence: Decodable, Sendable, Equatable {
        public let index: Int?
        public let bookingId: String?
        public let scheduledFor: String?
        public let status: String?
        public let startedAt: String?
        /// What THIS occurrence was booked at, in cents. Occurrence 0's value is
        /// the series pin; a later one that disagrees is drift the pro is owed a
        /// sight of.
        public let bookedTotalCents: Int?
        /// Deposit money still held. NOT a bill — it is here because a scoped
        /// cancel does not refund.
        public let depositHeldCents: Int?
        public let cancellable: Bool?
        public let untouchedReason: String?

        private enum CodingKeys: String, CodingKey {
            case index, bookingId, scheduledFor, status, startedAt
            case bookedTotalCents, depositHeldCents, cancellable, untouchedReason
        }

        public init(from decoder: Decoder) {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            index = (try? c?.decodeIfPresent(Int.self, forKey: .index)) ?? nil
            bookingId = (try? c?.decodeIfPresent(String.self, forKey: .bookingId)) ?? nil
            scheduledFor = (try? c?.decodeIfPresent(String.self, forKey: .scheduledFor)) ?? nil
            status = (try? c?.decodeIfPresent(String.self, forKey: .status)) ?? nil
            startedAt = (try? c?.decodeIfPresent(String.self, forKey: .startedAt)) ?? nil
            bookedTotalCents = (try? c?.decodeIfPresent(Int.self, forKey: .bookedTotalCents)) ?? nil
            depositHeldCents = (try? c?.decodeIfPresent(Int.self, forKey: .depositHeldCents)) ?? nil
            cancellable = (try? c?.decodeIfPresent(Bool.self, forKey: .cancellable)) ?? nil
            untouchedReason = (try? c?.decodeIfPresent(String.self, forKey: .untouchedReason)) ?? nil
        }

        public init(
            index: Int?, bookingId: String?, scheduledFor: String?, status: String?,
            startedAt: String?, bookedTotalCents: Int?, depositHeldCents: Int?,
            cancellable: Bool?, untouchedReason: String?
        ) {
            self.index = index
            self.bookingId = bookingId
            self.scheduledFor = scheduledFor
            self.status = status
            self.startedAt = startedAt
            self.bookedTotalCents = bookedTotalCents
            self.depositHeldCents = depositHeldCents
            self.cancellable = cancellable
            self.untouchedReason = untouchedReason
        }

        /// A row a list may render, or nil to drop it. It needs a booking to
        /// open and an instant to place; an index-less row is dropped rather
        /// than shown as "appointment 0", which would be a different appointment.
        public var display: Display? {
            guard let bookingId = bookingId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bookingId.isEmpty else { return nil }
            guard let scheduledFor = scheduledFor?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !scheduledFor.isEmpty else { return nil }
            guard let index, index >= 0 else { return nil }
            return Display(
                index: index,
                bookingId: bookingId,
                scheduledFor: scheduledFor,
                status: status ?? "",
                bookedTotalCents: bookedTotalCents,
                depositHeldCents: depositHeldCents ?? 0,
                cancellable: cancellable ?? false
            )
        }

        public struct Display: Sendable, Equatable, Identifiable {
            public let index: Int
            public let bookingId: String
            public let scheduledFor: String
            public let status: String
            public let bookedTotalCents: Int?
            public let depositHeldCents: Int
            public let cancellable: Bool

            public var id: String { bookingId }
            /// 1-based, for humans — the same ordinal `ProRecurringMark` prints.
            public var occurrenceNumber: Int { index + 1 }
        }
    }

    // MARK: - Skips

    /// One occurrence the materializer did NOT create, and why.
    ///
    /// 🔴 A SKIP IS PERMANENT. It is a `BookingSeriesException` row, unique per
    /// index, which the roll-forward never retries — which is precisely why K20
    /// made "too far ahead" defer instead of recording one. Nothing on device
    /// may present a skip as something that will sort itself out.
    public struct Skipped: Decodable, Sendable, Equatable {
        public let index: Int?
        /// The instant it would have taken, or nil for a DST gap where no such
        /// instant exists — `detail` then carries the wall clock that does not.
        public let intendedStart: String?
        public let reason: String?
        /// The refusal code, or the impossible wall-clock time. DIAGNOSTIC, not
        /// user copy — never printed as a sentence.
        public let detail: String?

        private enum CodingKeys: String, CodingKey {
            case index, intendedStart, reason, detail
        }

        public init(from decoder: Decoder) {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            index = (try? c?.decodeIfPresent(Int.self, forKey: .index)) ?? nil
            intendedStart = (try? c?.decodeIfPresent(String.self, forKey: .intendedStart)) ?? nil
            reason = (try? c?.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            detail = (try? c?.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        }

        public init(index: Int?, intendedStart: String?, reason: String?, detail: String?) {
            self.index = index
            self.intendedStart = intendedStart
            self.reason = reason
            self.detail = detail
        }

        /// Every reason web can send. An unknown one still renders — a skip the
        /// device cannot explain is still a date the pro did not get, and hiding
        /// it would be the very failure this list exists to prevent.
        public enum Reason: String, Sendable, CaseIterable {
            case slotUnavailable = "SLOT_UNAVAILABLE"
            case nonexistentLocalTime = "NONEXISTENT_LOCAL_TIME"
            case refused = "REFUSED"
        }

        public var display: Display? {
            guard let index, index >= 0 else { return nil }
            let code = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Display(
                index: index,
                intendedStart: intendedStart?.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: reason.flatMap(Reason.init(rawValue:)),
                detail: (code?.isEmpty ?? true) ? nil : code
            )
        }

        public struct Display: Sendable, Equatable, Identifiable {
            public let index: Int
            public let intendedStart: String?
            /// nil for a reason this build does not know — the row still shows.
            public let reason: Reason?
            public let detail: String?

            public var id: Int { index }
            public var occurrenceNumber: Int { index + 1 }

            /// The plain-words explanation. Composed on device because web
            /// composes it on web from the same enum — this is one of the few
            /// places both platforms own the sentence, and the unknown-reason
            /// fallback deliberately says what IS known rather than guessing.
            public var explanation: String {
                switch reason {
                case .slotUnavailable:
                    return "That time was already taken, so this date was left alone rather than double-booked."
                case .nonexistentLocalTime:
                    return "That clock time does not exist on this date — the clocks moved forward — so it was skipped rather than shifted by an hour."
                case .refused, .none:
                    return "This date could not be booked."
                }
            }
        }
    }
}
