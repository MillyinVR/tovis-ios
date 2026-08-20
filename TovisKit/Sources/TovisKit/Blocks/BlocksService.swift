import Foundation

/// The person block (App Store guideline 1.2 — a UGC app must let a user block
/// abusive users). Server: tovis-app `app/api/v1/blocks/`.
///
/// Its own service rather than a corner of `LooksService`, because a block is
/// about a PERSON, not a look: it hides that person's looks AND their comments,
/// and it is managed from Settings, not from the feed.
///
/// 🔴 The block is stored one-way but ENFORCED SYMMETRICALLY on the server —
/// neither party sees the other's looks or comments. Do not describe it in UI
/// copy as one-directional.
public final class BlocksService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// POST /api/v1/blocks — block the person behind `target`.
    ///
    /// Idempotent: a re-block swallows the unique violation server-side and
    /// returns the EXISTING row id, so the caller can always render Unblock.
    /// 404s `TARGET_NOT_FOUND` when nobody holds that handle/id — including a
    /// client record no person has ever signed into, which has no account to
    /// block. 400s `CANNOT_BLOCK_SELF`; the database refuses it too.
    @discardableResult
    public func block(_ target: BlockTarget) async throws -> BlockCreatedResponse {
        try await api.request(
            "/blocks",
            method: .post,
            body: try JSONEncoder().encode(target.requestBody)
        )
    }

    /// DELETE /api/v1/blocks/{blockId} — lift a block the viewer made.
    ///
    /// Keyed on the block ROW id, not the target's handle, because a blocked
    /// account can clear its handle afterwards and a block you cannot lift
    /// would be worse than the harassment it was meant to stop.
    @discardableResult
    public func unblock(blockId: String) async throws -> BlockRemovedResponse {
        try await api.request(
            "/blocks/\(blockId)",
            method: .delete
        )
    }

    /// GET /api/v1/blocks — the accounts the viewer has blocked, newest first.
    ///
    /// Only blocks the viewer MADE. Blocks RECEIVED also hide content, but
    /// surfacing them would tell the viewer who blocked them — which is exactly
    /// what a block exists to withhold.
    public func blockedAccounts() async throws -> [BlockedAccount] {
        let response: BlocksListResponse = try await api.request("/blocks")
        return response.blocks
    }
}
