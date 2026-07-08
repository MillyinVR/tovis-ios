import Foundation

// Google Places — proxied through the backend (the Google key is server-only, so
// the app never calls Google directly). Two calls: autocomplete (text → place
// predictions) and details (placeId → exact address + coordinates). Used to give
// the mobile service-address form real autocomplete + precise geocoding.
// Mirrors app/api/v1/google/places/{autocomplete,details}.

public struct PlacePrediction: Decodable, Sendable, Identifiable {
    public let placeId: String
    public let description: String
    public let mainText: String
    public let secondaryText: String

    public var id: String { placeId }
}

public struct PlaceDetails: Decodable, Sendable, Equatable {
    public let placeId: String
    public let formattedAddress: String
    public let lat: Double
    public let lng: Double
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let countryCode: String?
}

struct PlacesAutocompleteResponse: Decodable, Sendable {
    let predictions: [PlacePrediction]
}

struct PlaceDetailsResponse: Decodable, Sendable {
    let place: PlaceDetails
}

// GET /api/v1/google/geocode — `{ geo: { lat, lng, postalCode, city, state,
// countryCode } }`. Mirrors app/api/v1/google/geocode.
struct GeocodeResponse: Decodable, Sendable {
    struct Geo: Decodable, Sendable {
        let lat: Double?
        let lng: Double?
        let postalCode: String?
        let city: String?
        let state: String?
        let countryCode: String?
    }
    let geo: Geo?
}

// GET /api/v1/google/timezone — `{ timeZoneId }`.
struct TimezoneResponse: Decodable, Sendable {
    let timeZoneId: String?
}

public final class PlacesService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/google/places/autocomplete — address predictions for `input`.
    /// Pass the same `sessionToken` to autocomplete + the follow-up details call
    /// (Google session billing). `lat`/`lng` bias results toward the user.
    public func autocomplete(
        input: String,
        sessionToken: String,
        lat: Double? = nil,
        lng: Double? = nil,
        kind: String = "ADDRESS"
    ) async throws -> [PlacePrediction] {
        var query = [
            URLQueryItem(name: "input", value: input),
            URLQueryItem(name: "sessionToken", value: sessionToken),
            URLQueryItem(name: "kind", value: kind),
        ]
        if let lat { query.append(URLQueryItem(name: "lat", value: String(lat))) }
        if let lng { query.append(URLQueryItem(name: "lng", value: String(lng))) }

        let response: PlacesAutocompleteResponse = try await api.request(
            "/google/places/autocomplete", query: query
        )
        return response.predictions
    }

    /// GET /api/v1/google/places/details — exact address + coordinates for a
    /// picked prediction. Reuse the autocomplete `sessionToken` to close the
    /// billing session.
    public func details(
        placeId: String,
        sessionToken: String
    ) async throws -> PlaceDetails {
        let response: PlaceDetailsResponse = try await api.request(
            "/google/places/details",
            query: [
                URLQueryItem(name: "placeId", value: placeId),
                URLQueryItem(name: "sessionToken", value: sessionToken),
            ]
        )
        return response.place
    }

    /// Resolve a US ZIP to the coordinates + IANA timezone the client signup's
    /// `CLIENT_ZIP` payload needs. Two proxied Google calls (geocode → timezone),
    /// mirroring the web client signup's confirm-ZIP step. Unauthenticated: this
    /// runs before an account (and token) exists.
    public func resolveClientZip(postalCode: String) async throws -> ClientSignupLocation {
        let geoResponse: GeocodeResponse = try await api.request(
            "/google/geocode",
            query: [
                URLQueryItem(name: "postalCode", value: postalCode),
                URLQueryItem(name: "components", value: "country:us"),
            ],
            authenticated: false
        )

        guard let geo = geoResponse.geo,
              let lat = geo.lat,
              let lng = geo.lng,
              let resolvedPostal = geo.postalCode, !resolvedPostal.isEmpty
        else {
            throw APIError.server(
                status: 422,
                message: "We couldn't confirm that ZIP code. Please check it and try again.",
                code: "ZIP_UNRESOLVED"
            )
        }

        let tzResponse: TimezoneResponse = try await api.request(
            "/google/timezone",
            query: [
                URLQueryItem(name: "lat", value: String(lat)),
                URLQueryItem(name: "lng", value: String(lng)),
            ],
            authenticated: false
        )

        guard let timeZoneId = tzResponse.timeZoneId, !timeZoneId.isEmpty else {
            throw APIError.server(
                status: 422,
                message: "We couldn't determine your timezone. Please try again.",
                code: "TIMEZONE_UNRESOLVED"
            )
        }

        return ClientSignupLocation(
            postalCode: resolvedPostal,
            city: geo.city,
            state: geo.state,
            countryCode: geo.countryCode,
            lat: lat,
            lng: lng,
            timeZoneId: timeZoneId
        )
    }
}
