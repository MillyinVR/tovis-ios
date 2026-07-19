import Foundation
import Testing
import TovisKit
@testable import Tovis

// Where a tapped notification row goes.
//
// Both notification centers rendered every row as a tappable control but only
// navigated when the row carried a `bookingId`; every other row silently marked
// itself read and stayed put. The rows always carried the destination in `href`
// — the feed just never read it.
//
// The href templates pinned here are the ones the backend actually emits, read
// off the emit sites (there is no central href map server-side — every href is a
// literal at its own emit site, funnelled through `normInternalHref`). They are
// the contract this feature depends on: if an emitter changes shape, or
// `PushDeepLink` stops recognising a path, one of these goes red rather than the
// row quietly going dead again.

/// Decode through the real `Decodable` path rather than synthesising the struct,
/// so these exercise the wire shape the route actually returns.
private func clientNotification(href: String, bookingId: String? = nil) throws -> ClientNotification {
    let payload: [String: Any] = [
        "id": "n_1",
        "eventKey": "LOOK_LIKED",
        "title": "t",
        "body": NSNull(),
        "href": href,
        "createdAt": "2026-07-19T10:00:00.000Z",
        "updatedAt": "2026-07-19T10:00:00.000Z",
        "readAt": NSNull(),
        "bookingId": bookingId ?? NSNull(),
        "aftercareId": NSNull(),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(ClientNotification.self, from: data)
}

private func proNotification(href: String) throws -> ProNotification {
    let payload: [String: Any] = [
        "id": "n_1",
        "eventKey": "REVIEW_RECEIVED",
        "title": "t",
        "body": NSNull(),
        "href": href,
        "createdAt": "2026-07-19T10:00:00.000Z",
        "seenAt": NSNull(),
        "readAt": NSNull(),
        "bookingId": NSNull(),
        "reviewId": NSNull(),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(ProNotification.self, from: data)
}

@Suite("Client notification destinations")
struct ClientNotificationDeepLinkTests {
    // ⚠️ The regression. Every one of these was a dead tap: the row has no
    // `bookingId`, so the old `tap()` fell straight off the end after marking
    // read. They are the bulk of the non-booking feed.
    @Test("Rows with no bookingId still resolve a destination")
    func nonBookingRowsRoute() throws {
        // LOOK_LIKED / LOOK_SAVED / LOOK_COMMENTED / LOOK_COMMENT_REPLIED /
        // LOOK_MILESTONE_REACHED / LOOK_NEW_FROM_FOLLOWED_PRO /
        // SAVED_LOOK_AVAILABILITY_OPENED / SAVED_LOOK_PRICE_ALTERNATIVE
        #expect(try clientNotification(href: "/looks/look_1").deepLink?.target == .look(id: "look_1"))
        // WAITLIST_TIME_OFFERED
        #expect(try clientNotification(href: "/client/offers").deepLink?.target == .offers(accept: nil))
        // LAST_MINUTE_OPENING_AVAILABLE (priority/waitlist tier) — the recipient
        // id must survive so the offers screen can float that offer.
        #expect(
            try clientNotification(href: "/client/offers?accept=rec_1").deepLink?.target
                == .offers(accept: "rec_1")
        )
        // CLIENT_FOLLOW
        #expect(try clientNotification(href: "/client/activity").deepLink?.target == .activity)
        // REFERRAL_CONFIRMED / REFERRAL_CONVERTED
        #expect(try clientNotification(href: "/client/referrals").deepLink?.target == .referrals)
        // REFERRAL_TAP_RECEIVED
        #expect(try clientNotification(href: "/client/referrals?confirm=r_1").deepLink?.target == .referrals)
        // MESSAGE_RECEIVED
        #expect(
            try clientNotification(href: "/messages/thread/th_1").deepLink?.target == .thread(id: "th_1")
        )
    }

    // Booking rows already worked (via `bookingId`), but their hrefs must still
    // resolve — the href is the fallback when a row arrives without the id.
    @Test("Booking hrefs keep their step")
    func bookingRowsCarryStep() throws {
        // BOOKING_CONFIRMED / RESCHEDULED / CANCELLED_* / NO_SHOW_FEE_CHARGED /
        // APPOINTMENT_REMINDER
        #expect(
            try clientNotification(href: "/client/bookings/bk_1?step=overview").deepLink?.target
                == .booking(id: "bk_1", step: "overview")
        )
        // AFTERCARE_READY — note the real emitter sends the BOOKING path with a
        // step, not a standalone /client/aftercare/{id}.
        #expect(
            try clientNotification(href: "/client/bookings/bk_1?step=aftercare").deepLink?.target
                == .booking(id: "bk_1", step: "aftercare")
        )
        // CONSULTATION_PROPOSAL_SENT
        #expect(
            try clientNotification(href: "/client/bookings/bk_1?step=consult").deepLink?.target
                == .booking(id: "bk_1", step: "consult")
        )
        // REVIEW_REQUESTED — a fragment, not a query.
        #expect(
            try clientNotification(href: "/client/bookings/bk_1#review").deepLink?.target
                == .booking(id: "bk_1", step: "review")
        )
        // PAYMENT_COLLECTED / PAYMENT_ACTION_REQUIRED / PAYMENT_REFUNDED
        #expect(
            try clientNotification(href: "/client/bookings/bk_1").deepLink?.target
                == .booking(id: "bk_1", step: nil)
        )
    }

    // ⚠️ The half that keeps the fix safe. These screens are SHEETS, so routing
    // is "dismiss, then present". A nil here means the caller must leave the tap
    // as a mark-read — dismissing the notification center onto nothing would be
    // worse than the dead tap. Each of these is a real emitted href with no
    // native surface yet (see the PR notes).
    @Test("Paths with no native surface stay nil so the sheet is not dismissed")
    func unroutablePathsStayNil() throws {
        // REBOOK_CADENCE_DUE / SAVED_LOOK_CONSULT_NUDGE — `ProProfileView` exists
        // but `PushDeepLink` has no /professionals case.
        #expect(try clientNotification(href: "/professionals/pro_1").deepLink == nil)
        // LAST_MINUTE_OPENING_AVAILABLE (broadcast tier).
        #expect(try clientNotification(href: "/offerings/off_1?source=DISCOVERY").deepLink == nil)
        // Legacy rows: the column is `String @default("")`, so "" is reachable
        // and must never resolve.
        #expect(try clientNotification(href: "").deepLink == nil)
    }

    // The tag-page trap `PushDeepLink` already guards, re-pinned from this entry
    // point: the feed renders tag chips, so a /looks/tags href reaching a row
    // must not open a look called "tags".
    @Test("A tag page is not a look")
    func tagPageIsNotALook() throws {
        #expect(try clientNotification(href: "/looks/tags/balayage").deepLink == nil)
    }
}

