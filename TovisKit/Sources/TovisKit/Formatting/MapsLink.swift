import Foundation

/// 🔴 Tori's standing rule: **every address is a maps link.** An address a client
/// can read but not tap is an address they have to retype into another app while
/// standing on a street corner.
///
/// One builder so the surfaces can't drift on which maps app opens: a Google
/// Maps *search* URL, keyed on the pin when we have coordinates and on the
/// address text otherwise. `ClientAddress.mapsURL` delegates here.
///
/// ⚠️ A booking has TWO possible addresses and they belong to different people:
/// an IN-SALON booking's is the PRO's location, a MOBILE booking's is the
/// CLIENT's own service address. Resolve which one before asking for a link.
public enum MapsLink {
    /// nil when there is nothing to locate — no coordinates and no address text.
    /// Callers render plain text then, rather than a link that goes nowhere.
    public static func url(address: String?, lat: Double? = nil, lng: Double? = nil) -> URL? {
        let query: String

        if let lat, let lng {
            query = "\(lat),\(lng)"
        } else {
            guard let text = address?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
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
