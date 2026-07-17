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

    // MARK: - Search area (discovery origin)

    /// The saved SEARCH_AREA — the client's discovery origin — default first, or nil
    /// if none is set. Collapses to the single active area; DiscoverView seeds from
    /// this and only the default drives "pros near you".
    public func searchArea() async throws -> ClientAddress? {
        try await searchAreas().first
    }

    /// ALL saved SEARCH_AREA rows, active (default) first then newest — every area
    /// the client saved on any device. Unlike `searchArea()` this surfaces the full
    /// set so the discovery settings can list them and switch the active one (web
    /// parity with the Settings → Addresses "Search areas" list; a secondary area
    /// created on web is otherwise invisible on iOS). The active area is always the
    /// default, so `.first` here equals `searchArea()`.
    public func searchAreas() async throws -> [ClientAddress] {
        try await list()
            .filter { $0.isSearchArea }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.createdAt > rhs.createdAt
            }
    }

    /// Set (or replace) the discovery origin from a picked Places AREA result. Both
    /// the origin (lat/lng/placeId/label) and the search `radiusMiles` are
    /// server-persisted on the SEARCH_AREA `ClientAddress`, so they follow the client
    /// across devices — parity with the web default SEARCH_AREA row.
    ///
    /// Creates a fresh default SEARCH_AREA (the create tx demotes any prior default),
    /// then best-effort deletes the row it replaced — so exactly one SEARCH_AREA row
    /// survives, defined wholly by the new pick (no stale field carry-over, no PATCH
    /// label-clobber). `replacing` is the id returned by a prior `searchArea()`.
    public func saveSearchArea(
        from place: PlaceDetails,
        radiusMiles: Int? = nil,
        replacing existingId: String? = nil
    ) async throws -> ClientAddress {
        let created = try await create(CreateClientAddressRequest(
            kind: "SEARCH_AREA",
            label: nil,
            formattedAddress: place.formattedAddress,
            addressLine1: nil,
            addressLine2: nil,
            city: place.city,
            state: place.state,
            postalCode: place.postalCode,
            countryCode: place.countryCode,
            placeId: place.placeId,
            lat: place.lat,
            lng: place.lng,
            isDefault: true,
            radiusMiles: radiusMiles
        ))

        if let existingId, existingId != created.id {
            // The new row is already the default; drop the one it superseded.
            try? await delete(id: existingId)
        }

        return created
    }

    /// PATCH just the SEARCH_AREA's discovery radius (miles) — keeps the saved
    /// origin, updates only the radius so it syncs across devices. Used when the
    /// client re-tunes the radius while an area is already set.
    @discardableResult
    public func setSearchAreaRadius(
        id: String,
        radiusMiles: Int
    ) async throws -> ClientAddress {
        try await patch(id: id, UpdateClientAddressRadiusRequest(radiusMiles: radiusMiles))
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

    /// PATCH /api/v1/client/addresses/{id} — edit a saved SERVICE_ADDRESS's label,
    /// apt/unit, and default flag, optionally replacing the underlying address with a
    /// freshly picked Places result.
    ///
    /// `place: nil` keeps the existing geocoded address (the server sees it's already
    /// resolved and skips any re-geocode); passing a picked `place` swaps it. A nil
    /// `label`/`apt` CLEARS that field (an explicit JSON null, matching the web form).
    /// Throws an APIError with a user-facing message when the address can't be verified.
    public func updateServiceAddress(
        id: String,
        label: String?,
        apt: String?,
        isDefault: Bool,
        place: PlaceDetails? = nil
    ) async throws -> ClientAddress {
        let replacement = place.map { picked in
            UpdateClientAddressRequest.PlaceReplacement(
                formattedAddress: picked.formattedAddress,
                city: picked.city,
                state: picked.state,
                postalCode: picked.postalCode,
                countryCode: picked.countryCode,
                placeId: picked.placeId,
                lat: picked.lat,
                lng: picked.lng
            )
        }
        return try await patch(id: id, UpdateClientAddressRequest(
            label: label,
            addressLine2: apt,
            isDefault: isDefault,
            place: replacement
        ))
    }

    /// PATCH /api/v1/client/addresses/{id} with only `{ isDefault: true }` — promote an
    /// address to the default for its kind without touching any other field (the server
    /// demotes the previous default). Works for either kind.
    public func setDefault(id: String) async throws -> ClientAddress {
        try await patch(id: id, SetDefaultClientAddressRequest(isDefault: true))
    }

    /// DELETE /api/v1/client/addresses/{id} — remove a saved address. When it was the
    /// default for its kind, the server promotes the next-oldest as the new default.
    public func delete(id: String) async throws {
        try await api.requestVoid("/client/addresses/\(id)", method: .delete)
    }

    private func patch<Body: Encodable & Sendable>(
        id: String,
        _ body: Body
    ) async throws -> ClientAddress {
        let payload = try JSONEncoder.canonical.encode(body)
        let response: ClientAddressResponse = try await api.request(
            "/client/addresses/\(id)", method: .patch, body: payload
        )
        return response.address
    }
}
