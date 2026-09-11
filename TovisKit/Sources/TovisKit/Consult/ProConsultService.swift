import Foundation

public struct ProConsultQueue: Decodable, Sendable {
    public struct Item: Decodable, Sendable, Identifiable {
        public let consultId: String
        public let clientName: String
        public let version: Int
        public let awaitingAnalysis: Bool
        public let clientConfirmed: Bool
        public let professionalConfirmed: Bool
        public let appointmentStatus: String?
        public let scheduledFor: String?
        public let changes: [String]
        public var id: String { consultId }
    }
    public let items: [Item]
    public let nextCursor: String?
}

public struct ProConsultInspiration: Decodable, Sendable {
    public struct Detail: Decodable, Sendable { public let clientWords: String; public let sentiment: String }
    public let referenceNote: String
    public let exactClientDetails: [Detail]
}

public struct ProConsultBrief: Decodable, Sendable {
    public let sourceAnalysisRevisionId: String?
    public let suitability: ProSuitability?
    public var currentSuitability: ProSuitability? {
        guard let sourceAnalysisRevisionId,
              suitability?.analysisRevisionId == sourceAnalysisRevisionId else { return nil }
        return suitability
    }
    public let aiObservations: ConsultAIObservations?
    public let safetyFlags: [ConsultSafetyFlag]?
    public let achievabilityDirection: ConsultAchievabilityDirection?
    public let recommendationDirections: [ConsultRecommendationDirection]?
    public let serviceEstimate: ProConsultServiceEstimate?
    public let planVersion: Int?
    public let planChanges: [ConsultPlanDiffEntry]?
    public let feedback: ProConsultFeedback?
    public let mentor: ConsultMentor?
    public let inspiration: ProConsultInspiration?
    /// C2-4 — the questions this professional asked the client from this
    /// Brief, oldest first, with answers where they exist. Optional on the
    /// wire: a server that predates it sends nothing and the Brief shows no
    /// "Ask a follow-up" section, which is the truth on that server.
    public let proFollowUps: [ProConsultFollowUp]?
    /// C2-6a — the one-line synthesis at the top of the Brief: "Client wants
    /// X because Y. Must preserve Z and avoid W.", composed by the server from
    /// the client's own taps and answers. Optional on the wire: a server that
    /// predates it sends nothing and the Brief shows no line, which is the
    /// truth on that server. Null when the server had nothing to say.
    public let topLine: String?

    public let consultId: String
    public let lookPlan: ConsultLookPlan?
    public let lookBrief: ConsultLookBriefVersion?
    public let clientIntake: [ConsultClientIntakeItem]
    public let profile: ConsultFeatureProfile
    public let styleDirections: [ConsultStyleDirection]
}

public struct ProConsultPhotos: Decodable, Sendable {
    public struct Capture: Decodable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let url: URL
    }
    public let captures: [Capture]
    public let inspirationUrl: URL?
    public let expiresInSeconds: Int
}

public struct ProConsultTranscript: Decodable, Sendable {
    public struct Event: Decodable, Sendable, Identifiable {
        public struct Item: Decodable, Sendable { public let label: String; public let value: String }
        public let id: String
        public let createdAt: String
        public let title: String
        public let items: [Item]
        public let unavailable: Bool
    }
    public let consultId: String
    public let events: [Event]
    public let nextCursor: String?
    public let historyNote: String
}

/// All identities, prices and version guards are resolved again by the server.
public final class ProConsultService: Sendable {
    private let api: APIClient
    public init(api: APIClient) { self.api = api }
    /// `/pro/consults/{id}` — every pro consult resource hangs off this one root.
    private func consultPath(_ id: String) throws -> String {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))), !escaped.isEmpty else { throw URLError(.badURL) }
        return "/pro/consults/\(escaped)"
    }
    private func path(_ id: String) throws -> String { try consultPath(id) + "/look-plan" }
    public func queue(cursor: String? = nil) async throws -> ProConsultQueue {
        try await api.request("/pro/consults", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] })
    }
    public func brief(id: String) async throws -> ProConsultBrief {
        struct Response: Decodable { let brief: ProConsultBrief }
        let result: Response = try await api.request(path(id))
        return result.brief
    }
    public func transcript(id: String, cursor: String? = nil) async throws -> ProConsultTranscript {
        struct Response: Decodable { let transcript: ProConsultTranscript }
        let result: Response = try await api.request(try consultPath(id) + "/transcript",
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] })
        guard result.transcript.consultId == id else { throw APIError.invalidResponse }
        return result.transcript
    }
    public func photos(id: String) async throws -> ProConsultPhotos { try await api.request(path(id) + "/photos") }
    public func confirm(id: String, version: Int) async throws {
        struct Body: Encodable { let expectedVersion: Int }
        try await api.requestVoid(path(id) + "/acknowledge", method: .post, body: JSONEncoder().encode(Body(expectedVersion: version)))
    }
    private struct Adjustment: Encodable {
            let field: String
            let value: String
            let pathIndex: Int
            let visitIndex: Int?
            let offeringId: String?
            let locationType: String?
            let reason: String?
            enum CodingKeys: String, CodingKey { case field, value, pathIndex, visitIndex, offeringId, locationType, reason }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(field, forKey: .field); try c.encode(value, forKey: .value)
                try c.encode(pathIndex, forKey: .pathIndex); try c.encode(visitIndex, forKey: .visitIndex)
                try c.encode(offeringId, forKey: .offeringId); try c.encode(locationType, forKey: .locationType)
                if let reason { try c.encode(reason, forKey: .reason) } else { try c.encodeNil(forKey: .reason) }
            }
        }
    public func expectations(id: String, version: Int, pathIndex: Int, value: String) async throws {
        struct Body: Encodable { let expectedVersion: Int; let idempotencyKey: String; let adjustments: [Adjustment] }
        let body = Body(expectedVersion: version, idempotencyKey: UUID().uuidString, adjustments: [
            Adjustment(field: "EXPECTATIONS", value: value, pathIndex: pathIndex, visitIndex: nil,
                       offeringId: nil, locationType: nil, reason: nil),
        ])
        try await api.requestVoid(path(id) + "/adjust", method: .post, body: JSONEncoder().encode(body))
    }
    public func adjust(id: String, version: Int, pathIndex: Int, visitIndex: Int, offeringId: String,
                       locationType: String, price: String?, minutes: String?, reason: String?) async throws {
        struct Body: Encodable { let expectedVersion: Int; let idempotencyKey: String; let adjustments: [Adjustment] }
        let body = try JSONEncoder().encode(Body(expectedVersion: version, idempotencyKey: UUID().uuidString, adjustments: [
            price.map { Adjustment(field: "PRICE", value: $0, pathIndex: pathIndex, visitIndex: visitIndex, offeringId: offeringId, locationType: locationType, reason: reason) },
            minutes.map { Adjustment(field: "DURATION", value: $0, pathIndex: pathIndex, visitIndex: visitIndex, offeringId: offeringId, locationType: locationType, reason: reason) },
        ].compactMap { $0 }))
        try await api.requestVoid(path(id) + "/adjust", method: .post, body: body)
    }
}

