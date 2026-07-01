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

    /// GET /api/v1/pro/finance/export?scope=&month= → raw CSV bytes (CPA /
    /// Schedule C). `scope` is "month" | "ytd" | "year"; month is "YYYY-MM".
    public func exportCsv(scope: String, month: String) async throws -> Data {
        try await api.requestVoid(
            "/pro/finance/export",
            method: .get,
            query: [
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "month", value: month),
            ]
        )
    }

    /// POST /api/v1/pro/finance/receipts/{id} — confirm a pending receipt into an
    /// expense (body is the same as an expense create).
    public func confirmReceipt(
        id: String,
        _ request: ProExpenseWriteRequest
    ) async throws {
        let body = try JSONEncoder().encode(request)
        _ = try await api.requestVoid(
            "/pro/finance/receipts/\(id)",
            method: .post,
            body: body
        )
    }

    /// DELETE /api/v1/pro/finance/receipts/{id} — dismiss a pending receipt.
    public func dismissReceipt(id: String) async throws {
        _ = try await api.requestVoid(
            "/pro/finance/receipts/\(id)",
            method: .delete
        )
    }

    /// GET /api/v1/pro/finance/export?format=pdf → the "Schedule C Ready" PDF
    /// (annual, expenses mapped to Schedule C line numbers).
    public func exportScheduleCPdf(month: String) async throws -> Data {
        try await api.requestVoid(
            "/pro/finance/export",
            method: .get,
            query: [
                URLQueryItem(name: "scope", value: "year"),
                URLQueryItem(name: "month", value: month),
                URLQueryItem(name: "format", value: "pdf"),
            ]
        )
    }
}
