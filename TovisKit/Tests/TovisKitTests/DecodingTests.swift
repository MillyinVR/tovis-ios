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

    // GET /api/v1/client/bookings — Fixtures/clientBookings.json (schema-validated).
    @Test func decodesClientBookings() throws {
        let res = try JSONDecoder().decode(ClientBookingsResponse.self, from: fixture("clientBookings"))
        let b = res.buckets
        #expect(b.upcoming.count == 1)
        let booking = try #require(b.upcoming.first)
        #expect(booking.display.title == "Balayage + Toner")
        #expect(booking.items.filter { $0.isAddOn }.count == 1)
        #expect(booking.checkout.totalAmount == "120.00")
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
}