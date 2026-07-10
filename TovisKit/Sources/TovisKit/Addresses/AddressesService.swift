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

    /// POST /api/v1/client/addresses — add a SERVICE_ADDRESS from a typed form.
    /// The backend geocodes it on save (fills formattedAddress + lat/lng). Throws
    /// an APIError with a user-facing message if the address can't be verified.
    public func createServiceAddress(
        label: String?,
        addressLine1: String,
        addressLine2: String?,
        city: String,
        state: String,
        postalCode: String,
        isDefault: Bool = false
    ) async throws -> ClientAddress {
        try await create(CreateClientAddressRequest(
            kind: "SERVICE_ADDRESS",
            label: label,
            formattedAddress: nil,
            addressLine1: addressLine1,
            addressLine2: addressLine2,
            city: city,
            state: state,
            postalCode: postalCode,
            countryCode: nil,
            placeId: nil,
            lat: nil,
            lng: nil,
            isDefault: isDefault
        ))
    }

    /// Add a SERVICE_ADDRESS from a picked Places result — already resolved
    /// (placeId + exact lat/lng), so the backend keeps the coordinates as-is
    /// instead of re-geocoding. `apt` is the optional unit the user adds on top.
    public func createServiceAddress(
        from place: PlaceDetails,
        label: String?,
        apt: String? = nil,
        isDefault: Bool = false
    ) async throws -> ClientAddress {
        try await create(CreateClientAddressRequest(
            kind: "SERVICE_ADDRESS",
            label: label,
            formattedAddress: place.formattedAddress,
            addressLine1: nil,
            addressLine2: apt,
            city: place.city,
            state: place.state,
            postalCode: place.postalCode,
            countryCode: place.countryCode,
            placeId: place.placeId,
            lat: place.lat,
            lng: place.lng,
            isDefault: isDefault
        ))
    }

    private func create(_ request: CreateClientAddressRequest) async throws -> ClientAddress {
        let payload = try JSONEncoder.canonical.encode(request)
        let response: ClientAddressResponse = try await api.request(
            "/client/addresses", method: .post, body: payload
        )
        return response.address
    }
}
