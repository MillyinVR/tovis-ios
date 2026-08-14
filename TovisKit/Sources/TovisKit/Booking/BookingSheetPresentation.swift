import Foundation

/// Presentation rules for the booking sheet — the parts of `BookingSheetFrame`
/// that are decisions rather than layout: which reassurance chips a pro earns,
/// how a day's remaining supply reads, which daypart a slot belongs to, and how
/// a price or a running hold is worded.
///
/// They live here, in TovisKit, so `swift test` can pin them against the web
/// twin. Their counterparts are `lib/booking/trustSignals.ts` +
/// `AvailabilityDrawer/components/SheetCover.tsx` (chips),
/// `AvailabilityDrawer/components/DayScroller.tsx` (supply),
/// `lib/bookingTime.ts` (dayparts) and `AddOnsClient.tsx` (prices, hold label).
public enum BookingSheetPresentation {

    // MARK: - Dayparts

    /// Morning · Afternoon · Evening, in the order the tabs are drawn. Boundaries
    /// mirror web's `dayPeriodOfHour`: noon and 5pm, in the LOCATION's zone.
    public enum DayPeriod: String, CaseIterable, Sendable {
        case morning = "MORNING"
        case afternoon = "AFTERNOON"
        case evening = "EVENING"

        public var label: String {
            switch self {
            case .morning: return "Morning"
            case .afternoon: return "Afternoon"
            case .evening: return "Evening"
            }
        }

        /// The copy shown when this daypart is empty but the day is not.
        public var emptyCopy: String {
            switch self {
            case .morning: return "No morning times for this day."
            case .afternoon: return "No afternoon times for this day."
            case .evening: return "No evening times for this day."
            }
        }

        public static func of(hour: Int) -> DayPeriod {
            if hour < 12 { return .morning }
            if hour < 17 { return .afternoon }
            return .evening
        }
    }

    /// Bucket a day's slots into dayparts, resolved in `timeZone` — the booking
    /// location's zone, never the device's. A slot that can't be parsed is
    /// dropped rather than filed under the wrong tab.
    public static func groupSlotsByPeriod(
        _ slots: [String],
        timeZone: String
    ) -> [DayPeriod: [String]] {
        var grouped: [DayPeriod: [String]] = [.morning: [], .afternoon: [], .evening: []]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current

        for iso in slots {
            guard let date = Wire.date(iso) else { continue }
            let hour = calendar.component(.hour, from: date)
            grouped[DayPeriod.of(hour: hour), default: []].append(iso)
        }

        return grouped
    }

    /// The daypart to open on: keep `preferred` when it has slots, else the first
    /// one (morning → evening) that does. Returns `preferred` when the whole day
    /// is empty, so the tab selection stays stable rather than jumping.
    public static func firstNonEmptyPeriod(
        _ grouped: [DayPeriod: [String]],
        preferred: DayPeriod
    ) -> DayPeriod {
        if !(grouped[preferred] ?? []).isEmpty { return preferred }
        for period in DayPeriod.allCases where !(grouped[period] ?? []).isEmpty {
            return period
        }
        return preferred
    }

    // MARK: - Day supply

    /// How much of a day is left — "6 open", or "2 left" once it is down to the
    /// last couple of starts, which is the honest scarcity signal the frame asks
    /// for.
    ///
    /// ⚠️ "Full" is currently unreachable from `/availability/bootstrap`: the
    /// route skips any day whose slot count is zero (`if (slotCount <= 0)
    /// continue`), so a full day is absent from `availableDays` rather than
    /// present with a zero. The branch is kept because the function has to be
    /// total, not because the server sends that shape today.
    public static func daySupplyLabel(slotCount: Int) -> String {
        if slotCount <= 0 { return "Full" }
        if slotCount <= 2 { return "\(slotCount) left" }
        return "\(slotCount) open"
    }

    /// True while a day is down to its last couple of starts — the label is worth
    /// drawing attention to rather than stating.
    public static func daySupplyIsScarce(slotCount: Int) -> Bool {
        slotCount > 0 && slotCount <= 2
    }

    // MARK: - Trust chips

    public struct TrustChip: Equatable, Sendable, Identifiable {
        public let id: String
        public let text: String
        /// Accent-toned rather than muted — reserved for the verification chip.
        public let isAccent: Bool
    }

    /// The reassurance row under the service line.
    ///
    /// Every chip is omitted when its signal is unknown rather than rendered as
    /// a zero or a placeholder, so the row can legitimately come out with only
    /// the cancellation chip in it (a brand-new pro with no reviews and no
    /// completed bookings) — which is the honest result. Mirrors web's `TrustRow`
    /// chip-for-chip, including the order.
    public static func trustChips(_ trust: AvailabilityTrust?) -> [TrustChip] {
        guard let trust else { return [] }

        var chips: [TrustChip] = []

        if trust.verified {
            chips.append(TrustChip(id: "verified", text: "✓ Verified pro", isAccent: true))
        }

        if let completed = trust.completedBookings {
            chips.append(
                TrustChip(id: "booked", text: bookedCountLabel(completed), isAccent: false)
            )
        }

        // A pro who charges no late-cancel fee has no window to state — cancelling
        // is simply free, which is a stronger claim, not a missing one.
        if let hours = trust.freeCancellationHours {
            chips.append(TrustChip(id: "cancel", text: "Free cancel \(hours)h", isAccent: false))
        } else {
            chips.append(TrustChip(id: "cancel", text: "Free cancellation", isAccent: false))
        }

        return chips
    }

    /// "412 booked" / "1.2K booked" — exact below a thousand, because "0.9K" is a
    /// worse read than "912". Delegates to `CompactCount`, the app's one
    /// abbreviation rule, rather than rolling a fifth copy of it.
    public static func bookedCountLabel(_ count: Int) -> String {
        "\(CompactCount.label(count)) booked"
    }

    /// "4.8★" — the rating beside the pro's name, one decimal like web.
    public static func ratingLabel(_ rating: AvailabilityTrustRating?) -> String? {
        guard let rating else { return nil }
        return String(format: "%.1f★", rating.average)
    }

    // MARK: - Prices

    /// Prices are STARTING prices — never a bare figure. "From $30".
    ///
    /// Add-on prices arrive as a bare decimal string ("30.00"); the pro sets the
    /// final one, exactly as with the service itself, so the add-on rows carry
    /// the same "From" the sheet header does. Returns nil for an unusable value
    /// rather than inventing a "$0". The wording itself lives in
    /// `StartingPrice`, which is what every other price surface uses too.
    public static func addOnPriceLabel(_ raw: String?) -> String? {
        StartingPrice.labelFromAmount(raw)
    }

    // MARK: - Hold countdown

    /// "04:58" — the sheet's own countdown, mm:ss like web's `formatMmSs`.
    public static func holdCountdownLabel(secondsRemaining: Int) -> String {
        let clamped = max(0, secondsRemaining)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Under two minutes left — web's `URGENT_THRESHOLD_MS`.
    public static func holdIsUrgent(secondsRemaining: Int) -> Bool {
        secondsRemaining > 0 && secondsRemaining <= 120
    }

    /// "Hold: 5m" / "Hold: 45s" / "Hold expired" — the compact form the add-ons
    /// step's context strip carries, where the countdown is a reminder rather
    /// than the subject.
    public static func holdStripLabel(secondsRemaining: Int) -> String {
        if secondsRemaining <= 0 { return "Hold expired" }
        if secondsRemaining < 60 { return "Hold: \(secondsRemaining)s" }
        return "Hold: \(Int(ceil(Double(secondsRemaining) / 60)))m"
    }
}
