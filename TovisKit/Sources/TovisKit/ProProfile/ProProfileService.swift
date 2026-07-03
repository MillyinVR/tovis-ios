import Foundation

/// PRO workspace — the pro's own profile + offerings management (web
/// `/pro/profile/public-profile` + the services manager). The *public* preview
/// (stats/portfolio/reviews) is read via `ProfileService.professional(id:)` using
/// the `id` this returns. Authenticated; PRO-only. See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProProfileService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/profile → the pro's own editable profile (incl. its id).
    public func myProfile() async throws -> ProMyProfile {
        let response: ProMyProfileResponse = try await api.request("/pro/profile")
        return response.profile
    }

    /// GET /api/v1/pro/reviews → the pro's reviews list (web `/pro/reviews`):
    /// the 100 most recent reviews + render-safe media tiles.
    public func reviews() async throws -> [ProReviewItem] {
        let response: ProReviewsListResponse = try await api.request("/pro/reviews")
        return response.items
    }

    /// PUT /api/v1/pro/reviews/{id}/reply — upsert the pro's public response to a
    /// review (1–1000 chars; tovis-app PR #475). Returns the saved reply.
    @discardableResult
    public func upsertReviewReply(reviewId: String, body: String) async throws -> ProReviewItem.ProReviewReply {
        let payload = try JSONEncoder().encode(["body": body])
        let response: ProReviewReplyResponse = try await api.request(
            "/pro/reviews/\(reviewId)/reply", method: .put, body: payload
        )
        return response.reply
    }

    /// DELETE /api/v1/pro/reviews/{id}/reply — remove the pro's public response.
    public func deleteReviewReply(reviewId: String) async throws {
        try await api.requestVoid("/pro/reviews/\(reviewId)/reply", method: .delete)
    }

    /// PATCH /api/v1/pro/profile — sparse update; only the provided fields change.
    /// Pass an explicit value to set; omit to leave untouched. Returns the saved
    /// profile. Throws `APIError.server(409,…)` if the handle is taken.
    @discardableResult
    public func updateProfile(
        businessName: String?? = nil,
        bio: String?? = nil,
        location: String?? = nil,
        handle: String?? = nil,
        nameDisplay: String? = nil,
        avatarUrl: String?? = nil,
        instagramHandle: String?? = nil,
        tiktokHandle: String?? = nil,
        websiteUrl: String?? = nil
    ) async throws -> ProMyProfile {
        var fields: [String: JSONValue] = [:]
        if let businessName { fields["businessName"] = .stringOrNull(businessName) }
        if let bio { fields["bio"] = .stringOrNull(bio) }
        if let location { fields["location"] = .stringOrNull(location) }
        if let handle { fields["handle"] = .stringOrNull(handle) }
        if let nameDisplay { fields["nameDisplay"] = .string(nameDisplay) }
        if let avatarUrl { fields["avatarUrl"] = .stringOrNull(avatarUrl) }
        // Social presence (PR #478): the server treats "" as clear and
        // normalizes otherwise ("@tori" → "tori"; website coerced to https).
        if let instagramHandle { fields["instagramHandle"] = .stringOrNull(instagramHandle) }
        if let tiktokHandle { fields["tiktokHandle"] = .stringOrNull(tiktokHandle) }
        if let websiteUrl { fields["websiteUrl"] = .stringOrNull(websiteUrl) }

        let payload = try JSONEncoder().encode(fields)
        let response: ProMyProfileResponse = try await api.request(
            "/pro/profile", method: .patch, body: payload
        )
        return response.profile
    }

    /// GET /api/v1/pro/offerings → the pro's services (active + inactive).
    public func offerings() async throws -> [ProOfferingAdmin] {
        let response: ProOfferingsResponse = try await api.request("/pro/offerings")
        return response.offerings
    }

    /// PATCH /api/v1/pro/offerings/{id} — sparse update (e.g. toggle `isActive` or
    /// change a price/duration). Returns the updated offering.
    @discardableResult
    public func updateOffering(
        id: String,
        isActive: Bool? = nil,
        description: String?? = nil,
        offersInSalon: Bool? = nil,
        offersMobile: Bool? = nil,
        salonPriceStartingAt: String?? = nil,
        salonDurationMinutes: Int?? = nil,
        mobilePriceStartingAt: String?? = nil,
        mobileDurationMinutes: Int?? = nil
    ) async throws -> ProOfferingAdmin {
        var fields: [String: JSONValue] = [:]
        if let isActive { fields["isActive"] = .bool(isActive) }
        if let description { fields["description"] = .stringOrNull(description) }
        if let offersInSalon { fields["offersInSalon"] = .bool(offersInSalon) }
        if let offersMobile { fields["offersMobile"] = .bool(offersMobile) }
        if let salonPriceStartingAt { fields["salonPriceStartingAt"] = .stringOrNull(salonPriceStartingAt) }
        if let salonDurationMinutes { fields["salonDurationMinutes"] = .intOrNull(salonDurationMinutes) }
        if let mobilePriceStartingAt { fields["mobilePriceStartingAt"] = .stringOrNull(mobilePriceStartingAt) }
        if let mobileDurationMinutes { fields["mobileDurationMinutes"] = .intOrNull(mobileDurationMinutes) }

        let payload = try JSONEncoder().encode(fields)
        let response: ProOfferingResponse = try await api.request(
            "/pro/offerings/\(id)", method: .patch, body: payload
        )
        return response.offering
    }

    /// DELETE /api/v1/pro/offerings/{id} — soft-deletes (sets isActive=false).
    public func deleteOffering(id: String) async throws {
        try await api.requestVoid("/pro/offerings/\(id)", method: .delete)
    }

    /// GET /api/v1/pro/services/catalog → the addable service library tree + the
    /// pro's already-added offerings (so the picker can disable them).
    public func servicesCatalog() async throws -> ProServiceCatalog {
        try await api.request("/pro/services/catalog")
    }

    /// POST /api/v1/pro/offerings — add a service to the pro's menu. Returns the
    /// created offering.
    @discardableResult
    public func createOffering(
        serviceId: String,
        description: String?,
        customImageUrl: String?,
        offersInSalon: Bool,
        offersMobile: Bool,
        salonPriceStartingAt: String?,
        salonDurationMinutes: Int?,
        mobilePriceStartingAt: String?,
        mobileDurationMinutes: Int?
    ) async throws -> ProOfferingAdmin {
        var fields: [String: JSONValue] = [
            "serviceId": .string(serviceId),
            "offersInSalon": .bool(offersInSalon),
            "offersMobile": .bool(offersMobile),
            "description": .stringOrNull(description),
            "customImageUrl": .stringOrNull(customImageUrl),
            "salonPriceStartingAt": .stringOrNull(salonPriceStartingAt),
            "salonDurationMinutes": .intOrNull(salonDurationMinutes),
            "mobilePriceStartingAt": .stringOrNull(mobilePriceStartingAt),
            "mobileDurationMinutes": .intOrNull(mobileDurationMinutes),
        ]
        fields["title"] = .null
        let payload = try JSONEncoder().encode(fields)
        let response: ProOfferingResponse = try await api.request(
            "/pro/offerings", method: .post, body: payload
        )
        return response.offering
    }

    /// PATCH /api/v1/pro/offerings/{id} — set the custom image URL (after an
    /// SERVICE_IMAGE_PUBLIC upload). Returns the updated offering.
    @discardableResult
    public func setOfferingImage(id: String, customImageUrl: String?) async throws -> ProOfferingAdmin {
        let payload = try JSONEncoder().encode(["customImageUrl": JSONValue.stringOrNull(customImageUrl)])
        let response: ProOfferingResponse = try await api.request(
            "/pro/offerings/\(id)", method: .patch, body: payload
        )
        return response.offering
    }

    /// GET /api/v1/pro/offerings/{id}/add-ons → eligible + attached add-ons.
    public func addOns(offeringId: String) async throws -> ProAddOns {
        try await api.request("/pro/offerings/\(offeringId)/add-ons")
    }

    /// PUT /api/v1/pro/offerings/{id}/add-ons — replace the whole attached set.
    public func saveAddOns(offeringId: String, items: [ProAddOnInput]) async throws {
        let payload = try JSONEncoder().encode(["items": items])
        try await api.requestVoid("/pro/offerings/\(offeringId)/add-ons", method: .put, body: payload)
    }

    /// GET /api/v1/pro/profile/handle-available?handle= — live availability check
    /// for the vanity-link claim UI. The PATCH route stays authoritative; this is
    /// fast feedback. Returns status + message (+ suggestions when taken).
    public func handleAvailable(_ handle: String) async throws -> ProHandleAvailability {
        try await api.request(
            "/pro/profile/handle-available",
            query: [URLQueryItem(name: "handle", value: handle)]
        )
    }

    /// PATCH /api/v1/pro/profile including profession type + avatar (the fuller
    /// edit form). Mirrors the web Edit profile modal's PATCH body. Returns the
    /// saved profile.
    @discardableResult
    public func updateProfileFull(
        businessName: String,
        professionType: String,
        location: String,
        bio: String,
        avatarUrl: String,
        nameDisplay: String,
        handle: String?,
        instagramHandle: String,
        tiktokHandle: String,
        websiteUrl: String
    ) async throws -> ProMyProfile {
        var fields: [String: JSONValue] = [
            "businessName": .string(businessName),
            "professionType": .string(professionType),
            "location": .string(location),
            "bio": .string(bio),
            "avatarUrl": .string(avatarUrl),
            "nameDisplay": .string(nameDisplay),
            // Social presence (PR #478): "" clears; otherwise server-normalized
            // ("@tori" → "tori"; website coerced to https://).
            "instagramHandle": .string(instagramHandle),
            "tiktokHandle": .string(tiktokHandle),
            "websiteUrl": .string(websiteUrl),
        ]
        if let handle { fields["handle"] = .string(handle) }

        let payload = try JSONEncoder().encode(fields)
        let response: ProMyProfileResponse = try await api.request(
            "/pro/profile", method: .patch, body: payload
        )
        return response.profile
    }

    /// GET /api/v1/pro/payment-settings → the pro's payment settings (or nil until
    /// first save).
    public func paymentSettings() async throws -> ProPaymentSettings? {
        let response: ProPaymentSettingsResponse =
            try await api.request("/pro/payment-settings")
        return response.paymentSettings
    }

    /// PATCH /api/v1/pro/payment-settings — upsert + return the saved settings.
    /// Throws `APIError.server(400,…)` with a user-facing message on a business-rule
    /// violation (e.g. no method enabled, missing Venmo handle).
    @discardableResult
    public func updatePaymentSettings(
        _ update: ProPaymentSettingsUpdate
    ) async throws -> ProPaymentSettings? {
        let payload = try JSONEncoder().encode(update)
        let response: ProPaymentSettingsResponse = try await api.request(
            "/pro/payment-settings", method: .patch, body: payload
        )
        return response.paymentSettings
    }
}

/// A minimal JSON value so sparse PATCH bodies can carry explicit `null`s (which
/// `encodeIfPresent`-synthesised Encodables would otherwise drop). Only the cases
/// the pro write-paths need.
enum JSONValue: Encodable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case null

    static func stringOrNull(_ v: String?) -> JSONValue { v.map(JSONValue.string) ?? .null }
    static func intOrNull(_ v: Int?) -> JSONValue { v.map(JSONValue.int) ?? .null }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case .null: try c.encodeNil()
        }
    }
}
