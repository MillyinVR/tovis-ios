import Foundation
import Testing
@testable import TovisKit

// C2-6a — the one-line synthesis at the top of the pro Brief. Server-composed;
// this side only has to decode it, show it when present, and show nothing on a
// server that predates it.
struct ConsultBriefTopLineTests {
    private func proBriefPayload() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "consultSuitability", withExtension: "json"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root["proBrief"] as? [String: Any])
        return try #require(envelope["brief"] as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    /// The contract fixture carries the line, verbatim.
    @Test func briefDecodesTheTopLine() throws {
        let brief = try decode(ProConsultBrief.self, proBriefPayload())
        #expect(brief.topLine == "Client wants the color because the goal is a change people will notice, mainly going lighter. Must preserve the length and avoid heavy upkeep.")
    }

    /// A server that predates C2-6a sends no field; an up-to-date server with
    /// nothing to say sends null. Both decode, both render nothing.
    @Test func briefWithoutTheFieldOrWithNullDecodesAsNil() throws {
        var payload = try proBriefPayload()
        payload.removeValue(forKey: "topLine")
        #expect(try decode(ProConsultBrief.self, payload).topLine == nil)
        payload["topLine"] = NSNull()
        #expect(try decode(ProConsultBrief.self, payload).topLine == nil)
    }
}
