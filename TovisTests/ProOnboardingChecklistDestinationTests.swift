import Testing
import TovisKit
@testable import Tovis

/// The onboarding checklist row is the ONLY instantiation of `ProVerificationView`
/// in the entire app. So "which blocker resolves to `.verification`" is not a copy
/// question — it is the whole question of whether a pro can reach the screen that
/// unblocks them.
///
/// 🔴 This suite exists because that door was shut for twenty days and nothing
/// went red. Web #997 ("a verified licence is a badge, not a gate") collapsed
/// VERIFICATION_NOT_APPROVED + VERIFICATION_NOT_BROADLY_DISCOVERABLE into
/// VERIFICATION_BARRED. This app still pinned the two dead strings, so the
/// decoder's `.unknown` fallback caught them — a row reading "Finish an
/// outstanding setup step." with NO destination. A pro who was rejected or asked
/// for more info had no way in, and a pro whose licence was about to expire had
/// one only after it already had.
@Suite struct ProOnboardingChecklistDestinationTests {

    /// The regression itself, stated as the string on the wire.
    @Test func aBarredProIsSentToVerification() {
        let item = checklistItem(for: .verificationBarred)

        #expect(item.id == "VERIFICATION_BARRED")
        #expect(item.fix == .verification)
    }

    /// Verbatim from web's PRO_BLOCKER_COPY (lib/pro/readiness/blockerCopy.ts).
    /// #997 rewrote this copy on purpose: the blocker now fires ONLY on an
    /// admin's active refusal, so "finish verification" would be telling a
    /// rejected pro to do something they already did.
    @Test func theBarredRowReadsWhatWebReads() {
        #expect(
            checklistItem(for: .verificationBarred).label
                == "Your verification needs attention before you can take bookings."
        )
    }

    /// Both verification-family blockers must reach the screen — an expired
    /// licence was, until this change, the app's only surviving route to it.
    @Test func bothVerificationBlockersReachTheScreen() {
        #expect(checklistItem(for: .verificationBarred).fix == .verification)
        #expect(checklistItem(for: .licenseExpired).fix == .verification)
    }

    /// Every blocker the server can send resolves to a page. `.unknown` is the
    /// only destination-less row, and it exists to survive a blocker the app has
    /// not shipped support for yet — not to absorb one it was supposed to know.
    @Test func everyKnownBlockerHasSomewhereToGo() {
        let known: [ProReadinessBlocker] = [
            .noActiveOffering,
            .noBookableLocation,
            .salonMissingAddress,
            .mobileMissingBaseConfig,
            .locationMissingTimezone,
            .locationMissingWorkingHours,
            .locationMissingGeo,
            .offeringMissingSalonPriceOrDuration,
            .offeringMissingMobilePriceOrDuration,
            .stripeNotReady,
            .verificationBarred,
            .licenseExpired,
        ]

        for blocker in known {
            #expect(checklistItem(for: blocker).fix != nil, "\(blocker.rawValue) has no destination")
            #expect(checklistItem(for: blocker).label.isEmpty == false)
        }

        #expect(checklistItem(for: .unknown).fix == nil)
    }

    /// The row key. `ForEach` is keyed on it, so two blockers sharing an id would
    /// silently drop a row from the checklist.
    @Test func everyRowIsKeyedOnTheWireString() {
        #expect(checklistItem(for: .stripeNotReady).id == "STRIPE_NOT_READY")
        #expect(checklistItem(for: .licenseExpired).id == "LICENSE_EXPIRED")
        #expect(checklistItem(for: .unknown).id == "unknown")
    }
}
