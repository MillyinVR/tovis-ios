import Foundation
import Testing
@testable import TovisKit

/// The practice library's wire contract + the attach request's encoding.
///
/// The fixture is the same file `scripts/contract/validate-fixtures.mjs` checks
/// against the backend's generated schema, so shape is guarded from both sides:
/// ajv proves the server can emit it, this proves we can read it.
@Suite struct ProPracticeDecodeTests {
    @Test func decodesTheLibrary() throws {
        let data = try fixture("proPractice")
        let response = try JSONDecoder().decode(ProPracticeListResponse.self, from: data)

        #expect(response.items.count == 2)

        // A fresh shot: no caption, no attachment, a live signed URL.
        let fresh = response.items[0]
        #expect(fresh.id == "shot_practice_1")
        #expect(fresh.mediaType == .image)
        #expect(fresh.caption == nil)
        #expect(fresh.focalX == 0.5)
        #expect(fresh.isAttached == false)
        #expect(fresh.renderUrl != nil)
    }

    /// The three fields that are legitimately null on a real row — a focal on a
    /// faceless shot, and an expired signed URL — must not throw. This is the
    /// `ProPaymentBadge`/`ProServiceSwatch` non-throwing rule: a missing extra
    /// degrades the tile, it does not fail the whole library.
    @Test func aFacelessShotWithAnExpiredUrlStillDecodes() throws {
        let data = try fixture("proPractice")
        let response = try JSONDecoder().decode(ProPracticeListResponse.self, from: data)

        let attached = response.items[1]
        #expect(attached.focalX == nil)
        #expect(attached.focalY == nil)
        #expect(attached.renderUrl == nil)
        #expect(attached.isAttached == true)
        #expect(attached.attachedMediaId == "media_abc123")
        #expect(attached.attachedAt == "2026-08-04T09:15:00.000Z")
    }
}

@Suite struct ProPracticeAttachRequestTests {
    private func encoded(_ target: ProPracticeAttachTarget, caption: String? = nil) throws -> [String: Any] {
        let data = try JSONEncoder.canonical.encode(
            ProPracticeAttachRequest(target: target, caption: caption)
        )
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    @Test func bookingCarriesOnlyTheBooking() throws {
        let body = try encoded(.booking(bookingId: "bk_1"))

        #expect(body["target"] as? String == "BOOKING")
        #expect(body["bookingId"] as? String == "bk_1")
        // A look's fields must not ride along — the server would reject them,
        // and more importantly they'd be nonsense on a private attach.
        #expect(body["serviceIds"] == nil)
        #expect(body["publish"] == nil)
    }

    @Test func lookCarriesItsServicesAndPublishFlag() throws {
        let body = try encoded(
            .look(serviceIds: ["svc_1", "svc_2"], primaryServiceId: "svc_1", publish: true)
        )

        #expect(body["target"] as? String == "LOOK")
        #expect(body["serviceIds"] as? [String] == ["svc_1", "svc_2"])
        #expect(body["primaryServiceId"] as? String == "svc_1")
        #expect(body["publish"] as? Bool == true)
        #expect(body["bookingId"] == nil)
    }

    /// 🔴 The one that matters: a draft attach must send `publish: false`
    /// EXPLICITLY. If it were omitted, the server's own default would decide
    /// whether the pro's photo goes public — and this app would have no say in
    /// something that can't be taken back.
    @Test func aDraftSaysPublishFalseRatherThanOmittingIt() throws {
        let body = try encoded(
            .look(serviceIds: ["svc_1"], primaryServiceId: nil, publish: false)
        )

        #expect(body.keys.contains("publish"))
        #expect(body["publish"] as? Bool == false)
    }
}
