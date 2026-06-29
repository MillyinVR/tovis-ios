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

public struct PlaceDetails: Decodable, Sendable {
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
}
