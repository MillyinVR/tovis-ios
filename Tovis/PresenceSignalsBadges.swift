// Presence chips on the opening claim path — "N watching now" / "N on the
// waitlist", the native counterpart of web's PresenceSignals component
// (app/(main)/offerings/[offeringId]/PresenceSignals.tsx).
import SwiftUI
import TovisKit

/// Renders only what ``PresenceDisplay`` has already judged honest. It holds no
/// threshold of its own on purpose: the rule lives in TovisKit where `swift
/// test` covers it, and a view that can't compute a count can't invent one.
///
/// Renders nothing at all when there is nothing to say. "Below threshold",
/// "Redis is down", "the poll failed" and "we haven't fetched yet" deliberately
/// look identical — none of them justifies a number, so silence is the honest
/// answer to all four. (Web returns `null` in exactly the same cases.)
struct PresenceSignalsBadges: View {
    let display: PresenceDisplay

    var body: some View {
        if !display.isEmpty {
            HStack(spacing: 8) {
                if let watching = display.watching {
                    // Accent-tinted: this is the live one.
                    BrandPill(text: "\(watching) watching now", tint: BrandColor.accent)
                }
                if let waitlisted = display.waitlisted {
                    BrandPill(text: "\(waitlisted) on the waitlist")
                }
            }
            // Web pairs its watching chip with a pulsing dot. Deliberately not
            // ported: reproducing it would mean re-rolling BrandPill's padding,
            // font and capsule to slot a subview in, and the dot carries no
            // information the copy doesn't. Cosmetic-only divergence.
        }
    }
}

#Preview("Presence chips") {
    VStack(alignment: .leading, spacing: 12) {
        PresenceSignalsBadges(display: PresenceDisplay(signals: .init(watching: 4, waitlisted: 3)))
        PresenceSignalsBadges(display: PresenceDisplay(signals: .init(watching: 4, waitlisted: 0)))
        PresenceSignalsBadges(display: PresenceDisplay(signals: .init(watching: 1, waitlisted: 2)))
        // All of these render nothing: below threshold, unknown, not fetched.
        PresenceSignalsBadges(display: PresenceDisplay(signals: .init(watching: 1, waitlisted: 0)))
        PresenceSignalsBadges(display: PresenceDisplay(signals: .init(watching: nil, waitlisted: 0)))
        PresenceSignalsBadges(display: .empty)
    }
    .padding()
    .background(BrandColor.bgPrimary)
}
