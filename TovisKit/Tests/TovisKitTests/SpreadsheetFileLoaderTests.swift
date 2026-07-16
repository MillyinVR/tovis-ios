import Foundation
import Testing
@testable import TovisKit

// Pure-helper coverage for the migration wizard's shared file loader — binary
// sniffing (routes Excel to the server parse endpoint) and the multi-file
// header-match rule (web `tablesShareHeaders` parity). The network path itself
// is exercised end-to-end by the clients/services import flows.
struct SpreadsheetFileLoaderTests {
    @Test func sniffsBinarySpreadsheetContainers() {
        // xlsx = zip magic.
        #expect(SpreadsheetFileLoader.looksBinary(Data([0x50, 0x4B, 0x03, 0x04, 0x00])))
        // legacy .xls = OLE compound magic.
        #expect(SpreadsheetFileLoader.looksBinary(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1])))
        // CSV/plain text is not binary.
        #expect(!SpreadsheetFileLoader.looksBinary(Data("Name,Price\nCut,85\n".utf8)))
        // Too short to carry magic bytes.
        #expect(!SpreadsheetFileLoader.looksBinary(Data([0x50, 0x4B])))
    }

    @Test func headerMatchRuleIsOrderInsensitive() {
        let a = CsvParser.Table(headers: ["Name", "Email"], rows: [["Name": "Jane", "Email": "j@x.com"]])
        let b = CsvParser.Table(headers: ["Email", "Name"], rows: [["Name": "Sam", "Email": "s@x.com"]])
        let c = CsvParser.Table(headers: ["Name", "Phone"], rows: [["Name": "Kim", "Phone": "555"]])
        #expect(SpreadsheetFileLoader.tablesShareHeaders([]))
        #expect(SpreadsheetFileLoader.tablesShareHeaders([a]))
        #expect(SpreadsheetFileLoader.tablesShareHeaders([a, b]))
        #expect(!SpreadsheetFileLoader.tablesShareHeaders([a, c]))
    }

    @Test func parseResponseDecodesEnvelope() throws {
        let json = """
        { "ok": true, "headers": ["Name", "Price"], "rows": [{ "Name": "Cut", "Price": "85" }], "truncated": false }
        """
        let decoded = try JSONDecoder().decode(SpreadsheetParseResponse.self, from: Data(json.utf8))
        #expect(decoded.headers == ["Name", "Price"])
        #expect(decoded.rows == [["Name": "Cut", "Price": "85"]])
        #expect(!decoded.truncated)
    }
}
