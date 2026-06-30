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

    // GET /api/v1/google/places/{autocomplete,details} — inline (Google-proxy
    // shapes, decode-only; not a typed DTO in the schema).
    @Test func decodesPlaces() throws {
        let auto = """
        {"kind":"ADDRESS","predictions":[{"placeId":"p1","description":"123 Main St, Los Angeles, CA","mainText":"123 Main St","secondaryText":"Los Angeles, CA, USA","types":["street_address"],"distanceMeters":1200}]}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(PlacesAutocompleteResponse.self, from: auto)
        #expect(a.predictions.first?.placeId == "p1")
        #expect(a.predictions.first?.mainText == "123 Main St")

        let detail = """
        {"place":{"resourceName":"places/p1","placeId":"p1","name":null,"formattedAddress":"123 Main St, Los Angeles, CA 90001, USA","lat":34.0522,"lng":-118.2437,"viewport":null,"components":{"locality":"Los Angeles"},"city":"Los Angeles","state":"CA","postalCode":"90001","countryCode":"US","types":["street_address"]}}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(PlaceDetailsResponse.self, from: detail)
        #expect(d.place.lat == 34.0522)
        #expect(d.place.postalCode == "90001")
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

    // GET /api/v1/pro/session — Fixtures/proSession.json. The PRO footer's live-
    // session state machine (mirrors lib/proSession/types.ts). Envelope is spread,
    // so the payload fields sit at the top level.
    @Test func decodesProSession() throws {
        let res = try JSONDecoder().decode(ProSessionPayload.self, from: fixture("proSession"))
        #expect(res.mode == .upcoming)
        #expect(res.center.action == .start)
        #expect(res.center.href == "/pro/bookings/bk_1/session")
        let booking = try #require(res.booking)
        #expect(booking.id == "bk_1")
        #expect(booking.clientName == "Jordan Rivera")
        #expect(res.eligibleBookings == nil)
        // Unknown enum values fall back to .unknown rather than failing to decode.
        let unknown = """
        {"ok":true,"mode":"WAT","booking":null,"eligibleBookings":null,
         "targetStep":null,"center":{"label":"Start","action":"ZAP","href":null}}
        """.data(using: .utf8)!
        let u = try JSONDecoder().decode(ProSessionPayload.self, from: unknown)
        #expect(u.mode == .unknown)
        #expect(u.center.action == .unknown)
    }

    // GET /api/v1/pro/bookings/{id}/media — Fixtures/proBookingMedia.json. Session
    // before/after photos (ProBookingMediaItemDTO). Schema-validated via contract.
    @Test func decodesProBookingMedia() throws {
        let res = try JSONDecoder().decode(ProBookingMediaListResponse.self, from: fixture("proBookingMedia"))
        #expect(res.items.count == 2)
        let before = try #require(res.items.first)
        #expect(before.phase == .before)
        #expect(before.mediaType == .image)
        #expect(before.displayThumbUrl == "https://x/media_1_rt.jpg")   // prefers render thumb
        let after = res.items[1]
        #expect(after.phase == .after)
        #expect(after.caption == "fresh balayage")
        #expect(after.displayThumbUrl == "https://x/media_2_t.jpg")     // falls back when no render
    }

    // GET /api/v1/pro/bookings/{id} — Fixtures/proBookingDetail.json. Pro booking
    // detail (inline backend shape; decode-only until a ProBookingDetailDTO PR).
    @Test func decodesProBookingDetail() throws {
        let res = try JSONDecoder().decode(ProBookingDetailResponse.self, from: fixture("proBookingDetail"))
        let b = res.booking
        #expect(b.id == "bk_pro_1")
        #expect(b.status == "ACCEPTED")
        #expect(b.isAccepted)
        #expect(b.isCancellable)            // ACCEPTED is still cancellable
        #expect(!b.isTerminal)
        #expect(b.title == "Balayage")      // base item names the booking
        #expect(b.subtotalSnapshot == "220.00")
        #expect(b.client.fullName == "Jordan Rivera")
        #expect(b.serviceItems.count == 2)
        #expect(b.serviceItems.filter { $0.isAddOn }.count == 1)
        #expect(b.baseItem?.serviceId == "svc_balayage")
        #expect(b.timeZone == "America/Los_Angeles")
        // Expanded payment/timing/aftercare fields (PR #432).
        #expect(b.totalLabel == "242.00")
        #expect(b.taxAmount == "12.00")
        #expect(b.tipAmount == "10.00")
        #expect(b.discountAmount == nil)
        #expect(!b.isPaid)               // no paymentCollectedAt + no Stripe SUCCEEDED
        #expect(!b.canRefund)
        #expect(b.sessionStep == "NONE")
        #expect(b.aftercareSummary?.isSent == true)
        #expect(b.aftercareSummary?.version == 2)
    }

    // GET /api/v1/pro/bookings — Fixtures/proBookingsList.json. The native
    // bookings list (tovis-app PR #435): buckets + stats. Inline shape; decode-only.
    @Test func decodesProBookingsList() throws {
        let res = try JSONDecoder().decode(ProBookingsListResponse.self, from: fixture("proBookingsList"))
        #expect(res.scheduleTimeZone == "America/Los_Angeles")
        #expect(res.statusFilter == "ALL")
        #expect(res.stats.today == 2)
        #expect(res.stats.inSession == 1)
        #expect(res.stats.paymentDue == 1)
        #expect(res.today.count == 2)
        #expect(res.upcoming.count == 1)
        #expect(res.past.isEmpty)
        #expect(res.cancelled.count == 1)

        let first = res.today[0]
        #expect(first.id == "bk_today_1")
        #expect(first.isInProgress)
        #expect(first.statusLabel == "In progress")
        #expect(first.serviceName == "Balayage")
        #expect(first.addOnNames == ["Toner"])
        #expect(first.total == "242.00")
        #expect(first.whenLabel == "Mon, Jun 29 · 10:00 AM")
        #expect(first.needsCloseout)
        #expect(first.client.fullName == "Jordan Rivera")
        #expect(first.client.canViewClient)
        #expect(first.location.isMobile == false)
        #expect(first.location.formattedAddress == "123 Palm Ave, Encinitas, CA")

        // Mobile row + null money/contact decode cleanly.
        #expect(res.today[1].location.isMobile)
        #expect(res.today[1].client.email == nil)
        #expect(res.cancelled[0].total == nil)
        #expect(res.cancelled[0].sessionStep == nil)
    }

    // GET /api/v1/pro/aftercare — Fixtures/proAftercareList.json. The "all
    // aftercare" list (tovis-app PR #436). Inline shape; decode-only.
    @Test func decodesProAftercareList() throws {
        let res = try JSONDecoder().decode(ProAftercareListResponse.self, from: fixture("proAftercareList"))
        #expect(res.items.count == 3)

        let draft = res.items[0]
        #expect(draft.status == "draft")
        #expect(draft.clientName == "Jordan Rivera")
        #expect(draft.initials == "JR")
        #expect(draft.action == "send")
        #expect(draft.needsAction)
        #expect(draft.rebook?.kind == "recommended")
        #expect(draft.rebook?.value == "Jul 2")
        #expect(draft.ago?.verb == "saved")
        #expect(draft.media?.beforeUrl == "https://cdn.example.com/b1.jpg")

        #expect(res.items[1].status == "sent")
        #expect(res.items[1].rebook?.kind == "overdue")
        #expect(res.items[1].media?.beforeUrl == nil)

        let finished = res.items[2]
        #expect(finished.status == "finished")
        #expect(finished.action == nil)
        #expect(finished.rebook?.kind == "next")
        #expect(finished.media == nil)
    }

    // GET /api/v1/pro/bookings/[id]/consultation-services — the session flow's
    // consultation form service catalog. Inline shape; decode-only.
    @Test func decodesProConsultationServices() throws {
        let res = try JSONDecoder().decode(
            ProConsultationServicesResponse.self, from: fixture("proConsultationServices"))

        #expect(res.services.count == 2)
        #expect(res.services[0].serviceName == "Balayage")
        #expect(res.services[0].defaultPrice == 180.0)
        #expect(res.services[0].defaultDurationMinutes == 120)
        // Nullable defaults decode to nil (no crash).
        #expect(res.services[1].categoryName == nil)
        #expect(res.services[1].defaultPrice == nil)

        #expect(res.addOns.count == 1)
        #expect(res.addOns[0].isRecommended == true)
        #expect(res.addOns[0].parentOfferingId == "off_1")

        #expect(res.existingBookingItems.count == 1)
        #expect(res.existingBookingItems[0].itemType == "BASE")
    }

    // GET /api/v1/pro/bookings/[id]/aftercare — the authoring screen prefill.
    // Inline shape; decode-only.
    @Test func decodesProAftercareDetail() throws {
        let res = try JSONDecoder().decode(
            ProAftercareDetailResponse.self, from: fixture("proAftercareDetail"))

        let booking = res.booking
        #expect(booking.id == "bk_1")
        #expect(booking.locationTimeZone == "America/Los_Angeles")

        let summary = try #require(booking.aftercareSummary)
        #expect(summary.rebookMode == "RECOMMENDED_WINDOW")
        #expect(summary.version == 2)
        #expect(summary.isFinalized == false)
        #expect(summary.rebookWindowStart == "2026-07-20T07:00:00.000Z")
        #expect(summary.recommendedProducts.count == 2)

        // External product (name + url) vs catalog product (nested `product`).
        #expect(summary.recommendedProducts[0].displayName == "Olaplex No.7")
        #expect(summary.recommendedProducts[0].externalUrl == "https://example.com/olaplex-7")
        #expect(summary.recommendedProducts[1].displayName == "Purple Toning Shampoo")
        #expect(summary.recommendedProducts[1].product?.retailPrice == "28.00")
    }

    // GET /api/v1/pro/bookings/[id]/session/state — the per-booking session
    // state, incl. the consultation proof (tovis-app PR #441). Decode-only.
    @Test func decodesProSessionStateWithProof() throws {
        let res = try JSONDecoder().decode(
            ProSessionStateResponse.self, from: fixture("proSessionState"))
        let state = res.state

        #expect(state.bookingId == "bk_1")
        #expect(state.screenKey == .waitingOnClient)
        #expect(state.isConsultationApproved)

        let proof = try #require(state.consultation?.proof)
        #expect(proof.decision == "APPROVED")
        #expect(proof.decisionLabel == "Approved")
        #expect(proof.method == "REMOTE_SECURE_LINK")
        #expect(proof.methodLabel == "Remote secure link")
        #expect(proof.actedAt == "2026-06-30T17:09:30.000Z")
    }

    // GET /api/v1/pro/overview — Fixtures/proOverview.json. The pro dashboard
    // monthly analytics (tovis-app PR #437). Inline shape; decode-only.
    @Test func decodesProOverview() throws {
        let res = try JSONDecoder().decode(ProOverviewResponse.self, from: fixture("proOverview"))
        #expect(res.activeMonth.key == "2026-06")
        #expect(res.activeMonth.label == "June 2026")
        #expect(res.months.count == 3)
        #expect(res.months.last?.active == true)
        #expect(res.revenue.value == "$4,820.00")
        #expect(res.revenue.trendTone == "positive")
        #expect(res.primaryStats.count == 2)
        #expect(res.primaryStats[0].label == "Bookings")
        #expect(res.secondaryStats.count == 2)
        #expect(res.topServices.count == 2)
        #expect(res.topServices[0].name == "Balayage")
        #expect(res.topServices[0].bookings == 12)
    }

    // GET /api/v1/pro/reviews — Fixtures/proReviewsList.json. The pro reviews
    // list (tovis-app PR #438). Inline shape; decode-only.
    @Test func decodesProReviewsList() throws {
        let res = try JSONDecoder().decode(ProReviewsListResponse.self, from: fixture("proReviewsList"))
        #expect(res.items.count == 2)

        let first = res.items[0]
        #expect(first.rating == 5)
        #expect(first.headline == "Best balayage ever")
        #expect(first.clientName == "Jordan Rivera")
        #expect(first.bookingId == "bk_1")
        #expect(first.mediaTiles.count == 2)
        #expect(first.mediaTiles[0].isFeaturedInPortfolio)
        #expect(first.mediaTiles[0].services.first?.serviceName == "Balayage")
        #expect(first.mediaTiles[1].isVideo)
        #expect(first.mediaTiles[1].services.isEmpty)

        let second = res.items[1]
        #expect(second.headline == nil)
        #expect(second.bookingId == nil)
        #expect(second.mediaTiles.isEmpty)
    }

    // GET /api/v1/pro/last-minute/workspace — Fixtures/proLastMinute.json. The
    // last-minute settings workspace (tovis-app PR #439). Inline shape; decode-only.
    @Test func decodesProLastMinuteWorkspace() throws {
        let res = try JSONDecoder().decode(ProLastMinuteWorkspace.self, from: fixture("proLastMinute"))
        #expect(res.timeZone == "America/Los_Angeles")
        #expect(res.settings.enabled)
        #expect(res.settings.priorityOfferEnabled)
        #expect(res.settings.priorityOfferMinutes == 30)
        #expect(res.settings.minCollectedSubtotal == "40.00")
        #expect(res.settings.disableSun)
        #expect(res.settings.disableMon == false)
        #expect(res.settings.serviceRules.count == 2)
        #expect(res.settings.serviceRules[0].enabled)
        #expect(res.settings.serviceRules[1].minCollectedSubtotal == nil)
        #expect(res.settings.blocks.count == 1)
        #expect(res.settings.blocks[0].reason == "Holiday")
        #expect(res.offerings.count == 2)
        #expect(res.offerings[0].name == "Balayage")
        #expect(res.offerings[0].basePrice == "180.00")
    }

    // GET /api/v1/pro/profile — Fixtures/proMyProfile.json. The pro's own editable
    // profile (carries its professionalId). Inline backend shape; decode-only.
    @Test func decodesProMyProfile() throws {
        let res = try JSONDecoder().decode(ProMyProfileResponse.self, from: fixture("proMyProfile"))
        #expect(res.profile.id == "pro_1")
        #expect(res.profile.handle == "studio-lumen")
        #expect(res.profile.nameDisplay == "BUSINESS_NAME")
        #expect(res.profile.isPremium)
    }

    // GET /api/v1/pro/offerings — Fixtures/proOfferings.json. The pro's services
    // (active + inactive) for the services manager. Inline shape; decode-only.
    @Test func decodesProOfferings() throws {
        let res = try JSONDecoder().decode(ProOfferingsResponse.self, from: fixture("proOfferings"))
        #expect(res.offerings.count == 2)
        let balayage = try #require(res.offerings.first)
        #expect(balayage.isActive)
        #expect(balayage.offersInSalon && !balayage.offersMobile)
        #expect(balayage.salonPriceStartingAt == "180.00")
        #expect(balayage.displayImageUrl == "https://x/balayage.jpg")   // falls back to service default
        let blowout = res.offerings[1]
        #expect(!blowout.isActive)
        #expect(blowout.offersMobile)
        #expect(blowout.displayImageUrl == "https://x/blowout.jpg")      // custom override wins
    }

    // GET /api/v1/pro/payment-settings — Fixtures/proPaymentSettings.json. The
    // pro's payment settings (collection timing / deposits / methods / tips).
    @Test func decodesProPaymentSettings() throws {
        let res = try JSONDecoder().decode(ProPaymentSettingsResponse.self, from: fixture("proPaymentSettings"))
        let s = try #require(res.paymentSettings)
        #expect(s.collectPaymentAt == "AFTER_SERVICE")
        #expect(s.depositEnabled)
        #expect(s.depositType == "PERCENT")
        #expect(s.depositPercent == 25)
        #expect(s.depositFlatAmount == nil)
        #expect(s.acceptCash && s.acceptVenmo && !s.acceptPaypal)
        #expect(s.venmoHandle == "@studio-lumen")
        #expect(s.tipsEnabled && s.allowCustomTip)
        #expect(s.tipSuggestions?.count == 3)
        #expect(s.tipSuggestions?.first?.label == "18%")
        #expect(s.tipSuggestions?.first?.percent == 18)
    }

    // GET /api/v1/pro/payment-settings with no row yet → paymentSettings: null.
    @Test func decodesProPaymentSettingsNull() throws {
        let json = Data(#"{"ok":true,"paymentSettings":null}"#.utf8)
        let res = try JSONDecoder().decode(ProPaymentSettingsResponse.self, from: json)
        #expect(res.paymentSettings == nil)
    }

    // GET /api/v1/pro/profile/handle-available — the live vanity-handle check.
    @Test func decodesProHandleAvailability() throws {
        let taken = Data(#"{"ok":true,"handle":"tori","status":"taken","message":"That handle is taken.","suggestions":["tori1","tori-co"]}"#.utf8)
        let a = try JSONDecoder().decode(ProHandleAvailability.self, from: taken)
        #expect(a.status == "taken")
        #expect(a.isBlocking && !a.isPositive)
        #expect(a.suggestions?.count == 2)

        let ok = Data(#"{"ok":true,"handle":"tori","status":"available","message":"tori.tovis.me is available."}"#.utf8)
        let b = try JSONDecoder().decode(ProHandleAvailability.self, from: ok)
        #expect(b.isPositive && !b.isBlocking)
        #expect(b.suggestions == nil)
    }

    // GET /api/v1/pro/clients/[id]/chart — Fixtures/proClientChart.json. The
    // aggregate client chart powering the native 8-tab chart + safety strip.
    @Test func decodesProClientChart() throws {
        let chart = try JSONDecoder().decode(ProClientChart.self, from: fixture("proClientChart"))
        #expect(chart.header.fullName == "Jordan Rivera")
        #expect(chart.header.occupation == "Nurse")
        #expect(chart.header.bookingCount == 4)
        #expect(chart.alertBanner?.isEmpty == false)
        #expect(chart.doNotRebook == nil)
        #expect(chart.allergies.first?.severity == "HIGH")
        #expect(chart.allergies.first?.recordedBy == "Studio Lumen")
        #expect(chart.noteGroups.first?.notes.first?.body == "Prefers cooler tones.")
        #expect(chart.history.first?.isMine == true)
        #expect(chart.products.first?.brand == "Olaplex")
        #expect(chart.reviewsLeft.first?.rating == 5)
        #expect(chart.proFeedback.first?.title == "Punctual")
        #expect(chart.photos.first?.phase == "AFTER")
        #expect(!chart.technicalEnabled)
    }

    // GET /api/v1/pro/services/catalog — Fixtures/proServicesCatalog.json. The
    // add-service library tree + the pro's already-added offerings.
    @Test func decodesProServicesCatalog() throws {
        let res = try JSONDecoder().decode(ProServiceCatalog.self, from: fixture("proServicesCatalog"))
        #expect(res.categories.count == 1)
        let hair = try #require(res.categories.first)
        #expect(hair.services.first?.name == "Balayage")
        #expect(hair.children.first?.name == "Color")
        let toner = try #require(hair.children.first?.services.first)
        #expect(toner.isAddOnEligible)
        #expect(toner.addOnGroup == "COLOR")
        #expect(res.offerings.first?.serviceId == "svc_balayage")
    }

    // GET /api/v1/pro/offerings/{id}/add-ons — Fixtures/proAddOns.json.
    @Test func decodesProAddOns() throws {
        let res = try JSONDecoder().decode(ProAddOns.self, from: fixture("proAddOns"))
        #expect(res.eligible.count == 2)
        #expect(res.attached.count == 1)
        #expect(res.attached.first?.addOnServiceId == "svc_toner")
        #expect(res.attached.first?.isActive == true)
    }

    // GET /api/v1/pro/notifications — Fixtures/proNotifications.json. The pro
    // notification feed (distinct from the client center: priority/seenAt/reviewId).
    @Test func decodesProNotifications() throws {
        let res = try JSONDecoder().decode(ProNotificationListResponse.self, from: fixture("proNotifications"))
        #expect(res.items.count == 2)
        #expect(res.nextCursor == "cursor_abc")
        let first = try #require(res.items.first)
        #expect(first.eventKey == "BOOKING_REQUEST_CREATED")
        #expect(first.priority == "HIGH")
        #expect(first.isUnread)
        #expect(first.bookingId == "bk_1")
        let second = res.items[1]
        #expect(!second.isUnread)
        #expect(second.reviewId == "rv_9")
        #expect(second.priority == nil)
    }

    // GET /api/v1/pro/working-hours — Fixtures/proWorkingHours.json. The pro's
    // weekly hours editor source. Inline backend shape; decode-only.
    @Test func decodesProWorkingHours() throws {
        let res = try JSONDecoder().decode(ProWorkingHoursResponse.self, from: fixture("proWorkingHours"))
        #expect(res.locationType == "SALON")
        #expect(res.usedDefault == false)
        #expect(res.workingHours.mon.enabled)
        #expect(res.workingHours.mon.start == "10:00")
        #expect(!res.workingHours.sun.enabled)
        #expect(res.workingHours.thu.end == "20:00")
    }

    // GET /api/v1/pro/clients — Fixtures/proClientsDirectory.json. The visible
    // client directory (web `/pro/clients` parity). Inline shape; decode-only.
    @Test func decodesProClientsDirectory() throws {
        let res = try JSONDecoder().decode(ProClientDirectoryResponse.self, from: fixture("proClientsDirectory"))
        #expect(res.count == 2)
        #expect(res.clients.count == 2)
        let first = try #require(res.clients.first)
        #expect(first.fullName == "Jordan Rivera")
        #expect(first.canViewClient)
        #expect(first.lastBookingLabel == "Last booking: Jul 1, 2026")
        #expect(res.clients[1].email == nil)
        #expect(res.clients[1].phone == nil)
        #expect(res.clients[1].lastBookingLabel == "No bookings yet")
    }

    // GET /api/v1/pro/clients/search — Fixtures/proClientsSearch.json. The pro
    // clients directory (recent + other). Inline backend shape; decode-only.
    @Test func decodesProClientsSearch() throws {
        let res = try JSONDecoder().decode(ProClientSearchResponse.self, from: fixture("proClientsSearch"))
        #expect(res.recentClients.count == 2)
        #expect(res.otherClients.count == 1)
        let first = try #require(res.recentClients.first)
        #expect(first.fullName == "Jordan Rivera")
        #expect(first.canViewClient)
        #expect(res.recentClients[1].email == nil)
        #expect(res.otherClients.first?.canViewClient == false)
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
        #expect(booking.hasPendingRebookConfirmation == false)
        #expect(booking.rebookProposedFor == nil)
        #expect(booking.mediaUseConsent == false)
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

    // POST/PATCH/GET /api/v1/pro/calendar/blocked[/id] — Fixtures/proCalendarBlock.json.
    @Test func decodesProCalendarBlock() throws {
        let res = try JSONDecoder().decode(
            ProCalendarBlockResponse.self, from: fixture("proCalendarBlock"))
        #expect(res.block.id == "blk_1")
        #expect(res.block.note == "Lunch")
        #expect(res.block.locationId == "loc_1")
        #expect(res.block.startsAt == "2026-07-15T19:00:00.000Z")
    }

    // GET /api/v1/pro/locations — Fixtures/proLocations.json (block-create picker).
    @Test func decodesProLocations() throws {
        let res = try JSONDecoder().decode(
            ProLocationsResponse.self, from: fixture("proLocations"))
        #expect(res.locations.count == 2)
        let primary = try #require(res.locations.first { $0.isPrimary })
        #expect(primary.id == "loc_1")
        #expect(primary.isBookable == true)
        // A nameless mobile location still decodes (name is optional).
        #expect(res.locations[1].name == nil)
        #expect(res.locations[1].type == "MOBILE")
    }

    // PATCH /api/v1/pro/settings — Fixtures/proSettings.json (auto-accept bar).
    @Test func decodesProSettings() throws {
        let res = try JSONDecoder().decode(
            ProSettingsResponse.self, from: fixture("proSettings"))
        #expect(res.professionalProfile.autoAcceptBookings == true)
    }

    // The create-block body omits a nil note (synthesized encodeIfPresent).
    @Test func createBlockRequestOmitsNilNote() throws {
        let data = try JSONEncoder().encode(CreateBlockRequest(
            startsAt: "2026-07-15T19:00:00Z",
            endsAt: "2026-07-15T20:00:00Z",
            note: nil,
            locationId: "loc_1"))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"locationId\""))
        #expect(!json.contains("note"))
    }
}