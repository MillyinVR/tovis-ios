import Foundation

/// PRO workspace — the Finance & Tax tab (`GET /pro/finance`, tovis-app) and its
/// manual-expense CRUD. The finance response is a superset of the Overview
/// view-model. Authenticated; PRO-only (CLIENT tokens 403).
public final class ProFinanceService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/finance?month= → the finance summary + retained Overview
    /// stats. Pass nil for the current month. Month format is "YYYY-MM".
    public func finance(month: String? = nil) async throws -> ProFinanceResponse {
        let query = month.map { [URLQueryItem(name: "month", value: $0)] }
        return try await api.request("/pro/finance", query: query)
    }

    /// POST /api/v1/pro/finance/expenses — add a tracked expense.
    public func createExpense(_ request: ProExpenseWriteRequest) async throws {
        let body = try JSONEncoder().encode(request)
        _ = try await api.requestVoid(
            "/pro/finance/expenses",
            method: .post,
            body: body
        )
    }

    /// PATCH /api/v1/pro/finance/expenses/{id} — edit a tracked expense.
    public func updateExpense(
        id: String,
        _ request: ProExpenseWriteRequest
    ) async throws {
        let body = try JSONEncoder().encode(request)
        _ = try await api.requestVoid(
            "/pro/finance/expenses/\(id)",
            method: .patch,
            body: body
        )
    }

    /// DELETE /api/v1/pro/finance/expenses/{id} — remove a tracked expense.
    public func deleteExpense(id: String) async throws {
        _ = try await api.requestVoid(
            "/pro/finance/expenses/\(id)",
            method: .delete
        )
    }
}
