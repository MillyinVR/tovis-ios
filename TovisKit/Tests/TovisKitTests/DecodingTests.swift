import Foundation
import Testing
@testable import TovisKit

// Verifies our Swift wire models decode the EXACT JSON the backend emits.
//
// The big endpoint fixtures live in Fixtures/*.json and are the SINGLE source of
// wire-shape truth: decoded here AND validated against the backend's generated
// schema by scripts/contract/validate-fixtures.mjs. So a backend DTO change
// fails loudly in one of those two places instead of silently at runtime.
// Small, stable shapes (auth/refresh/error) stay inline.

enum FixtureError: Error { case missing(String) }

/// Load a Fixtures/<name>.json resource bundled with the test target.
func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json")
        ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    guard let url else { throw FixtureError.missing(name) }
    return try Data(contentsOf: url)
}

@Suite struct DecodingTests {
    @Test func decodesLoginResponse() throws {
        let json = """
        {
          "ok": true,
          "user": { "id": "usr_1", "email": "a@b.com", "role": "CLIENT" },
          "token": "jwt.abc.def",
          "nextUrl": "/client",
          "isPhoneVerified": true,
          "isEmailVerified": false,
          "isFullyVerified": false
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(LoginResponse.self, from: json)
        #expect(res.token == "jwt.abc.def")
        #expect(res.user.role == .client)
        #expect(res.isFullyVerified == false)
        #expect(res.nextUrl == "/client")
    }

    @Test func unknownRoleFallsBack() throws {
        let json = #"{ "id": "x", "email": "e", "role": "WIZARD" }"#.data(using: .utf8)!
        let user = try JSONDecoder().decode(AuthUser.self, from: json)
        #expect(user.role == .unknown)
    }

    @Test func decodesRefreshResponse() throws {
        let json = #"{ "token": "new.jwt" }"#.data(using: .utf8)!
        let res = try JSONDecoder().decode(RefreshResponse.self, from: json)
        #expect(res.token == "new.jwt")
    }

    @Test func decodesErrorBody() throws {
        let json = #"{ "ok": false, "error": "Invalid email or password", "code": "INVALID_CREDENTIALS" }"#.data(using: .utf8)!
        let body = try JSONDecoder().decode(APIErrorBody.self, from: json)
        #expect(body.error == "Invalid email or password")
        #expect(body.code == "INVALID_CREDENTIALS")
    }

    // GET /api/v1/client/home — Fixtures/clientHome.json (also schema-validated).
    @Test func decodesClientHome() throws {
        let res = try JSONDecoder().decode(ClientHomeResponse.self, from: fixture("clientHome"))
        let home = res.home
        #expect(home.upcomingCount == 2)
        #expect(home.upcoming?.service?.name == "Balayage")
        #expect(home.upcoming?.resolvedTimeZone == "America/Los_Angeles")

        if case let .pendingConsultation(booking) = home.action {
            #expect(booking.id == "bk_2")
        } else {
            Issue.record("expected a pending-consultation action")
        }

        // Solo pro with no businessName falls back to the handle.
        #expect(home.invites.first?.opening.professional.displayName == "@alex")
        // Invite opening derives its title + starting price from services.
        #expect(home.invites.first?.opening.title == "Blowout")
        #expect(home.invites.first?.opening.startingPrice == "60.00")
        #expect(home.waitlists.first?.service?.name == "Cut")
        #expect(home.favoritePros.first?.professional?.displayName == "Gloss")
        #expect(home.favoriteServices.first?.service?.minPrice == "45.00")
        #expect(home.favoriteServices.first?.service?.category?.name == "Nails")
        #expect(home.viralLive.first?.fanOutCount == 12)
        // Pending viral carries its review status + derived platform.
        #expect(home.viralPending.first?.status == "IN_REVIEW")
        #expect(home.viralPending.first?.platform == "TikTok")

        // The pending-consultation action surfaces the proposed plan.
        if case let .pendingConsultation(b) = home.action {
            #expect(b.consultationApproval?.proposedTotal == "160.00")
            #expect(b.consultationApproval?.notes == "Adds a gloss.")
        }
    }

    // GET /api/v1/me — Fixtures/clientMe.json (also schema-validated).
    @Test func decodesClientMe() throws {
        let res = try JSONDecoder().decode(ClientMeResponse.self, from: fixture("clientMe"))
        let me = res.me
        #expect(me.profile.handle == "amara")
        #expect(me.profile.isPublicProfile == true)
        #expect(me.counts.followers == 12)
        #expect(me.counts.booked == 3)
        // Board preview pulls the look-post primary media thumb.
        #expect(me.boards.first?.previewImageUrls.first == "https://cdn.example.com/lp_1_thumb.jpg")
        // Following resolves the pro's public display name (BUSINESS_NAME mode).
        #expect(me.following.items.first?.professional.displayName == "Studio Lux")
        #expect(me.following.items.first?.professional.subtitle == "HAIRSTYLIST · Los Angeles")
        #expect(me.myLooks.first?.isPublic == true)
        #expect(me.creator.isCreator == true)
        #expect(me.creator.remixes.first?.who == "Maya")
        #expect(me.activityUnreadCount == 2)
    }

    // GET /api/v1/messages/threads — Fixtures/messagesThreads.json (schema-validated).
    @Test func decodesMessageThreads() throws {
        let res = try JSONDecoder().decode(MessageThreadsResponse.self, from: fixture("messagesThreads"))
        let thread = try #require(res.threads.first)
        #expect(thread.professional.displayName == "Plume Studio")
        #expect(thread.lastMessagePreview == "See you at 2!")
        // lastMessageAt (18:30) is newer than my lastReadAt (18:00) → unread.
        #expect(thread.isUnread == true)
    }

    // GET /api/v1/messages/threads/{id} — Fixtures/messageThread.json (schema-validated).
    @Test func decodesMessageThread() throws {
        let res = try JSONDecoder().decode(MessageThreadPageResponse.self, from: fixture("messageThread"))
        #expect(res.messages.count == 2)
        #expect(res.messages.first?.senderUserId == "usr_pro")
        #expect(res.messages.last?.attachments.first?.mediaType == "IMAGE")
        #expect(res.hasMore == false)
    }

    // GET /api/v1/search — Fixtures/search.json (schema-validated, both tabs).
    @Test func decodesSearch() throws {
        let res = try JSONDecoder().decode(SearchResponse.self, from: fixture("search"))
        let pro = try #require(res.pros.first)
        #expect(pro.displayName == "Plume Studio")
        #expect(pro.ratingAvg == 4.8)
        #expect(pro.minPrice == 65)
        #expect(pro.supportsMobile == true)
        #expect(res.services.first?.categoryName == "Hair")
    }

    // GET /api/v1/availability/bootstrap + /day — schema-validated fixtures.
    @Test func decodesAvailability() throws {
        let boot = try JSONDecoder().decode(AvailabilityBootstrap.self, from: fixture("availabilityBootstrap"))
        #expect(boot.timeZone == "America/Los_Angeles")
        #expect(boot.request.locationId.isEmpty == false)
        #expect(boot.offering?.salonDurationMinutes == 90)

        let day = try JSONDecoder().decode(AvailabilityDay.self, from: fixture("availabilityDay"))
        #expect(day.slots.isEmpty == false) // 2026-07-15 has openings for this pro
    }

    // POST /api/v1/holds + /bookings/finalize — small, stable shapes (inline).
    @Test func decodesHoldAndFinalize() throws {
        let hold = """
        {"hold":{"id":"hold_1","expiresAt":"2026-07-15T17:05:00.000Z","scheduledFor":"2026-07-15T17:00:00.000Z","locationType":"SALON","locationId":"loc_1","clientAddressId":null,"clientAddressSnapshot":null},"meta":{"mutated":true,"noOp":false}}
        """.data(using: .utf8)!
        let h = try JSONDecoder().decode(CreateHoldResponse.self, from: hold)
        #expect(h.hold.id == "hold_1")
        #expect(h.hold.locationType == "SALON")

        let booking = """
        {"ok":true,"booking":{"id":"bk_1","status":"PENDING","scheduledFor":"2026-07-15T17:00:00.000Z","professionalId":"pro_1"},"meta":{"mutated":true,"noOp":false}}
        """.data(using: .utf8)!
        let b = try JSONDecoder().decode(FinalizeBookingResponse.self, from: booking)
        #expect(b.booking.status == "PENDING")
    }

    // GET /api/v1/client/addresses — Fixtures/clientAddresses.json (schema-validated).
    @Test func decodesClientAddresses() throws {
        let res = try JSONDecoder().decode(ClientAddressesResponse.self, from: fixture("clientAddresses"))
        #expect(res.addresses.count == 2)
        let service = try #require(res.addresses.first)
        #expect(service.isServiceAddress)
        #expect(service.isDefault)
        #expect(service.displayLine == "Home")           // label preferred
        #expect(service.detailLine?.contains("123 Main St") == true)
        #expect(res.addresses[1].isServiceAddress == false) // SEARCH_AREA
        #expect(res.addresses[1].lat == 34.0195)
    }

    // GET /api/v1/offerings/add-ons — Fixtures/offeringAddOns.json. No schema
    // entry yet (the backend route isn't a typed DTO), so this is decode-only.
    @Test func decodesOfferingAddOns() throws {
        let res = try JSONDecoder().decode(OfferingAddOnsResponse.self, from: fixture("offeringAddOns"))
        #expect(res.addOns.count == 2)
        let first = try #require(res.addOns.first)
        #expect(first.id == "addon_link_1")       // link id (→ finalize addOnIds)
        #expect(first.serviceId == "svc_toner")
        #expect(first.minutes == 30)
        #expect(first.isRecommended)
        #expect(res.addOns[1].group == nil)        // nullable group decodes
    }

    // GET /api/v1/client/bookings — Fixtures/clientBookings.json (schema-validated).
    @Test func decodesClientBookings() throws {
        let res = try JSONDecoder().decode(ClientBookingsResponse.self, from: fixture("clientBookings"))
        let b = res.buckets
        #expect(b.upcoming.count == 1)
        let booking = try #require(b.upcoming.first)
        #expect(booking.display.title == "Balayage + Toner")
        #expect(booking.items.filter { $0.isAddOn }.count == 1)
        #expect(booking.checkout.totalAmount == "120.00")
        #expect(booking.checkout.depositStatus == "PENDING")
        #expect(booking.checkout.depositAmount == "25.00")
        // REAL_NAME mode → first + last name.
        #expect(booking.professional?.displayName == "Dana Lee")
        #expect(b.waitlist.first?.professional?.displayName == "Snip")
        #expect(b.waitlist.first?.service?.name == "Cut")
    }

    // The consultation decision body must use the backend's exact action verbs.
    @Test func consultationDecisionEncodesActionVerb() throws {
        #expect(ConsultationDecision.approve.wire == "APPROVE")
        #expect(ConsultationDecision.reject.wire == "REJECT")

        let data = try JSONEncoder().encode(ConsultationDecisionRequest(action: ConsultationDecision.approve.wire))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"action":"APPROVE"}"#)
    }

    // GET /api/v1/professionals/{id} — Fixtures/proProfile.json (schema-validated).
    @Test func decodesProProfile() throws {
        let res = try JSONDecoder().decode(ProProfileResponse.self, from: fixture("proProfile"))
        let p = res.professional
        #expect(p.header.displayName == "Dana Lee")
        #expect(p.header.isLicenseVerified == true)
        #expect(p.offerings.first?.pricingLines.count == 2)
        #expect(p.portfolioTiles.first?.displayUrl == "https://x/1t.jpg")
        #expect(p.reviews.first?.rating == 5)
        #expect(p.stats.averageRatingLabel == "4.9")
    }

    // POST/DELETE /api/v1/professionals/{id}/favorite → { ok, favorited, count }.
    @Test func decodesFavoriteResult() throws {
        let json = #"{ "ok": true, "favorited": true, "count": 46 }"#.data(using: .utf8)!
        let res = try JSONDecoder().decode(FavoriteResult.self, from: json)
        #expect(res.favorited == true)
        #expect(res.count == 46)
    }

    // GET /api/v1/looks — Fixtures/looksFeed.json (schema-validated, both author kinds).
    @Test func decodesLooksFeed() throws {
        let res = try JSONDecoder().decode(LooksFeedResponse.self, from: fixture("looksFeed"))
        #expect(res.items.count == 2)
        #expect(res.nextCursor != nil)

        let pro = try #require(res.items.first)
        #expect(pro.professional?.displayName == "Studio Lumière") // BUSINESS_NAME mode
        #expect(pro.count.likes == 342)
        #expect(pro.priceLabel == "$220")
        #expect(pro.viewerLiked == false)

        let client = res.items[1]
        #expect(client.professional == nil)
        #expect(client.clientAuthor?.handleLabel == "@noellestyles")
        #expect(client.thumbUrl == nil)
        #expect(client.viewerSaved == true)
    }

    // GET /api/v1/search/pros — Fixtures/searchPros.json (schema-validated).
    @Test func decodesSearchPros() throws {
        let res = try JSONDecoder().decode(SearchProsResponse.self, from: fixture("searchPros"))
        #expect(res.items.count == 2)
        #expect(res.nextCursor != nil)
        let pro = try #require(res.items.first)
        #expect(pro.displayName == "Studio Lumière")
        #expect(pro.distanceMiles == 2.3)
        #expect(pro.supportsMobile == true)
        #expect(pro.mapLocation?.lat == 34.05)
        #expect(pro.mapLocation?.cityState == "Los Angeles, CA")
        // Pro with no location still decodes (optionals).
        #expect(res.items[1].mapLocation == nil)
    }

    // GET /api/v1/client/notifications — Fixtures/clientNotifications.json (schema-validated).
    @Test func decodesClientNotifications() throws {
        let res = try JSONDecoder().decode(
            ClientNotificationListResponse.self, from: fixture("clientNotifications"))
        #expect(res.items.count == 2)
        #expect(res.nextCursor == "ntf_2")

        let unread = try #require(res.items.first)
        #expect(unread.eventKey == "BOOKING_CONFIRMED")
        #expect(unread.bookingId == "bk_1")
        #expect(unread.isUnread == true) // readAt == null

        let read = res.items[1]
        #expect(read.aftercareId == "ac_1")
        #expect(read.bookingId == nil)
        #expect(read.isUnread == false) // readAt set
    }

    // GET /api/v1/client/notification-preferences — Fixtures/notificationPreferences.json.
    @Test func decodesNotificationPreferences() throws {
        let res = try JSONDecoder().decode(
            NotificationPreferences.self, from: fixture("notificationPreferences"))
        #expect(res.categories.count == 2)
        #expect(res.categories.first?.key == "BOOKINGS")
        #expect(res.categories.first?.events.first?.supportedChannels == ["IN_APP", "SMS", "EMAIL"])
        // PAYMENT_COLLECTED is email-locked (critical event the engine always emails).
        let payments = try #require(res.categories.first { $0.key == "PAYMENTS" })
        #expect(payments.events.first?.emailLocked == true)
        // Effective per-event channel state is keyed by event key.
        #expect(res.events["AFTERCARE_READY"]?.smsEnabled == false)
        #expect(res.quietHours.enabled == true)
        #expect(res.quietHours.startMinutes == 1320)
    }

    // The mark-read body omits nil selectors (so the route gets only what we mean).
    @Test func markReadRequestOmitsNilSelectors() throws {
        let data = try JSONEncoder().encode(
            MarkNotificationsReadRequest(ids: ["ntf_1"], eventKeys: nil, before: nil))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"ids\""))
        #expect(!json.contains("eventKeys"))
        #expect(!json.contains("before"))
    }

    // GET /api/v1/looks/{id}/comments — Fixtures/looksComments.json (schema-validated).
    @Test func decodesLooksComments() throws {
        let res = try JSONDecoder().decode(LooksCommentsListResponse.self, from: fixture("looksComments"))
        #expect(res.commentsCount == 2)
        let top = try #require(res.comments.first)
        #expect(top.isReply == false)
        #expect(top.replyCount == 1)
        #expect(top.viewerCanDelete == false)
        let reply = res.comments[1]
        #expect(reply.isReply == true)
        #expect(reply.parentCommentId == "cmt_1")
        #expect(reply.viewerCanDelete == true)
    }
}