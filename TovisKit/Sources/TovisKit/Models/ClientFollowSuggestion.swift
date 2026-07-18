import Foundation

/// A "creator to follow" suggestion — GET /api/v1/client/follow-suggestions.
///
/// The server ranks the **client** authors whose looks the viewer has liked
/// (most-liked first, ties broken by handle), excluding the viewer and anyone
/// they already follow. So these are client→client suggestions addressed by
/// `handle`, the same addressing `/u/{handle}` and the follow toggle use — not
/// pro suggestions, which are a different graph keyed by professional id.
///
/// Because the list is already filtered server-side, a followed creator simply
/// drops out of the next response; there is no "unfollow" affordance to model.
public struct ClientFollowSuggestion: Decodable, Sendable, Identifiable, Hashable {
    public let clientId: String
    public let handle: String
    public let avatarUrl: String?
    /// How many of the viewer's liked looks this creator authored — the reason
    /// they're being suggested. Defaults to 0 if a future server omits it.
    public let likedLookCount: Int

    public var id: String { clientId }

    public init(clientId: String, handle: String, avatarUrl: String?, likedLookCount: Int) {
        self.clientId = clientId
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.likedLookCount = likedLookCount
    }
}

/// The envelope, decoded **defensively**: one malformed row must not blank the
/// whole rail (and with it the Following tab it sits on). Rows missing the two
/// fields the UI cannot work without — `clientId` to key on, `handle` to address
/// the follow and the profile link — are dropped rather than thrown, and a
/// missing `items` decodes as empty.
public struct ClientFollowSuggestionsResponse: Decodable, Sendable {
    public let items: [ClientFollowSuggestion]

    private enum CodingKeys: String, CodingKey { case items }

    /// A row whose every field is optional, so a decode failure is confined to
    /// the row instead of taking the array with it.
    private struct LenientRow: Decodable {
        let clientId: String?
        let handle: String?
        let avatarUrl: String?
        let likedLookCount: Int?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([LenientRow].self, forKey: .items) ?? []

        items = rows.compactMap { row in
            guard
                let clientId = row.clientId?.trimmedOrNil,
                let handle = row.handle?.trimmedOrNil
            else { return nil }

            return ClientFollowSuggestion(
                clientId: clientId,
                handle: handle,
                avatarUrl: row.avatarUrl?.trimmedOrNil,
                likedLookCount: max(0, row.likedLookCount ?? 0)
            )
        }
    }
}