public struct ProLookOffering: Decodable, Sendable, Identifiable {
    public let offeringId: String
    public let name: String
    public var id: String { offeringId }
}

extension ProConsultService {
    public func offerings(id: String) async throws -> [ProLookOffering] {
        struct Response: Decodable { let offerings: [ProLookOffering] }
        let result: Response = try await api.request(path(id) + "/author")
        return result.offerings
    }
    public func author(id: String, version: Int, tier: String, title: String, summary: String,
                       reasoning: String, reviewNote: String, reviewedClientDetails: Bool, visits: [[String]]) async throws {
        struct Body: Encodable {
            let expectedVersion: Int
            let idempotencyKey: String
            let tier: String
            let title: String
            let summary: String
            let whyThisWorksForYou: String
            let reviewNote: String
            let reviewedClientDetails: Bool
            let visits: [[String]]
        }
        let body = Body(expectedVersion: version, idempotencyKey: UUID().uuidString, tier: tier, title: title,
            summary: summary, whyThisWorksForYou: reasoning, reviewNote: reviewNote,
            reviewedClientDetails: reviewedClientDetails, visits: visits)
        try await api.requestVoid(path(id) + "/author", method: .post, body: JSONEncoder().encode(body))
    }
}

public struct ConsultMentor: Decodable, Sendable {
    public struct Section: Decodable, Sendable, Identifiable {
        public struct Item: Decodable, Sendable { public let text: String; public let sourceId: String }
        public let id: Int
        public let title: String
        public let items: [Item]
    }
    public let title: String
    public let authority: String
    public let formulationNote: String
    public let sections: [Section]
}

public struct ProConsultFeedback: Decodable, Sendable {
    public enum Rating: String, Codable, Sendable { case accurateUseful = "ACCURATE_USEFUL", off = "OFF" }
    public let rating: Rating
    public let createdAt: String
}

public struct ProConsultServiceEstimate: Decodable, Sendable {
    public struct Line: Decodable, Sendable {
        public let serviceId: String
        public let serviceName: String
        public let source: String
        public let estimatedPrice: String
        public let estimatedDurationMinutes: Int
        public let rationale: String
    }
    public let status: String
    public let locationType: String
    public let refusalCode: String?
    public let lines: [Line]
    public let bufferMinutes: Int?
}

extension ProConsultService {
    public func feedback(id: String, rating: ProConsultFeedback.Rating) async throws -> ProConsultFeedback {
        struct Body: Encodable { let rating: ProConsultFeedback.Rating }
        struct Response: Decodable { let feedback: ProConsultFeedback }
        let result: Response = try await api.request(try consultPath(id) + "/feedback", method: .post, body: JSONEncoder().encode(Body(rating: rating)))
        return result.feedback
    }
}

// C2-4 — the pro asks. What she asked comes back on the Brief (`proFollowUps`);
// the route's GET twin exists server-side but the Brief is the read here.
extension ProConsultService {
    /// `POST /pro/consults/{id}/follow-up` — asks, and returns the whole list
    /// with the new question on it. The server mints the option values and the
    /// key; identity is the session's, never sent. A refusal (open cap, total
    /// cap, no Brief yet, appointment started) arrives as `APIError.server`
    /// with the server's own sentence, which is what the sheet shows.
    public func askFollowUp(id: String, _ ask: ProConsultFollowUpAsk) async throws -> [ProConsultFollowUp] {
        let result: ProConsultFollowUpListResponse = try await api.request(
            try consultPath(id) + "/follow-up", method: .post, body: JSONEncoder().encode(ask))
        return result.questions
    }
}
