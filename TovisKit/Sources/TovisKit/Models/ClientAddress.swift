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
    public let createdAt: String
    public let updatedAt: String

    public var isServiceAddress: Bool { kind == "SERVICE_ADDRESS" }

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
}

// MARK: - Requests / responses

struct ClientAddressesResponse: Decodable, Sendable {
    let addresses: [ClientAddress]
}

struct ClientAddressResponse: Decodable, Sendable {
    let address: ClientAddress
}

/// POST /api/v1/client/addresses body for a new SERVICE_ADDRESS. The backend
/// geocodes the typed address on save (fills formattedAddress + lat/lng), so the
/// client sends the street + a location anchor (city/state/postal).
struct CreateClientAddressRequest: Encodable, Sendable {
    let kind: String
    let label: String?
    let addressLine1: String?
    let addressLine2: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let isDefault: Bool?
}