@Suite("Pro notification destinations")
struct ProNotificationDeepLinkTests {
    @Test("Pro rows with no bookingId still resolve a destination")
    func nonBookingProRowsRoute() throws {
        #expect(try proNotification(href: "/pro/reviews").deepLink?.target == .proReviews(id: nil))
        #expect(
            try proNotification(href: "/pro/reviews#review-rv_1").deepLink?.target
                == .proReviews(id: "rv_1")
        )
        #expect(try proNotification(href: "/pro/profile").deepLink?.target == .proProfile)
        #expect(try proNotification(href: "/pro/calendar").deepLink?.target == .proCalendar)
        #expect(try proNotification(href: "/pro/membership").deepLink?.target == .membership)
        // /pro/services, /pro/locations, /pro/media/new, /pro/dashboard all fall
        // to the pro home rather than nowhere.
        #expect(try proNotification(href: "/pro/services").deepLink?.target == .proHome)
        #expect(try proNotification(href: "/pro/dashboard?month=2026-04").deepLink?.target == .proHome)
        // Shared with the client shell.
        #expect(try proNotification(href: "/messages/thread/th_1").deepLink?.target == .thread(id: "th_1"))
    }

    @Test("Pro paths with no native surface stay nil")
    func unroutableProPathsStayNil() throws {
        #expect(try proNotification(href: "").deepLink == nil)
    }
}
