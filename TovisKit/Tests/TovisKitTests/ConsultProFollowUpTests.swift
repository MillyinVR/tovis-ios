import Foundation
import Testing
@testable import TovisKit

// C2-4 — the pro's own follow-up questions: the Brief field, the route's own
// response, and the draft rules that mirror the server's parser.
struct ConsultProFollowUpTests {
    private func proBriefPayload() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "consultSuitability", withExtension: "json"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root["proBrief"] as? [String: Any])
        return try #require(envelope["brief"] as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    /// The Brief carries the list, oldest first, with one OPEN and one ANSWERED.
    @Test func briefDecodesTheProsQuestionsWithTheirAnswers() throws {
        let brief = try decode(ProConsultBrief.self, proBriefPayload())
        let questions = try #require(brief.proFollowUps)
        #expect(questions.map(\.questionKey) == ["pro_1", "pro_2"])

        let open = questions[0]
        #expect(open.priority == .needBeforeAppointment)
        #expect(open.isOpen)
        #expect(open.selectedValue == nil)
        #expect(open.selectedLabel == nil)
        #expect(open.answeredAt == nil)
        #expect(open.options.map(\.value) == ["option-1", "option-2", "option-3"])
        #expect(open.planVersion == 3)

        let answered = questions[1]
        #expect(answered.priority == .helpfulForPrep)
        #expect(!answered.isOpen)
        #expect(answered.selectedValue == "option-2")
        // The label is the SERVER's join of value → option, for display.
        #expect(answered.selectedLabel == "Mostly down")
        #expect(answered.answeredAt != nil)
    }

    /// A server that predates C2-4 sends no field; the Brief decodes and the
    /// section stays hidden (nil, not empty — empty would offer a control that
    /// 404s there).
    @Test func briefWithoutTheFieldDecodesAsNil() throws {
        var payload = try proBriefPayload()
        payload.removeValue(forKey: "proFollowUps")
        #expect(try decode(ProConsultBrief.self, payload).proFollowUps == nil)
    }

    /// A priority this build has never heard of decodes rather than taking the
    /// Brief down, and is never one the pro can pick.
    @Test func unknownPriorityDecodesAsUnknownAndIsNeverAskable() throws {
        var payload = try proBriefPayload()
        var questions = try #require(payload["proFollowUps"] as? [[String: Any]])
        questions[0]["priority"] = "SOMETHING_NEW"
        payload["proFollowUps"] = questions
        let brief = try decode(ProConsultBrief.self, payload)
        #expect(brief.proFollowUps?.first?.priority == .unknown)
        #expect(!ProConsultFollowUpPriority.askable.contains(.unknown))
        #expect(ProConsultFollowUpPriority.askable == [.needBeforeAppointment, .helpfulForPrep])
    }

    /// The ask/list route's own envelope, off its fixture.
    @Test func listResponseDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "proConsultFollowUps", withExtension: "json"))
        let response = try JSONDecoder().decode(ProConsultFollowUpListResponse.self, from: Data(contentsOf: url))
        #expect(response.questions.count == 2)
        #expect(response.questions.filter(\.isOpen).count == 1)
    }

    /// The body on the wire is exactly `{ priority, text, options }` with the
    /// server's spellings — and never a professional id.
    @Test func askEncodesThePriorityTextAndLabelsOnly() throws {
        let ask = try #require(ProConsultFollowUpDraft(
            priority: .needBeforeAppointment,
            text: "  Have you had keratin in the last year?  ",
            options: [" Yes ", "No", "", "Not sure"]
        ).normalized())
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ask)) as? [String: Any]
        )
        #expect(Set(json.keys) == ["priority", "text", "options"])
        #expect(json["priority"] as? String == "NEED_BEFORE_APPOINTMENT")
        #expect(json["text"] as? String == "Have you had keratin in the last year?")
        #expect(json["options"] as? [String] == ["Yes", "No", "Not sure"])
    }

    /// The parser's accept/refuse matrix (`parseConsultProFollowUpAsk`).
    @Test func draftRulesMirrorTheServersParser() {
        func ok(_ text: String, _ options: [String], _ priority: ProConsultFollowUpPriority = .helpfulForPrep) -> Bool {
            ProConsultFollowUpDraft(priority: priority, text: text, options: options).normalized() != nil
        }
        #expect(ok("Up or down?", ["Up", "Down"]))
        // Blank rows are dropped, not refused — the form starts with two empties.
        #expect(ok("Up or down?", ["Up", "Down", ""]))
        #expect(!ok("", ["Up", "Down"]))
        #expect(!ok("   ", ["Up", "Down"]))
        #expect(!ok(String(repeating: "x", count: 301), ["Up", "Down"]))
        #expect(ok(String(repeating: "x", count: 300), ["Up", "Down"]))
        // Fewer than two real answers.
        #expect(!ok("Up or down?", ["Up"]))
        #expect(!ok("Up or down?", ["Up", "  "]))
        // More than six.
        #expect(!ok("Which?", ["1", "2", "3", "4", "5", "6", "7"]))
        #expect(ok("Which?", ["1", "2", "3", "4", "5", "6"]))
        // Duplicates, case-insensitively.
        #expect(!ok("Up or down?", ["Up", "up"]))
        #expect(!ok("Up or down?", ["Up", " UP "]))
        // A label that is too long.
        #expect(!ok("Which?", ["Up", String(repeating: "y", count: 121)]))
        #expect(ok("Which?", ["Up", String(repeating: "y", count: 120)]))
        // A priority the server would not know.
        #expect(!ok("Up or down?", ["Up", "Down"], .unknown))
    }

    /// The words are the web's words, line for line.
    @Test func copyMirrorsTheWebControl() {
        #expect(ProConsultFollowUpCopy.title == "Ask a follow-up")
        #expect(ProConsultFollowUpCopy.priorityTitle(.needBeforeAppointment) == "Needed before the appointment")
        #expect(ProConsultFollowUpCopy.priorityTitle(.helpfulForPrep) == "Helpful for prep")
        #expect(ProConsultFollowUpCopy.openLimit(3) == "Up to 3 questions can be open at once. Wait for an answer before asking another.")
        #expect(ProConsultFollowUpCopy.optionPlaceholder(0) == "Option 1")
        #expect(ProConsultFollowUpCopy.waiting == "Waiting for her answer")
        #expect(ProConsultFollowUpCopy.answered == "Answered")
    }
}
