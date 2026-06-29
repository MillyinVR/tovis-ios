import Foundation

/// Client saved addresses — list + create. The MOBILE booking flow uses this to
/// pick (or add) the SERVICE_ADDRESS a hold is placed against. Authenticated
/// (bearer token; client only). Mirrors app/api/v1/client/addresses.
public final class AddressesService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/addresses — all saved addresses (both kinds).
    public func list() async throws -> [ClientAddress] {
        let response: ClientAddressesResponse = try await api.request("/client/addresses")
        return response.addresses
    }

    /// Just the SERVICE_ADDRESS rows (where MOBILE bookings can be performed),
    /// default first.
    public func serviceAddresses() async throws -> [ClientAddress] {
        try await list()
            .filter { $0.isServiceAddress }
            .sorted { $0.isDefault && !$1.isDefault }
    }

    /// POST /api/v1/client/addresses — add a SERVICE_ADDRESS. The backend geocodes
    /// the typed address on save (fills formattedAddress + lat/lng). Throws an
    /// APIError with a user-facing message if the address can't be verified.
    public func createServiceAddress(
        label: String?,
        addressLine1: String,
        addressLine2: String?,
        city: String,
        state: String,
        postalCode: String,
        isDefault: Bool = false
    ) async throws -> ClientAddress {
        let payload = try JSONEncoder().encode(CreateClientAddressRequest(
            kind: "SERVICE_ADDRESS",
            label: label,
            addressLine1: addressLine1,
            addressLine2: addressLine2,
            city: city,
            state: state,
            postalCode: postalCode,
            isDefault: isDefault
        ))
        let response: ClientAddressResponse = try await api.request(
            "/client/addresses", method: .post, body: payload
        )
        return response.address
    }
}
