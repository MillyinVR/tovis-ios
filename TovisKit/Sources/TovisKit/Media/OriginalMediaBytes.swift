// The pro's original file, fetched to be handed straight to their photo library.
//
// 🔴 This deliberately does NOT decode. Every alternative — `UIImage(data:)` and
// re-encode, `ImageDownsample`, the export renderer — produces a NEW file, and a
// new file has lost the EXIF: the capture date, the orientation tag the web
// gallery reads, the lens and exposure a pro may one day want, the colour profile.
// A save-to-Photos is the pro leaving with their own photograph, so the only
// correct implementation is the one that changes nothing.
//
// So the whole job is: get the bytes, keep the bytes. It is a named seam rather
// than an inline `URLSession.data(from:)` at four call sites because "don't
// re-encode this" is a rule that has to live somewhere it can be read and tested.
import Foundation

public enum OriginalMediaBytesError: Error, Equatable {
    case http(status: Int)
    case empty
}

public enum OriginalMediaBytes {
    /// The asset's bytes, exactly as served. `session` is injectable so the
    /// no-re-encode guarantee is testable.
    public static func fetch(
        _ url: URL,
        using session: URLSession = .shared
    ) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OriginalMediaBytesError.http(status: http.statusCode)
        }
        guard !data.isEmpty else { throw OriginalMediaBytesError.empty }
        return data
    }
}
