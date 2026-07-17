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

    @Test func decodesTechnicalRecord() throws {
        // GET /pro/clients/{id}/technical — a formula, a full-scope consent (notes
        // travel), a safety-scope patch test (notes redacted, byName present), and
        // the photo-release status.
        let json = """
        {
          "formula": [
            {
              "id": "fm_1", "when": "2026-07-01T17:00:00.000Z",
              "timeZone": "America/Los_Angeles", "serviceName": "Balayage",
              "brand": "Wella", "developer": "20 vol", "ratio": "1:1",
              "processingTimeMinutes": 35, "resultNotes": "Lifted to level 8"
            }
          ],
          "consents": [
            {
              "id": "cn_full", "scope": "full", "kind": "SERVICE_WAIVER",
              "when": "2026-06-01T00:00:00.000Z", "timeZone": null,
              "serviceScope": "Color", "signedAt": "2026-06-01T00:00:00.000Z",
              "proofMethod": "IN_PERSON", "proofRef": "paper-12",
              "patchTestResult": null, "validUntil": null,
              "notes": "Signed on paper", "byName": null
            },
            {
              "id": "cn_safety", "scope": "safety", "kind": "PATCH_TEST",
              "when": "2026-06-10T00:00:00.000Z", "timeZone": null,
              "serviceScope": null, "signedAt": null, "proofMethod": null,
              "proofRef": null, "patchTestResult": "PASS",
              "validUntil": "2026-12-10T00:00:00.000Z", "notes": null,
              "byName": "Glow Studio"
            }
          ],
          "photoReleaseStatus": "GRANTED"
        }
        """.data(using: .utf8)!

        let rec = try JSONDecoder().decode(ProClientTechnicalRecord.self, from: json)
        #expect(rec.photoReleaseStatus == "GRANTED")
        #expect(rec.formula.count == 1)
        #expect(rec.formula[0].resultNotes == "Lifted to level 8")
        #expect(rec.formula[0].processingTimeMinutes == 35)

        let full = try #require(rec.consents.first { $0.id == "cn_full" })
        #expect(full.scope == "full")
        #expect(full.notes == "Signed on paper")
        #expect(full.proofRef == "paper-12")

        let safety = try #require(rec.consents.first { $0.id == "cn_safety" })
        #expect(safety.scope == "safety")
        #expect(safety.notes == nil)
        #expect(safety.patchTestResult == "PASS")
        #expect(safety.byName == "Glow Studio")
    }

    @Test func decodesPublicClientProfile() throws {
        // GET /pro/clients/{id}/public-profile — the client's public creator
        // profile the pro sees behind the `view=public` toggle.
        let json = """
        {
          "handle": "ava",
          "displayName": "@ava",
          "avatarUrl": "https://cdn/a.jpg",
          "bio": "Balayage lover",
          "counts": { "followers": 12, "following": 3, "looks": 2 },
          "looks": [
            { "id": "lk_1", "name": "Sunlit balayage", "imageUrl": "https://cdn/1.jpg", "saveCount": 8, "href": "/looks/lk_1" },
            { "id": "lk_2", "name": "Copper melt", "imageUrl": null, "saveCount": 0, "href": "/looks/lk_2" }
          ],
          "viewer": { "isOwn": false, "following": false }
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ProClientPublicProfile.self, from: json)
        #expect(profile.handle == "ava")
        #expect(profile.displayName == "@ava")
        #expect(profile.bio == "Balayage lover")
        #expect(profile.counts.followers == 12)
        #expect(profile.counts.looks == 2)
        #expect(profile.looks.count == 2)
        #expect(profile.looks[0].saveCount == 8)
        #expect(profile.looks[1].imageUrl == nil)
        #expect(profile.viewer.isOwn == false)
    }

    @Test func publicClientProfileToleratesMissingFields() throws {
        // Forward-compat: an older/not-yet-deployed backend that omits optional
        // keys still decodes (displayName defaults to "@handle", collections empty).
        let json = """
        { "handle": "sky", "counts": { "followers": 4 } }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ProClientPublicProfile.self, from: json)
        #expect(profile.handle == "sky")
        #expect(profile.displayName == "@sky")
        #expect(profile.bio == nil)
        #expect(profile.avatarUrl == nil)
        #expect(profile.counts.followers == 4)
        #expect(profile.counts.following == 0)
        #expect(profile.looks.isEmpty)
        #expect(profile.viewer.isOwn == false)
    }

    @Test func unknownRoleFallsBack() throws {
        let json = #"{ "id": "x", "email": "e", "role": "WIZARD" }"#.data(using: .utf8)!
        let user = try JSONDecoder().decode(AuthUser.self, from: json)
        #expect(user.role == .unknown)
    }

    @Test func decodesRegisterResponse() throws {
        // Mirrors AuthRegisterResponseDTO (lib/dto/auth.ts). The pro-only license
        // flags are present on the wire but intentionally absent from the Swift
        // model — decoding must skip them without error.
        let json = """
        {
          "user": { "id": "usr_9", "email": "new@b.com", "role": "CLIENT" },
          "token": "verification.jwt.token",
          "nextUrl": null,
          "requiresPhoneVerification": true,
          "phoneVerificationSent": "pending",
          "phoneVerificationErrorCode": null,
          "requiresEmailVerification": true,
          "isPhoneVerified": false,
          "isEmailVerified": false,
          "isFullyVerified": false,
          "emailVerificationSent": "pending",
          "needsManualLicenseUpload": false,
          "manualLicensePendingReview": false
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(RegisterResponse.self, from: json)
        #expect(res.token == "verification.jwt.token")
        #expect(res.user.role == .client)
        #expect(res.requiresPhoneVerification == true)
        #expect(res.isFullyVerified == false)
        #expect(res.nextUrl == nil)
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

    // GET /api/v1/client/referrals/invite-link — Fixtures/clientInviteLink.json
    // (schema-validated). Flat envelope: the DTO fields sit beside `ok`.
    @Test func decodesClientInviteLink() throws {
        let link = try JSONDecoder().decode(ClientInviteLink.self, from: fixture("clientInviteLink"))
        #expect(link.cardId == "card_ref_1")
        #expect(link.shortCode == "7Q4KX2M9")
        #expect(link.shortCodeDisplay == "TOV-7Q4K-X2M9")
        #expect(link.path == "/c/7Q4KX2M9")
    }

    @Test func decodesProMembership() throws {
        let json = """
        {
          "ok": true,
          "membership": {
            "planKey": "pro", "rawPlanKey": "pro", "status": "active",
            "compPlanKey": null, "compUntil": null,
            "entitlements": ["custom_handle", "tax_export"],
            "currentPeriodEnd": "2026-08-01T00:00:00.000Z",
            "cancelAtPeriodEnd": false, "trialEndsAt": null, "hasBillingAccount": true
          }
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(ProMembershipResponse.self, from: json).membership
        #expect(m.planKey == "pro")
        #expect(m.entitlements.contains("tax_export"))
        #expect(m.cancelAtPeriodEnd == false)
        #expect(m.hasBillingAccount == true)
    }

    @Test func decodesProLooksAnalytics() throws {
        let json = """
        {
          "ok": true,
          "analytics": {
            "publishedCount": 2,
            "totals": {"views": 120, "likes": 40, "comments": 8, "saves": 15, "shares": 4, "bookings": 2},
            "followers": {"total": 50, "new30d": 6, "weekly": [{"weeksAgo": 1, "count": 3}]},
            "topLooks": [
              {"lookPostId": "lp1", "caption": "Balayage", "thumbUrl": "https://cdn/x.jpg",
               "publishedAt": "2026-07-01T00:00:00.000Z", "views": 90, "likes": 30, "comments": 5,
               "saves": 10, "shares": 3, "bookings": 2, "engagementScore": 42.5}
            ]
          }
        }
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(ProLooksAnalyticsResponse.self, from: json).analytics
        #expect(a.publishedCount == 2)
        #expect(a.totals.views == 120)
        #expect(a.followers.new30d == 6)
        #expect(a.topLooks.first?.engagementScore == 42.5)
    }

    @Test func decodesProReferralActivity() throws {
        let json = """
        {
          "ok": true,
          "summary": {"total": 2, "rewarded": 1, "creditDollarsApplied": 20},
          "rows": [
            {"id": "r1", "status": "REWARDED", "createdAt": "2026-06-01T12:00:00.000Z",
             "convertedAt": "2026-06-10T09:30:00.000Z", "rewardTier": "CREDIT", "rewardValue": 20,
             "rewardApplied": true, "referrerName": "Ada", "referredName": "Grace", "cardShortCode": "ABCD1234"},
            {"id": "r2", "status": "CONVERTED", "createdAt": "2026-06-05T00:00:00.000Z",
             "convertedAt": null, "rewardTier": null, "rewardValue": null, "rewardApplied": false,
             "referrerName": "Bo", "referredName": "Cleo", "cardShortCode": null}
          ]
        }
        """.data(using: .utf8)!
        let activity = try JSONDecoder().decode(ProReferralActivity.self, from: json)
        #expect(activity.summary.total == 2)
        #expect(activity.rows.count == 2)
        #expect(activity.rows[0].referrerName == "Ada")
        #expect(activity.rows[1].convertedAt == nil)
    }

    @Test func decodesProReminderSettings() throws {
        let json = """
        {"ok": true,
         "settings": {"enabled": true, "offsetMinutes": [10080, 240],
           "leads": [{"minutes": 10080, "value": 7, "unit": "days", "label": "1 week before"},
                     {"minutes": 240, "value": 4, "unit": "hours", "label": "4 hours before"}]},
         "presets": [{"value": 7, "unit": "days", "label": "1 week before"},
                     {"value": 4, "unit": "hours", "label": "4 hours before"}]}
        """.data(using: .utf8)!
        let res = try JSONDecoder().decode(ProReminderSettingsResponse.self, from: json)
        #expect(res.settings.enabled)
        #expect(res.settings.offsetMinutes == [10080, 240])
        #expect(res.settings.leads.count == 2)
        #expect(res.settings.leads.first?.value == 7)
        #expect(res.settings.leads.last?.unit == "hours")
        #expect(res.presets.count == 2)
        #expect(res.presets.first?.label == "1 week before")
    }

    @Test func decodesProNoShowSettings() throws {
        let json = """
        {"ok": true,
         "settings": {"enabled": true, "feeType": "FLAT", "feeFlatAmount": "25.00",
                      "feePercent": null, "cancelWindowHours": 24,
                      "chargeNoShow": true, "chargeLateCancel": false}}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(ProNoShowSettingsResponse.self, from: json).settings
        #expect(s.feeType == "FLAT")
        #expect(s.feeFlatAmount == "25.00")
        #expect(s.feePercent == nil)
        #expect(s.cancelWindowHours == 24)
        #expect(s.chargeLateCancel == false)
    }

    // GET /api/v1/messages/threads — Fixtures/messagesThreads.json (schema-validated).
    @Test func decodesMessageThreads() throws {
        let res = try JSONDecoder().decode(MessageThreadsResponse.self, from: fixture("messagesThreads"))
        let thread = try #require(res.threads.first)
        #expect(thread.professional.displayName == "Plume Studio")
        #expect(thread.lastMessagePreview == "See you at 2!")
        // lastMessageAt (18:30) is newer than my lastReadAt (18:00) → unread.
        #expect(thread.isUnread == true)
        // Viewer is the pro → counterparty is the CLIENT, not the pro's own name.
        #expect(thread.isViewerPro == true)
        #expect(thread.counterpartyName == "Amara Reyes")
        // Server-computed context eyebrow (booking time / service), accented.
        #expect(thread.eyebrow == "BOOKING CONFIRMED — Balayage — Sat 2:30 PM")
        #expect(thread.isAccentContext == true)
    }

    // GET /api/v1/messages/threads/{id} — Fixtures/messageThread.json (schema-validated).
    @Test func decodesMessageThread() throws {
        let res = try JSONDecoder().decode(MessageThreadPageResponse.self, from: fixture("messageThread"))
        #expect(res.messages.count == 2)
        #expect(res.messages.first?.senderUserId == "usr_pro")
        #expect(res.messages.last?.attachments.first?.mediaType == "IMAGE")
        #expect(res.hasMore == false)
        // Read-receipt driver: the counterparty's last-read stamp rides the thread.
        #expect(res.thread?.isViewerPro == true)
        #expect(res.thread?.counterpartyLastReadAt == "2026-06-27T18:35:00.000Z")
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
        #expect(res.clientUseConsent)   // booking-scoped media-use consent (C4)
        let before = try #require(res.items.first)
        #expect(before.phase == .before)
        #expect(before.mediaType == .image)
        #expect(before.displayThumbUrl == "https://x/media_1_rt.jpg")   // prefers render thumb
        let after = res.items[1]
        #expect(after.phase == .after)
        #expect(after.caption == "fresh balayage")
        #expect(after.displayThumbUrl == "https://x/media_2_t.jpg")     // falls back when no render
    }

    // clientUseConsent tolerates absence (server predating the field) → false.
    @Test func decodesProBookingMediaWithoutConsentField() throws {
        let json = Data(#"{"ok":true,"items":[]}"#.utf8)
        let res = try JSONDecoder().decode(ProBookingMediaListResponse.self, from: json)
        #expect(res.items.isEmpty)
        #expect(!res.clientUseConsent)
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
        // §10 off-platform payment: client attested, pro must confirm receipt →
        // drives the booking-detail "Confirm payment received" action.
        #expect(b.checkoutStatus == "AWAITING_CONFIRMATION")
        #expect(b.isAwaitingPaymentConfirmation)
        #expect(b.rebookOfBookingId == nil)
        // Absent key (pre-field backend response) must decode as nil.
        #expect(b.clientAddressId == nil)
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

    // POST /api/v1/pro/bookings — the create response. When the booking creates
    // a new unclaimed client the body carries `client.claimStatus` + a one-time
    // `invite.token`; both are read so the UI can confirm/share the claim link.
    // Inline shape; decode-only.
    @Test func decodesProBookingCreateWithInvite() throws {
        let json = Data("""
        {
          "ok": true,
          "booking": { "id": "bk_new_1" },
          "client": { "id": "cl_new_1", "claimStatus": "UNCLAIMED" },
          "invite": { "id": "inv_1", "token": "raw-claim-token" }
        }
        """.utf8)
        let res = try JSONDecoder().decode(ProBookingCreateResponse.self, from: json)
        #expect(res.booking.id == "bk_new_1")
        #expect(res.client?.claimStatus == "UNCLAIMED")
        #expect(res.invite?.token == "raw-claim-token")

        // Existing/claimed client: no invite block, token absent — must still decode.
        let claimed = Data("""
        { "ok": true, "booking": { "id": "bk_2" },
          "client": { "id": "cl_2", "claimStatus": "CLAIMED" } }
        """.utf8)
        let res2 = try JSONDecoder().decode(ProBookingCreateResponse.self, from: claimed)
        #expect(res2.booking.id == "bk_2")
        #expect(res2.invite == nil)
    }

    // Override-gated scheduling codes map to the flag that authorizes a retry
    // (native port of web overridePrompts.ts). Non-override codes → nil.
    @Test func mapsBookingOverridePromptCodes() {
        #expect(bookingOverridePrompt(forErrorCode: "ADVANCE_NOTICE_REQUIRED", intent: .create)?.flag == .allowShortNotice)
        #expect(bookingOverridePrompt(forErrorCode: "MAX_DAYS_AHEAD_EXCEEDED", intent: .create)?.flag == .allowFarFuture)
        #expect(bookingOverridePrompt(forErrorCode: "OUTSIDE_WORKING_HOURS", intent: .create)?.flag == .allowOutsideWorkingHours)
        #expect(bookingOverridePrompt(forErrorCode: "TIME_BOOKED", intent: .create) == nil)
        #expect(bookingOverridePrompt(forErrorCode: nil, intent: .create) == nil)
        // Also reachable straight off an APIError.
        let err = APIError.server(status: 409, message: "x", code: "OUTSIDE_WORKING_HOURS")
        #expect(err.bookingOverridePrompt(intent: .create)?.flag == .allowOutsideWorkingHours)
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

        // Before/after media pass-through for the authoring screen (tovis-app AC5).
        let media = try #require(booking.media)
        #expect(media.beforeUrl == "https://cdn.example.com/bk_1-before-thumb.jpg")
        #expect(media.afterUrl == "https://cdn.example.com/bk_1-after-thumb.jpg")
        #expect(media.beforeFullUrl == "https://cdn.example.com/bk_1-before-full.jpg")
        #expect(media.afterFullUrl == "https://cdn.example.com/bk_1-after-full.jpg")

        let summary = try #require(booking.aftercareSummary)
        #expect(summary.rebookMode == "RECOMMENDED_WINDOW")
        #expect(summary.version == 2)
        #expect(summary.isFinalized == false)
        #expect(summary.rebookWindowStart == "2026-07-20T07:00:00.000Z")
        #expect(summary.recommendedProducts.count == 2)

        // Pro-chosen featured before/after pair (seeds the native picker).
        #expect(summary.featuredBeforeAssetId == "media_1")
        #expect(summary.featuredAfterAssetId == "media_2")

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

    // GET /api/v1/pro/camera/shot-packs — Fixtures/proShotPacks.json. Trending
    // camera shot packs (tovis-app PR #453). Inline shape; decode-only. The
    // fixture deliberately includes an UNKNOWN pose-rule kind — `kind` is a
    // plain string on the wire so old builds can decode new server vocabulary
    // (the app drops unknown kinds at guide-build time, not decode time).
    @Test func decodesProShotPacks() throws {
        let res = try JSONDecoder().decode(ProShotPacksResponse.self, from: fixture("proShotPacks"))
        #expect(res.version == 1)
        #expect(res.packs.count == 2)
        let reveal = try #require(res.packs.first)
        #expect(reveal.id == "hair-reveal-v1")
        #expect(reveal.name == "The Reveal")
        #expect(reveal.trendScore == 100)
        #expect(reveal.serviceKeywords.contains("balayage"))
        #expect(reveal.steps.count == 2)
        #expect(reveal.steps[0].face == "absent")
        #expect(reveal.steps[0].fillBandMin == 0.25)
        #expect(reveal.steps[0].pose.first?.kind == "shouldersLevel")
        #expect(reveal.steps[0].pose.first?.params?["maxDegrees"] == 6)
        // The unknown-vocabulary rule still decodes (kind = plain string).
        #expect(reveal.steps[1].pose.count == 2)
        #expect(reveal.steps[1].pose[1].kind == "someFutureRuleKind")
        let nails = res.packs[1]
        #expect(nails.steps[0].isDetail)
        #expect(nails.steps[0].fillBandMin == nil)
        #expect(nails.steps[0].pose.isEmpty)
    }

    // POST /api/v1/pro/camera/look-brief — Fixtures/proLookBrief.json. The
    // Claude-vision enhanced "Match a look" brief (tovis-app PR #454). Inline
    // shape; decode-only. Pose rules ride the SAME wire type as shot packs —
    // the fixture's unknown kind proves new server vocabulary still decodes
    // (dropped at guide-build, not decode).
    @Test func decodesProLookBrief() throws {
        let res = try JSONDecoder().decode(ProLookBriefResponse.self, from: fixture("proLookBrief"))
        #expect(res.brief.summary.hasPrefix("Golden-hour glam"))
        #expect(res.brief.poseRules.count == 2)
        #expect(res.brief.poseRules[0].kind == "handNearFace")
        #expect(res.brief.poseRules[0].params?["maxFaceHeights"] == 1.2)
        #expect(res.brief.poseRules[0].tip == "Bring their hand up to graze the jaw")
        #expect(res.brief.poseRules[1].kind == "someFutureRuleKind")
        #expect(res.brief.directionLines.count == 3)
        #expect(res.brief.directionLines[0] == "Soft smile, eyes just past the lens")
    }

    // POST /api/v1/pro/camera/set-critique — Fixtures/proSetCritique.json.
    // The wrap-up photographer's review (tovis-app PR #454). Inline shape;
    // decode-only. `verdict` is a plain string — the fixture's unknown verdict
    // proves future verdicts decode on old builds (rendered neutrally).
    @Test func decodesProSetCritique() throws {
        let res = try JSONDecoder().decode(ProSetCritiqueResponse.self, from: fixture("proSetCritique"))
        #expect(res.critique.overall.contains("retake the macro"))
        #expect(res.critique.strengths.count == 2)
        #expect(res.critique.photos.count == 3)
        let hero = try #require(res.critique.photos.first)
        #expect(hero.id == "media-1")
        #expect(hero.verdict == "portfolio")
        #expect(hero.retakeTip == nil)
        #expect(res.critique.photos[1].verdict == "retake")
        #expect(res.critique.photos[1].retakeTip == "Step closer and tap to focus on the ends")
        #expect(res.critique.photos[2].verdict == "someFutureVerdict")
    }

    // GET /api/v1/pro/visibility — Fixtures/proVisibility.json. The §6.5
    // "why you're showing up" transparency read (tovis-app PR #643).
    @Test func decodesProVisibility() throws {
        let res = try JSONDecoder().decode(ProVisibilityResponse.self, from: fixture("proVisibility"))
        let v = res.visibility

        #expect(v.status == .action)
        #expect(v.discoverable == false)
        #expect(v.levers.count == 4)

        // Server order is authoritative — the screen never re-sorts.
        #expect(v.levers[0].key == "BOOKABLE")
        #expect(v.levers[0].status == .action)
        #expect(v.levers[0].actions.count == 2)
        #expect(v.levers[0].actions[0].href == "/pro/services")

        #expect(v.levers[1].status == .attention)
        #expect(v.levers[2].status == .good)
        #expect(v.levers[3].status == .unknown)
        #expect(v.levers[2].actions.isEmpty)

        #expect(v.looks.feedEligibleCount == 3)
        #expect(v.looks.rejectedCount == 2)
        #expect(v.looks.distinctServiceCount == 2)
        #expect(v.notMeasured.count == 2)
    }

    // Forward-compat probe — inline, NOT in the shared fixture: the fixture is
    // validated against the backend schema, so it must only ever carry statuses
    // the schema's enum allows. A status added server-side must degrade to
    // .unknown ("not measured yet") rather than fail the decode and blank the
    // whole screen for a pro on an older build.
    @Test func proVisibilityUnknownStatusDegradesRatherThanFailing() throws {
        let json = Data("""
        {"visibility":{"status":"someFutureStatus","discoverable":true,
        "levers":[{"key":"SOME_FUTURE_LEVER","status":"alsoFromTheFuture",
        "headline":"H","detail":"D","actions":[]}],
        "looks":{"feedEligibleCount":0,"pendingReviewCount":0,"rejectedCount":0,
        "draftCount":0,"distinctTagCount":0,"distinctServiceCount":0},
        "notMeasured":[]}}
        """.utf8)

        let res = try JSONDecoder().decode(ProVisibilityResponse.self, from: json)
        #expect(res.visibility.status == .unknown)
        #expect(res.visibility.levers.count == 1)
        #expect(res.visibility.levers[0].key == "SOME_FUTURE_LEVER")
        #expect(res.visibility.levers[0].status == .unknown)
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

    // GET /api/v1/pro/finance — Fixtures/proFinance.json. The Finance & Tax tab
    // (tovis-app), a superset of the Overview view-model + a `finance` block.
    @Test func decodesProFinance() throws {
        let res = try JSONDecoder().decode(ProFinanceResponse.self, from: fixture("proFinance"))
        // Superset carries the Overview fields.
        #expect(res.activeMonth.key == "2026-06")
        #expect(res.revenue.value == "$4,020.00")
        #expect(res.topServices.count == 1)
        // Finance block.
        #expect(res.finance.taxYear == 2026)
        #expect(res.finance.netProfitCents == 367860)
        #expect(res.finance.summaryCards.count == 4)
        #expect(res.finance.summaryCards[0].tone == "positive")
        #expect(res.finance.summaryCards[3].tone == "warn")
        #expect(res.finance.incomeBreakdown.count == 3)
        #expect(res.finance.quarterlyReminder.dueDateLabel == "June 15, 2026")
        #expect(res.finance.expenses.count == 3)
        #expect(res.finance.expenses[0].categoryRisk == "green")
        #expect(res.finance.expenses[0].notes == nil)
        #expect(res.finance.expenses[0].mileageMiles == nil)
        #expect(res.finance.expenses[1].notes == "Monthly suite")
        #expect(res.finance.categories.count == 2)
        #expect(res.finance.categories[1].risk == "red")
        // Mileage expense + rate.
        #expect(res.finance.expenses[2].category == "MILEAGE")
        #expect(res.finance.expenses[2].mileageMiles == 100)
        #expect(res.finance.mileageRateCents == 72.5)
        #expect(res.finance.mileageRateLabel == "72.5¢/mi")
        // Receipt inbox + forwarding address.
        #expect(res.finance.receiptInbox.count == 1)
        #expect(res.finance.receiptInbox[0].source == "COSMOPROF")
        #expect(res.finance.receiptInbox[0].parsedAmountCents == 24219)
        #expect(res.finance.receiptInboxAddress == "jadehair@tovis.me")
        // Membership gate for tax-doc export (nil → treat as allowed).
        #expect(res.finance.canExportTaxDocs == true)
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
        // Pro public reply (tovis-app PR #475).
        #expect(first.proReply?.body == "Thank you, Jordan! See you at the gloss refresh.")
        #expect(first.proReply?.repliedAtISO == "2026-06-19T15:00:00.000Z")

        let second = res.items[1]
        #expect(second.headline == nil)
        #expect(second.bookingId == nil)
        #expect(second.proReply == nil)   // missing key decodes as nil (backward-compatible)
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
        #expect(res.profile.instagramHandle == "studio.lumen")
        #expect(res.profile.tiktokHandle == "studiolumen")
        #expect(res.profile.websiteUrl == "https://studiolumen.com/")
    }

    // Social fields ship with web PR #478 — an older backend omits them and the
    // profile must still decode (chips just don't render).
    @Test func proMyProfileDecodesWithoutSocialFields() throws {
        let json = """
        { "ok": true, "profile": { "id": "pro_1", "businessName": null, "handle": null,
          "bio": null, "location": null, "avatarUrl": null, "professionType": null,
          "nameDisplay": null, "isPremium": false } }
        """.data(using: .utf8)!
        let res = try JSONDecoder().decode(ProMyProfileResponse.self, from: json)
        #expect(res.profile.instagramHandle == nil)
        #expect(res.profile.websiteUrl == nil)
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
        // Relationship intelligence — formatted server-side, decoded verbatim.
        let intel = try #require(chart.relationshipIntelligence)
        #expect(intel.lifetimeValue.value == "$720")
        #expect(intel.lifetimeValue.hint == "$960 platform-wide")
        #expect(intel.leadTime.hint == nil)
        #expect(intel.rebooking.value == "At risk")
        #expect(intel.rebooking.hint == "Birthday in 12d")
        #expect(intel.referralSource == "Referred by a client")
        #expect(intel.flags.count == 2)
        #expect(intel.flags.first?.key == "retention-risk")
        #expect(intel.flags.first?.tone == "warn")
    }

    // A chart from a backend that predates the relationship-intelligence field
    // still decodes (the field is optional) — the card is simply hidden.
    @Test func decodesProClientChartWithoutRelationshipIntelligence() throws {
        var object = try JSONSerialization.jsonObject(
            with: fixture("proClientChart")
        ) as! [String: Any]
        object.removeValue(forKey: "relationshipIntelligence")
        let data = try JSONSerialization.data(withJSONObject: object)
        let chart = try JSONDecoder().decode(ProClientChart.self, from: data)
        #expect(chart.relationshipIntelligence == nil)
        #expect(chart.header.fullName == "Jordan Rivera")
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

    // GET /api/v1/pro/camera/usage — Fixtures/proCameraUsage.json. The pro's
    // monthly AI-camera image allowance behind the membership quota panel.
    @Test func decodesProCameraUsage() throws {
        let res = try JSONDecoder().decode(ProCameraUsageResponse.self, from: fixture("proCameraUsage"))
        #expect(res.usage.used == 4)
        #expect(res.usage.baseQuota == 30)
        #expect(res.usage.bonus == 10)
        #expect(res.usage.quota == 40)
        #expect(res.usage.remaining == 36)
        #expect(res.usage.enforced)
        #expect(abs(res.usage.usedFraction - 0.1) < 0.0001)
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
        // A standalone booking is not a coupled aftercare rebook.
        #expect(booking.rebookOfBookingId == nil)
        #expect(!booking.isCoupledRebookAwaitingPaymentConfirmation)
        // Native-checkout payment options (accepted methods + handles + tip config).
        let options = try #require(booking.paymentOptions)
        #expect(options.methods.map(\.key) == ["cash", "venmo", "zelle"])
        #expect(options.methods.first(where: { $0.key == "venmo" })?.handle == "@amara")
        #expect(options.tipsEnabled)
        #expect(options.allowCustomTip)
        #expect(options.tipSuggestions == [18, 20, 25])
        #expect(options.paymentNote == "Cash or Venmo preferred, thank you!")
        #expect(options.collectPaymentAt == "AFTER_SERVICE")
        // A pending consultation carries the pro's proposal: the client sees the
        // itemized plan they're approving, not just the total.
        let consult = try #require(b.pending.first)
        #expect(consult.hasPendingConsultationApproval)
        let proposal = try #require(consult.consultation?.proposedServices)
        #expect(proposal.currency == "USD")
        #expect(proposal.items.map(\.label) == ["Full Balayage", "Gloss"])
        #expect(proposal.items.map(\.price) == ["175.00", "40.00"])
        // categoryName is nullable per item — the second has none.
        #expect(proposal.items.map(\.categoryName) == ["Color", nil])
        #expect(consult.consultation?.proposedTotal == "215.00")
        // The prebooked aftercare rebook is PENDING + coupled to bk_1's payment —
        // drives the "pending — your pro will confirm" label (§10).
        let next = try #require(b.prebooked.first)
        #expect(next.rebookOfBookingId == "bk_1")
        #expect(next.paymentOptions == nil)
        #expect(next.isCoupledRebookAwaitingPaymentConfirmation)
        // REAL_NAME mode → first + last name.
        #expect(booking.professional?.displayName == "Dana Lee")
        #expect(b.waitlist.first?.professional?.displayName == "Snip")
        #expect(b.waitlist.first?.service?.name == "Cut")
    }

    // `proposedServicesJson` is an untyped Json column, so a blob that isn't the
    // expected `{ items: [...] }` object must degrade to "no line items" instead of
    // failing the surrounding consultation's decode.
    @Test func toleratesUnexpectedProposedServicesShapes() throws {
        func consultation(_ proposedServicesJson: String) throws -> ClientBookingConsultation {
            let json = """
            {
              "consultationNotes": null, "consultationPrice": null,
              "consultationConfirmedAt": null, "approvalStatus": "PENDING",
              "approvalNotes": null, "proposedTotal": "10.00",
              "approvedAt": null, "rejectedAt": null,
              "proposedServicesJson": \(proposedServicesJson)
            }
            """
            return try JSONDecoder().decode(
                ClientBookingConsultation.self, from: Data(json.utf8)
            )
        }

        // Null, a non-object, and an object without `items` all decode to no proposal.
        #expect(try consultation("null").proposedServices == nil)
        #expect(try consultation(#""garbage""#).proposedServices == nil)
        #expect(try consultation("{}").proposedServices == nil)
        // ...but the rest of the consultation still decodes.
        #expect(try consultation("null").proposedTotal == "10.00")

        // A bare-number price (the column is untyped) still renders as money.
        let numeric = try consultation(#"{"items":[{"label":"Gloss","price":40.5}]}"#)
        #expect(numeric.proposedServices?.items.first?.price == "40.5")
    }

    // The consultation decision body must use the backend's exact action verbs.
    @Test func consultationDecisionEncodesActionVerb() throws {
        #expect(ConsultationDecision.approve.wire == "APPROVE")
        #expect(ConsultationDecision.reject.wire == "REJECT")

        let data = try JSONEncoder().encode(ConsultationDecisionRequest(action: ConsultationDecision.approve.wire))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"action":"APPROVE"}"#)
    }

    // POST /api/v1/support/tickets — Fixtures/supportTicket.json (schema-validated
    // against SupportTicketDTO). The route's response is the ticket itself; the
    // submitted message is deliberately not echoed back.
    @Test func decodesSupportTicket() throws {
        let ticket = try JSONDecoder().decode(SupportTicket.self, from: fixture("supportTicket"))
        #expect(ticket.id == "cmrnv7n140001pofjp183ql40")
        #expect(ticket.subject == "Booking not confirming")
        #expect(ticket.status == "OPEN")
        #expect(ticket.createdAt == "2026-07-16T18:51:19.769Z")
    }

    // GET /api/v1/professionals/{id} — Fixtures/proProfile.json (schema-validated).
    @Test func decodesProProfile() throws {
        let res = try JSONDecoder().decode(ProProfileResponse.self, from: fixture("proProfile"))
        let p = res.professional
        #expect(p.header.displayName == "Dana Lee")
        #expect(p.header.isLicenseVerified == true)
        #expect(p.header.instagramHandle == "dana.hair")
        #expect(p.header.tiktokHandle == "danadoeshair")
        #expect(p.header.websiteUrl == "https://plumestudio.com/")
        #expect(p.offerings.first?.pricingLines.count == 2)
        #expect(p.portfolioTiles.first?.displayUrl == "https://x/1t.jpg")
        #expect(p.reviews.first?.rating == 5)
        #expect(p.stats.averageRatingLabel == "4.9")
        #expect(p.stats.followerCount == 45)
        #expect(p.stats.looksLabel == "18")
        #expect(p.stats.followersLabel == "45")
        #expect(p.acceptedPayments == ["Cash", "Venmo"])
    }

    // The looks/followers labels post-date the native tab, so a backend that
    // predates tovis-app PR #645 omits them — the stats must still decode and the
    // pro-profile grid then drops those two tiles rather than showing a wrong count.
    @Test func decodesProProfileStatsWithoutLooksAndFollowersLabels() throws {
        let json = #"""
        {
          "priceFromLabel": "From $100",
          "completedBookingsLabel": "120",
          "favoritesLabel": "45",
          "reviewCountLabel": "30",
          "averageRatingLabel": "4.9",
          "followerCount": 45
        }
        """#.data(using: .utf8)!

        let stats = try JSONDecoder().decode(ProProfileStats.self, from: json)
        #expect(stats.looksLabel == nil)
        #expect(stats.followersLabel == nil)
        #expect(stats.followerCount == 45)
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
        // Opt-in before/after pair + style tags on the pro look.
        #expect(pro.before?.id == "asset_before_1")
        #expect(pro.tags.map(\.slug) == ["balayage", "money-piece"])

        let client = res.items[1]
        #expect(client.professional == nil)
        #expect(client.clientAuthor?.handleLabel == "@noellestyles")
        #expect(client.thumbUrl == nil)
        #expect(client.viewerSaved == true)
        // Single-tile look: no pair, no tags.
        #expect(client.before == nil)
        #expect(client.tags.isEmpty)
    }

    // GET /api/v1/discover/trending-tags — Fixtures/discoverTrendingTags.json.
    // The Discover looks-first trending-tags rail (social-first D2).
    @Test func decodesDiscoverTrendingTags() throws {
        let res = try JSONDecoder().decode(TrendingTagsResponse.self, from: fixture("discoverTrendingTags"))
        #expect(res.tags.count == 3)
        let top = try #require(res.tags.first)
        #expect(top.slug == "balayage")
        #expect(top.display == "balayage")
        #expect(top.lookCount == 42)
        #expect(res.tags[1].display == "curtainBangs")
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
        // Client commenter: no Creator/Pro badge.
        #expect(top.user.isLookAuthor == false)
        #expect(top.user.isPro == false)
        #expect(top.user.badgeLabel == nil)
        let reply = res.comments[1]
        #expect(reply.isReply == true)
        #expect(reply.parentCommentId == "cmt_1")
        #expect(reply.viewerCanDelete == true)
        // The look author (also a pro) — Creator badge wins.
        #expect(reply.user.isLookAuthor == true)
        #expect(reply.user.isPro == true)
        #expect(reply.user.badgeLabel == "Creator")
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

    // GET /api/v1/client/bookings/{id}/aftercare — care notes + featured pair (§24 AF3b).
    @Test func decodesClientAftercareDetail() throws {
        let json = """
        {
          "ok": true,
          "canShowAftercare": true,
          "aftercare": {
            "id": "ac_1",
            "notes": "Rinse with cool water for 48h.",
            "sentToClientAt": "2026-07-02T15:00:00.000Z"
          },
          "beforeAfter": {
            "beforeUrl": "https://cdn/thumb-before.jpg",
            "afterUrl": "https://cdn/thumb-after.jpg",
            "beforeFullUrl": "https://cdn/full-before.jpg",
            "afterFullUrl": "https://cdn/full-after.jpg"
          }
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(ClientAftercareDetail.self, from: json)
        #expect(res.canShowAftercare == true)
        #expect(res.hasContent == true)
        #expect(res.aftercare?.notes == "Rinse with cool water for 48h.")
        #expect(res.beforeAfter.hasAny == true)
        // Full-size URL is preferred for the hero compare / tap-to-open.
        #expect(res.beforeAfter.beforePreferred == "https://cdn/full-before.jpg")
        #expect(res.beforeAfter.afterPreferred == "https://cdn/full-after.jpg")
        // Product fields are additive — a payload without them decodes to empty
        // (this JSON omits them) so the section still renders notes + photos.
        #expect(res.recommendedProducts.isEmpty)
        #expect(res.checkoutProducts.isEmpty)
        #expect(res.checkoutProductsEditable == false)
        // The rebook slice is additive too — an omitting payload decodes to nil.
        #expect(res.rebook == nil)
        // The review fields are additive (§5 A3-rev) — an omitting payload
        // decodes to a hidden review block (no review, not eligible).
        #expect(res.existingReview == nil)
        #expect(res.reviewEligible == false)
    }

    // GET .../aftercare with the §5 A3-prod product-checkout fields —
    // Fixtures/clientAftercareDetail.json (also schema-validated). Splits internal
    // (addable) vs external (link-out) recs + carries the current selection.
    @Test func decodesClientAftercareDetailWithProducts() throws {
        let res = try JSONDecoder().decode(
            ClientAftercareDetail.self, from: fixture("clientAftercareDetail"))

        #expect(res.canShowAftercare == true)
        #expect(res.checkoutProductsEditable == true)
        #expect(res.recommendedProducts.count == 2)

        // rp_1 is external (link-out only); rp_2 is an in-app product.
        #expect(res.externalRecommendations.map(\.id) == ["rp_1"])
        #expect(res.internalRecommendations.map(\.id) == ["rp_2"])

        let external = try #require(res.externalRecommendations.first)
        #expect(external.isInternal == false)
        #expect(external.externalName == "Olaplex No.7 Bonding Oil")
        #expect(external.externalUrl == "https://example.com/olaplex-7")
        #expect(external.product == nil)

        let internalRec = try #require(res.internalRecommendations.first)
        #expect(internalRec.isInternal == true)
        #expect(internalRec.product?.name == "Purple Toning Shampoo")
        #expect(internalRec.product?.retailPrice == "28.00")

        // The current selection seeds the qty stepper (rp_2 × 2).
        let selected = try #require(res.checkoutProducts.first)
        #expect(selected.id == "rp_2")
        #expect(selected.recommendationId == "rp_2")
        #expect(selected.productId == "prod_9")
        #expect(selected.quantity == 2)
        #expect(selected.unitPrice == "28.00")

        // §5 A3-rebook: the pro recommended a window (no coupled next booking yet),
        // so the card shows the window + a "Rebook now" CTA.
        let rebook = try #require(res.rebook)
        #expect(rebook.isRecommendedWindow == true)
        #expect(rebook.isBookedNextAppointment == false)
        #expect(rebook.windowStart == "2026-08-01T00:00:00.000Z")
        #expect(rebook.windowEnd == "2026-08-15T00:00:00.000Z")
        #expect(rebook.isDeclined == false)
        #expect(rebook.confirmedNextBooking == nil)

        // §5 A3-rev 4a: the fixture carries an existing review + review-eligible.
        #expect(res.reviewEligible == true)
        let review = try #require(res.existingReview)
        #expect(review.id == "rev_1")
        #expect(review.rating == 5)
        #expect(review.headline == "Best color of my life")
        #expect(review.body == "Amara nailed the balayage — booking again.")

        // §5 A3-rev 4b: the review carries attached photos (image + video) with
        // render-ready URLs; the video tile renders a badge, not an inline player.
        #expect(review.mediaAssets.count == 2)
        let firstMedia = try #require(review.mediaAssets.first)
        #expect(firstMedia.id == "rm_1")
        #expect(firstMedia.isVideo == false)
        #expect(firstMedia.displayThumbUrl == "https://cdn.example.com/rev-1-thumb.jpg")
        let videoMedia = try #require(review.mediaAssets.last)
        #expect(videoMedia.isVideo == true)
        // No thumb → falls back to the full URL for the tile.
        #expect(videoMedia.displayThumbUrl == "https://cdn.example.com/rev-2.mp4")
    }

    // §5 A3-rev 4b: review media is additive + defensively decoded — an omitted
    // list decodes to an empty grid, and a garbled item can't wedge the review.
    @Test func decodesClientAftercareReviewMediaDefensively() throws {
        // No mediaAssets key at all → empty grid (older backend / pre-4b payload).
        let noMedia = """
        {
          "ok": true,
          "canShowAftercare": true,
          "aftercare": { "id": "ac_1", "notes": null, "sentToClientAt": "2026-07-02T15:00:00.000Z" },
          "beforeAfter": { "beforeUrl": null, "afterUrl": null, "beforeFullUrl": null, "afterFullUrl": null },
          "reviewEligible": true,
          "existingReview": { "id": "rev_3", "rating": 5, "headline": null, "body": null }
        }
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(ClientAftercareDetail.self, from: noMedia)
        #expect(a.existingReview?.mediaAssets.isEmpty == true)

        // An unknown mediaType decodes leniently to an image rather than failing.
        let oddMedia = """
        {
          "ok": true,
          "canShowAftercare": true,
          "aftercare": { "id": "ac_1", "notes": null, "sentToClientAt": "2026-07-02T15:00:00.000Z" },
          "beforeAfter": { "beforeUrl": null, "afterUrl": null, "beforeFullUrl": null, "afterFullUrl": null },
          "reviewEligible": true,
          "existingReview": {
            "id": "rev_4", "rating": 4, "headline": null, "body": null,
            "mediaAssets": [
              { "id": "rm_9", "mediaType": "GIF", "url": "https://cdn/x.gif", "thumbUrl": null, "createdAt": "2026-07-03T10:00:00.000Z" }
            ]
          }
        }
        """.data(using: .utf8)!
        let b = try JSONDecoder().decode(ClientAftercareDetail.self, from: oddMedia)
        let media = try #require(b.existingReview?.mediaAssets.first)
        #expect(media.id == "rm_9")
        #expect(media.mediaType == .image)
    }

    // §5 A3-rev 4a: a garbled / out-of-range rating defensively decodes to nil
    // rather than failing the whole aftercare decode (the editor starts unrated).
    @Test func decodesClientAftercareExistingReviewClampsBadRating() throws {
        let json = """
        {
          "ok": true,
          "canShowAftercare": true,
          "aftercare": { "id": "ac_1", "notes": null, "sentToClientAt": "2026-07-02T15:00:00.000Z" },
          "beforeAfter": { "beforeUrl": null, "afterUrl": null, "beforeFullUrl": null, "afterFullUrl": null },
          "reviewEligible": true,
          "existingReview": { "id": "rev_2", "rating": 9, "headline": null, "body": null }
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(ClientAftercareDetail.self, from: json)
        #expect(res.reviewEligible == true)
        let review = try #require(res.existingReview)
        #expect(review.id == "rev_2")
        // 9 is out of 1…5 ⇒ clamped to nil.
        #expect(review.rating == nil)
    }

    // GET .../aftercare with a confirmed BOOKED_NEXT_APPOINTMENT rebook — the
    // coupled next booking (still PENDING the pro's approval) drives the card's
    // "pending your pro's approval" state (§5 A3-rebook).
    @Test func decodesClientAftercareRebookCoupledNextBooking() throws {
        let json = """
        {
          "ok": true,
          "canShowAftercare": true,
          "aftercare": { "id": "ac_1", "notes": null, "sentToClientAt": "2026-07-02T15:00:00.000Z" },
          "beforeAfter": { "beforeUrl": null, "afterUrl": null, "beforeFullUrl": null, "afterFullUrl": null },
          "recommendedProducts": [],
          "checkoutProducts": [],
          "rebook": {
            "mode": "BOOKED_NEXT_APPOINTMENT",
            "rebookedFor": "2026-08-05T17:00:00.000Z",
            "windowStart": null,
            "windowEnd": null,
            "declinedAt": null,
            "nextBooking": {
              "id": "booking_next",
              "status": "PENDING",
              "scheduledFor": "2026-08-05T17:00:00.000Z"
            }
          },
          "checkoutProductsEditable": false
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(ClientAftercareDetail.self, from: json)
        let rebook = try #require(res.rebook)
        #expect(rebook.isBookedNextAppointment == true)
        #expect(rebook.isRecommendedWindow == false)
        let next = try #require(rebook.confirmedNextBooking)
        #expect(next.id == "booking_next")
        #expect(next.scheduledFor == "2026-08-05T17:00:00.000Z")
        // PENDING coupled rebook ⇒ "pending your pro's approval" state.
        #expect(rebook.isNextBookingPendingApproval == true)
    }

    // A cancelled coupled next booking is treated as "no active next" so the card
    // can re-offer a rebook rather than showing a stale confirmed state.
    @Test func decodesClientAftercareRebookIgnoresCancelledNext() throws {
        let json = """
        {
          "ok": true,
          "canShowAftercare": true,
          "aftercare": { "id": "ac_1", "notes": null, "sentToClientAt": "2026-07-02T15:00:00.000Z" },
          "beforeAfter": { "beforeUrl": null, "afterUrl": null, "beforeFullUrl": null, "afterFullUrl": null },
          "recommendedProducts": [],
          "checkoutProducts": [],
          "rebook": {
            "mode": "RECOMMENDED_WINDOW",
            "rebookedFor": null,
            "windowStart": "2026-08-01T00:00:00.000Z",
            "windowEnd": "2026-08-15T00:00:00.000Z",
            "declinedAt": null,
            "nextBooking": {
              "id": "booking_cancelled",
              "status": "CANCELLED",
              "scheduledFor": "2026-08-05T17:00:00.000Z"
            }
          },
          "checkoutProductsEditable": false
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(ClientAftercareDetail.self, from: json)
        let rebook = try #require(res.rebook)
        #expect(rebook.confirmedNextBooking == nil)
        #expect(rebook.isNextBookingPendingApproval == false)
        #expect(rebook.isRecommendedWindow == true)
        #expect(rebook.hasRenderableRebook == true)
        // PF6: a rebook-only summary (no notes / photos / products) still has
        // content, so the native aftercare card — and its rebook CTA — mounts.
        #expect(res.hasContent == true)
    }

    // A COMPLETED booking with no summary + no photos: visible gate, but nothing
    // to render (the native section stays hidden on `hasContent == false`).
    @Test func decodesEmptyClientAftercareDetail() throws {
        let json = """
        {
          "ok": true,
          "canShowAftercare": true,
          "aftercare": null,
          "beforeAfter": {
            "beforeUrl": null,
            "afterUrl": null,
            "beforeFullUrl": null,
            "afterFullUrl": null
          }
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(ClientAftercareDetail.self, from: json)
        #expect(res.canShowAftercare == true)
        #expect(res.aftercare == nil)
        #expect(res.beforeAfter.hasAny == false)
        #expect(res.hasContent == false)
        // Falls back cleanly when a phase is absent.
        #expect(res.beforeAfter.beforePreferred == nil)
    }
}