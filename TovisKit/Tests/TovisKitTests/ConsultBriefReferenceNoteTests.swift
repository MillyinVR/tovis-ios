import Foundation
import Testing
@testable import TovisKit

// C2-6b — the reference note on the pro Brief: one line about the photograph
// the inspiration reading flagged. Server-composed; this side only has to
// decode it, show it when present, and show nothing on a server that
// predates it or had nothing to say.
struct ConsultBriefReferenceNoteTests {
    private func proBriefPayload() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "consultSuitability", withExtension: "json"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root["proBrief"] as? [String: Any])
        return try #require(envelope["brief"] as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    /// The contract fixture carries the line, verbatim — and never a flag code.
    @Test func briefDecodesTheReferenceNote() throws {
        let brief = try decode(ProConsultBrief.self, proBriefPayload())
        #expect(brief.inspirationCredibility == "Reference note: looks edited or filtered; lit like a photo shoot.")
        #expect(brief.inspirationCredibility?.contains("LIKELY_EDITED") == false)
    }

    /// A server that predates C2-6b sends no field; an up-to-date server with
    /// no flag sends null. Both decode, both render nothing.
    @Test func briefWithoutTheFieldOrWithNullDecodesAsNil() throws {
        var payload = try proBriefPayload()
        payload.removeValue(forKey: "inspirationCredibility")
        #expect(try decode(ProConsultBrief.self, payload).inspirationCredibility == nil)
        payload["inspirationCredibility"] = NSNull()
        #expect(try decode(ProConsultBrief.self, payload).inspirationCredibility == nil)
    }
}
