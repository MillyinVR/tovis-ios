import Foundation

/// Native client for the Founders Portal. Room eligibility is never inferred
/// here: every screen renders only the server-filtered `FounderPortal.rooms`.
public final class FoundersService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    public func portal() async throws -> FounderPortal {
        let response: FounderPortalResponse = try await api.request("/founders/portal")
        return response.portal
    }

    public func messages(room: FounderRoomKey, cursor: String? = nil) async throws -> [FounderMessage] {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] }
        let response: FounderMessagesResponse = try await api.request(
            "/founders/rooms/\(room.rawValue)/messages",
            query: query
        )
        return response.messages
    }

    public func send(
        room: FounderRoomKey,
        body: String,
        kind: FounderMessageKind,
        replyToId: String? = nil
    ) async throws -> FounderMessage {
        let payload = try JSONEncoder.canonical.encode(
            FounderMessageCreateRequest(body: body, kind: kind, replyToId: replyToId)
        )
        let response: FounderMessageCreateResponse = try await api.request(
            "/founders/rooms/\(room.rawValue)/messages",
            method: .post,
            body: payload
        )
        return response.message
    }

    public func markRead(room: FounderRoomKey) async throws {
        try await api.requestVoid("/founders/rooms/\(room.rawValue)/read", method: .post)
    }

    public func report(messageId: String, reason: FounderMessageReportReason = .other) async throws {
        let payload = try JSONEncoder.canonical.encode(
            FounderReportRequest(reason: reason, details: nil)
        )
        let _: FounderReportResponse = try await api.request(
            "/founders/messages/\(messageId)/report",
            method: .post,
            body: payload
        )
    }

    public func adminSummary() async throws -> FounderAdminSummary {
        let response: FounderAdminSummaryResponse = try await api.request("/founders/admin")
        return response.summary
    }

    public func enrollProfessional(email: String, specialty: FounderSpecialty) async throws {
        let payload = try JSONEncoder.canonical.encode(
            FounderProfessionalEnrollmentRequest(email: email, specialty: specialty)
        )
        let _: FounderEnrollmentResponse = try await api.request(
            "/founders/admin",
            method: .post,
            body: payload
        )
    }

    public func enrollClient(email: String, sponsorEmail: String) async throws {
        let payload = try JSONEncoder.canonical.encode(
            FounderClientEnrollmentRequest(email: email, sponsorEmail: sponsorEmail)
        )
        let _: FounderEnrollmentResponse = try await api.request(
            "/founders/admin",
            method: .post,
            body: payload
        )
    }

    public func moderateReport(reportId: String, hideMessage: Bool) async throws {
        let payload = try JSONEncoder.canonical.encode(
            FounderModerationRequest(
                reportId: reportId,
                action: hideMessage ? "HIDE" : "RESOLVE"
            )
        )
        let _: FounderModerationResponse = try await api.request(
            "/founders/admin",
            method: .patch,
            body: payload
        )
    }
}
