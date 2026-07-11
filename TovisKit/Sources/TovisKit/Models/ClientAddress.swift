import Foundation

// Wire model for a client's saved address — GET/POST /api/v1/client/addresses.
// Mirrors `ClientAddressDTO` (lib/dto/clientAddress.ts). A SERVICE_ADDRESS (with
// geocoded lat/lng) is where a MOBILE booking happens; the booking flow lists and
// selects one before holding. Unknown keys are ignored.

public struct ClientAddress: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let kind: String           // "SEARCH_AREA" | "SERVICE_ADDRESS"
    public let label: String?
    public let isDefault: Bool
    public let formattedAddress: String?
    public let addressLine1: String?
    public let addressLine2: String?
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let countryCode: String?
    public let placeId: String?
    public let lat: Double?
    public let lng: Double?
    /// SEARCH_AREA only: the server-persisted discovery radius in miles (5–50),
    /// synced across devices. Nil for a SERVICE_ADDRESS or a search area saved
    /// before a radius was stored (older server / pre-sync row).
    public let radiusMiles: Int?
    public let createdAt: String
    public let updatedAt: String

    public var isServiceAddress: Bool { kind == "SERVICE_ADDRESS" }

    /// A SEARCH_AREA is the client's saved discovery origin (where "pros near you"
    /// searches from) — the server-persisted half of the web viewer location.
    public var isSearchArea: Bool { kind == "SEARCH_AREA" }

    /// A one-line label for the picker — the saved label, else the formatted
    /// address, else a street/city composite.
    public var displayLine: String {
        if let label, !label.isEmpty { return label }
        if let formattedAddress, !formattedAddress.isEmpty { return formattedAddress }
        let parts = [addressLine1, city, state].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Saved address" : parts.joined(separator: ", ")
    }

    /// The secondary line (street/city) shown under the label when a label exists.
    public var detailLine: String? {
        guard let label, !label.isEmpty else { return nil }
        if let formattedAddress, !formattedAddress.isEmpty { return formattedAddress }
        let parts = [addressLine1, city, state].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A Google Maps "search" URL for this address — the pin coordinates when we
    /// have them, else the formatted/typed address text. Mirrors the web card's
    /// `mapsHref`; nil when there's nothing to locate.
    public var mapsURL: URL? {
        let query: String
        if let lat, let lng {
            query = "\(lat),\(lng)"
        } else {
            let text = formattedAddress
                ?? [addressLine1, addressLine2, city, state, postalCode]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            guard !text.isEmpty else { return nil }
            query = text
        }
        var components = URLComponents(string: "https://www.google.com/maps/search/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: query),
        ]
        return components?.url
    }
}

// MARK: - Requests / responses

struct ClientAddressesResponse: Decodable, Sendable {
    let addresses: [ClientAddress]
}

struct ClientAddressResponse: Decodable, Sendable {
    let address: ClientAddress
}

/// POST /api/v1/client/addresses body for a new SERVICE_ADDRESS. When the address
/// came from Places (placeId + lat/lng + formattedAddress), the backend keeps it
/// as-is (already resolved); a bare typed address is geocoded server-side.
struct CreateClientAddressRequest: Encodable, Sendable {
    let kind: String
    let label: String?
    let formattedAddress: String?
    let addressLine1: String?
    let addressLine2: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let countryCode: String?
    let placeId: String?
    let lat: Double?
    let lng: Double?
    let isDefault: Bool?
    /// SEARCH_AREA discovery radius (miles). Omitted from the body when nil
    /// (synthesized encode drops nil), so a SERVICE_ADDRESS create is unchanged.
    var radiusMiles: Int? = nil
}

/// PATCH /api/v1/client/addresses/{id} body that touches only the SEARCH_AREA
/// discovery radius — every other field is omitted so the server keeps the saved
/// origin and just updates the radius (which then syncs across devices).
struct UpdateClientAddressRadiusRequest: Encodable, Sendable {
    let radiusMiles: Int
}

/// PATCH /api/v1/client/addresses/{id} body for editing a saved SERVICE_ADDRESS.
///
/// `label` + `addressLine2` (apt/unit) are ALWAYS emitted — an explicit JSON `null`
/// clears the field (an *absent* key reads as "no change" server-side, so nil is
/// encoded as null, matching the web edit form). `isDefault` is always sent.
///
/// The geocoded address anchor (formattedAddress + city/state/zip + placeId +
/// lat/lng) is emitted **only** when the user re-picks a new address (`place` set):
/// omitting it makes the server keep the existing resolved address and short-circuit
/// with no re-geocode (`resolveServiceAddressValues` sees it's already resolved). A
/// re-picked autocomplete result already carries coordinates, so it also skips the
/// geocode — just swapping the stored address.
struct UpdateClientAddressRequest: Encodable, Sendable {
    let label: String?
    let addressLine2: String?
    let isDefault: Bool
    let place: PlaceReplacement?

    /// The full anchor of a freshly picked Places result (carries coordinates, so
    /// the server keeps them rather than re-geocoding).
    struct PlaceReplacement: Sendable {
        let formattedAddress: String
        let city: String?
        let state: String?
        let postalCode: String?
        let countryCode: String?
        let placeId: String
        let lat: Double
        let lng: Double
    }

    enum CodingKeys: String, CodingKey {
        case label, addressLine2, isDefault
        case formattedAddress, city, state, postalCode, countryCode, placeId, lat, lng
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeNullable(&c, label, forKey: .label)
        try encodeNullable(&c, addressLine2, forKey: .addressLine2)
        try c.encode(isDefault, forKey: .isDefault)

        if let place {
            try c.encode(place.formattedAddress, forKey: .formattedAddress)
            try encodeNullable(&c, place.city, forKey: .city)
            try encodeNullable(&c, place.state, forKey: .state)
            try encodeNullable(&c, place.postalCode, forKey: .postalCode)
            try encodeNullable(&c, place.countryCode, forKey: .countryCode)
            try c.encode(place.placeId, forKey: .placeId)
            try c.encode(place.lat, forKey: .lat)
            try c.encode(place.lng, forKey: .lng)
        }
    }

    private func encodeNullable(
        _ c: inout KeyedEncodingContainer<CodingKeys>,
        _ value: String?,
        forKey key: CodingKeys
    ) throws {
        if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
    }
}

/// PATCH body that touches only the default flag — every other key is omitted so the
/// server keeps the address as-is and just promotes this row to the default for its
/// kind (demoting the previous default). Used by the "Make default" row action.
struct SetDefaultClientAddressRequest: Encodable, Sendable {
    let isDefault: Bool
}

/// DELETE /api/v1/client/addresses/{id} response envelope.
struct DeletedClientAddressResponse: Decodable, Sendable {
    let deleted: Bool
    let id: String
}
