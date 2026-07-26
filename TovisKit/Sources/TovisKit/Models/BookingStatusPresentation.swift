import Foundation

/// THE canonical presentation of a booking status on iOS — the mirror of web's
/// `lib/booking/statusLabel.ts` (B10).
///
/// Before this existed, every client-facing screen rendered `status.capitalized`
/// straight off the wire. Measured, not assumed (`swift` run, 2026-07-26):
///
///     "IN_PROGRESS".capitalized == "In_Progress"
///     "NO_SHOW".capitalized     == "No_Show"
///
/// …so a client whose session was under way read **"In_Progress"** in their own
/// app, and a no-show read "No_Show". The pro detail screen had already grown a
/// private table with the right words; the client screens never did.
///
/// Keep this table equal to `BOOKING_STATUS_LABELS` on web. The pro bookings
/// LIST does not use it — that screen renders the server-computed `statusLabel`
/// field, which is produced by the same web table and pinned by the contract
/// fixture, so the two can only drift here.
public enum BookingStatusPresentation {

    /// Semantic tone for a status chip. UI-free on purpose: `TovisKit` has no
    /// `Color`, so the app maps these to `BrandColor` in one place.
    public enum Tone: String, Sendable, Equatable {
        /// Awaiting the pro's decision — provisional.
        case pending
        /// Confirmed or under way.
        case active
        /// Finished successfully.
        case done
        /// Cancelled or missed.
        case ended
        /// Anything the app does not recognise.
        case unknown
    }

    /// Normalized wire status, or "" for nil/blank.
    private static func normalize(_ status: String?) -> String {
        (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// The word for a lifecycle state, sentence case — the same word web shows.
    ///
    /// ACCEPTED reads "Confirmed" (Tori's call, 2026-07-26). An unrecognized
    /// value is humanized rather than passed through, so no screen can print an
    /// enum: "SOMETHING_ELSE" → "Something else", never "Something_Else".
    public static func label(_ status: String?) -> String {
        switch normalize(status) {
        case "PENDING": return "Pending"
        case "ACCEPTED": return "Confirmed"
        case "IN_PROGRESS": return "In progress"
        case "COMPLETED": return "Completed"
        case "CANCELLED": return "Cancelled"
        case "NO_SHOW": return "No-show"
        default: return humanize(normalize(status))
        }
    }

    /// Tone for a status chip. IN_PROGRESS and NO_SHOW both used to fall to the
    /// app's `default` arm and render in muted grey — the same grey the pro's
    /// own blocked time uses — so a missed appointment looked like a footnote.
    ///
    /// Booking statuses only. The calendar's pseudo-statuses (`HELD`, and the
    /// `CONSULTATION` session step) are NOT booking states and keep their arms
    /// in the app's `statusTone`, which delegates here for everything else —
    /// folding `HELD` in would have silently dropped B5's gold hold tint.
    public static func tone(_ status: String?) -> Tone {
        switch normalize(status) {
        case "PENDING": return .pending
        case "ACCEPTED", "CONFIRMED", "IN_PROGRESS": return .active
        case "COMPLETED": return .done
        case "CANCELLED", "NO_SHOW", "DECLINED", "EXPIRED": return .ended
        default: return .unknown
        }
    }

    private static func humanize(_ normalized: String) -> String {
        let words = normalized.split(separator: "_").map(String.init)
        guard let first = words.first, !first.isEmpty else { return "" }
        let head = first.prefix(1).uppercased() + first.dropFirst().lowercased()
        return ([head] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    }
}
