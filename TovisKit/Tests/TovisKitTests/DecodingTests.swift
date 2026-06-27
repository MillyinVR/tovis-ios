import Foundation
import Testing
@testable import TovisKit

// Verifies our Swift models decode the EXACT JSON the backend emits.
// The fixtures below are the real /api/v1 wire shapes (lib/dto/auth.ts).

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

    // GET /api/v1/client/home — a representative payload (lib/dto/clientHome.ts).
    @Test func decodesClientHome() throws {
        let json = """
        {
          "ok": true,
          "home": {
            "upcoming": {
              "id": "bk_1",
              "status": "CONFIRMED",
              "source": "CLIENT",
              "sessionStep": "SCHEDULED",
              "scheduledFor": "2026-07-01T17:00:00.000Z",
              "finishedAt": null,
              "totalAmount": "120.00",
              "tipAmount": null,
              "totalDurationMinutes": 90,
              "bufferMinutes": 0,
              "locationType": "SALON",
              "locationTimeZone": "America/Los_Angeles",
              "service": { "id": "svc_1", "name": "Balayage" },
              "professional": {
                "id": "pro_1", "businessName": "Plume Studio", "handle": "plume",
                "avatarUrl": null, "location": "Los Angeles, CA", "timeZone": "America/Los_Angeles"
              },
              "location": {
                "id": "loc_1", "name": "Plume Studio", "formattedAddress": "1 Main St",
                "city": "Los Angeles", "state": "CA", "timeZone": "America/Los_Angeles"
              },
              "serviceItems": [],
              "productSales": []
            },
            "upcomingCount": 2,
            "action": {
              "kind": "PENDING_CONSULTATION",
              "booking": {
                "id": "bk_2", "status": "CONSULTATION", "source": "PRO",
                "sessionStep": "CONSULTATION", "scheduledFor": "2026-07-02T20:00:00.000Z",
                "finishedAt": null, "totalAmount": null, "totalDurationMinutes": 30,
                "bufferMinutes": 0, "locationType": null, "service": null,
                "professional": null, "location": null, "serviceItems": [], "productSales": []
              }
            },
            "invites": [
              {
                "id": "inv_1", "firstMatchedTier": "EARLY", "status": "NOTIFIED",
                "opening": {
                  "id": "op_1", "professionalId": "pro_9", "startAt": "2026-06-29T18:00:00.000Z",
                  "endAt": "2026-06-29T19:00:00.000Z", "status": "OPEN", "visibilityMode": "PRIVATE",
                  "timeZone": "America/New_York",
                  "professional": {
                    "id": "pro_9", "businessName": null, "handle": "alex", "avatarUrl": null,
                    "professionType": "HAIR", "location": "NYC", "timeZone": "America/New_York"
                  },
                  "location": null, "services": [], "tierPlans": []
                }
              }
            ],
            "waitlists": [
              {
                "id": "wl_1", "createdAt": "2026-06-20T00:00:00.000Z", "status": "ACTIVE",
                "preferenceType": "ANY",
                "service": { "id": "svc_2", "name": "Cut" },
                "professional": { "id": "pro_2", "businessName": "Snip", "handle": null, "avatarUrl": null, "location": null, "timeZone": null }
              }
            ],
            "favoritePros": [
              { "professional": { "id": "pro_3", "businessName": "Gloss", "handle": "gloss", "avatarUrl": null, "professionType": "NAILS", "location": "SF" } }
            ],
            "favoriteServices": [
              {
                "id": "fav_1",
                "service": { "id": "svc_3", "name": "Gel Mani", "minPrice": "45.00", "defaultDurationMinutes": 60, "defaultImageUrl": null, "category": { "id": "cat_1", "name": "Nails" } }
              }
            ],
            "viralLive": [
              { "id": "v_1", "name": "Glass Skin", "sourceUrl": null, "approvedAt": "2026-06-01T00:00:00.000Z", "_count": { "approvalFanOuts": 12 } }
            ],
            "viralPending": []
          }
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(ClientHomeResponse.self, from: json)
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
        #expect(home.waitlists.first?.service?.name == "Cut")
        #expect(home.favoritePros.first?.professional?.displayName == "Gloss")
        #expect(home.favoriteServices.first?.service?.minPrice == "45.00")
        #expect(home.viralLive.first?.fanOutCount == 12)
    }

    // GET /api/v1/client/bookings — bucketed response (lib/dto/clientBooking.ts).
    @Test func decodesClientBookings() throws {
        let json = """
        {
          "ok": true,
          "buckets": {
            "upcoming": [
              {
                "id": "bk_1", "status": "ACCEPTED", "source": "CLIENT", "sessionStep": "SCHEDULED",
                "scheduledFor": "2026-07-01T17:00:00.000Z", "totalDurationMinutes": 90, "bufferMinutes": 0,
                "subtotalSnapshot": "120.00",
                "checkout": {
                  "subtotalSnapshot": "120.00", "serviceSubtotalSnapshot": "120.00",
                  "productSubtotalSnapshot": null, "tipAmount": null, "taxAmount": null,
                  "discountAmount": null, "totalAmount": "120.00", "checkoutStatus": null,
                  "selectedPaymentMethod": null, "paymentAuthorizedAt": null, "paymentCollectedAt": null
                },
                "locationType": "SALON", "locationId": "loc_1",
                "timeZone": "America/Los_Angeles", "timeZoneSource": "LOCATION",
                "locationLabel": "1 Main St, Los Angeles",
                "professional": {
                  "id": "pro_1", "businessName": null, "firstName": "Dana", "lastName": "Lee",
                  "handle": "dana", "nameDisplay": "REAL_NAME", "location": "LA", "timeZone": "America/Los_Angeles"
                },
                "bookedLocation": {
                  "id": "loc_1", "name": "Plume", "formattedAddress": "1 Main St",
                  "city": "Los Angeles", "state": "CA", "timeZone": "America/Los_Angeles"
                },
                "display": { "title": "Balayage + Toner", "baseName": "Balayage", "addOnNames": ["Toner"], "addOnCount": 1 },
                "items": [
                  { "id": "it_1", "type": "BASE", "serviceId": "svc_1", "name": "Balayage", "price": "100.00", "durationMinutes": 75, "parentItemId": null, "sortOrder": 0 },
                  { "id": "it_2", "type": "ADD_ON", "serviceId": "svc_2", "name": "Toner", "price": "20.00", "durationMinutes": 15, "parentItemId": "it_1", "sortOrder": 1 }
                ],
                "productSales": [],
                "hasUnreadAftercare": false, "hasPendingConsultationApproval": false,
                "consultation": null
              }
            ],
            "pending": [],
            "prebooked": [],
            "past": [],
            "waitlist": [
              {
                "id": "wl_1", "createdAt": "2026-06-20T00:00:00.000Z", "status": "ACTIVE",
                "preferenceType": "ANY", "notes": null,
                "service": { "id": "svc_3", "name": "Cut" },
                "professional": { "id": "pro_2", "businessName": "Snip", "firstName": null, "lastName": null, "handle": null, "nameDisplay": "BUSINESS_NAME", "location": null, "timeZone": null }
              }
            ]
          },
          "meta": { "now": "2026-06-27T00:00:00.000Z", "next30": "2026-07-27T00:00:00.000Z" }
        }
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode(ClientBookingsResponse.self, from: json)
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
}