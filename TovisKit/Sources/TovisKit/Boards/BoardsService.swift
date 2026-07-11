import Foundation

/// Client boards — the detail / create / share surface behind the "Me" tab's
/// BOARDS grid. Authenticated (bearer token; client only). Mirrors
/// `app/api/v1/boards`. The list itself rides the `/me` payload (see
/// `MeService.fetch()`); this service adds:
///   • detail(id:)                  → GET   /boards/{id}   (looks grid + share state)
///   • create(name:visibility:…)    → POST  /boards        (new board, 201)
///   • updateVisibility(id:isShared:) → PATCH /boards/{id}  (share ↔ private toggle)
///
/// Board deletion + name/answers edits aren't exposed here — the web board detail
/// page is view + share only, and this keeps native at parity.
public final class BoardsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/boards/{id} — the owner's board with its saved looks and the
    /// slug/visibility the share control needs. 403/404 surface as `APIError`.
    public func detail(id: String) async throws -> Board {
        let response: BoardDetailResponse = try await api.request("/boards/\(id)")
        return response.board
    }

    /// POST /api/v1/boards — create a board. `type` defaults to "GENERAL";
    /// `eventDate` (`YYYY-MM-DD`) is only meaningful for bridal/prom boards and is
    /// omitted otherwise. Returns the created board's detail (the route responds
    /// 201 with the same `{ board }` envelope as GET). Throws with a user-facing
    /// message on a duplicate name / invalid input.
    public func create(
        name: String,
        visibility: String,
        type: String,
        eventDate: String? = nil
    ) async throws -> Board {
        let payload = try JSONEncoder.canonical.encode(CreateBoardRequest(
            name: name,
            visibility: visibility,
            type: type,
            eventDate: eventDate
        ))
        let response: BoardDetailResponse = try await api.request(
            "/boards", method: .post, body: payload
        )
        return response.board
    }

    /// PATCH /api/v1/boards/{id} — flip the board between Shared (public link) and
    /// Private. Returns the updated board (so the caller can read back the
    /// authoritative slug/visibility). This is the "share" write.
    public func updateVisibility(id: String, isShared: Bool) async throws -> Board {
        let payload = try JSONEncoder.canonical.encode(
            UpdateBoardVisibilityRequest(visibility: isShared ? "SHARED" : "PRIVATE")
        )
        let response: BoardDetailResponse = try await api.request(
            "/boards/\(id)", method: .patch, body: payload
        )
        return response.board
    }
}
