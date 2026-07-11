import Foundation
import Testing
@testable import TovisKit

// Proves the on-device CSV parser matches the web PapaParse config
// (`header: true, skipEmptyLines: true`) the client-import step relies on, so the
// raw rows we POST are the same header-keyed dictionaries the server expects.

@Suite struct CsvParserTests {
    @Test func parsesHeaderAndRows() {
        let table = CsvParser.parse("first,last,email\nJane,Doe,jane@x.com\nSam,Lee,sam@y.com")
        #expect(table.headers == ["first", "last", "email"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == ["first": "Jane", "last": "Doe", "email": "jane@x.com"])
        #expect(table.rows[1]["email"] == "sam@y.com")
        #expect(table.isEmpty == false)
    }

    @Test func skipsEmptyLines() {
        let table = CsvParser.parse("first,last\n\nJane,Doe\n\n\nSam,Lee\n")
        #expect(table.rows.count == 2)
        #expect(table.rows[0]["first"] == "Jane")
        #expect(table.rows[1]["first"] == "Sam")
    }

    @Test func handlesQuotedCommas() {
        let table = CsvParser.parse("name,note\n\"Doe, Jane\",\"hi, there\"")
        #expect(table.rows[0]["name"] == "Doe, Jane")
        #expect(table.rows[0]["note"] == "hi, there")
    }

    @Test func handlesEscapedQuotes() {
        let table = CsvParser.parse("a\n\"she said \"\"hi\"\"\"")
        #expect(table.rows[0]["a"] == "she said \"hi\"")
    }

    @Test func handlesQuotedNewline() {
        let table = CsvParser.parse("a,b\n\"line1\nline2\",x")
        #expect(table.rows.count == 1)
        #expect(table.rows[0]["a"] == "line1\nline2")
        #expect(table.rows[0]["b"] == "x")
    }

    @Test func handlesCRLF() {
        let table = CsvParser.parse("a,b\r\n1,2\r\n3,4\r\n")
        #expect(table.headers == ["a", "b"])
        #expect(table.rows.count == 2)
        #expect(table.rows[1] == ["a": "3", "b": "4"])
    }

    @Test func stripsLeadingBOM() {
        let table = CsvParser.parse("\u{FEFF}first,last\nJane,Doe")
        #expect(table.headers == ["first", "last"])
        #expect(table.rows[0]["first"] == "Jane")
    }

    @Test func padsShortRowsAndIgnoresExtraCells() {
        let table = CsvParser.parse("a,b,c\n1\n1,2,3,4")
        #expect(table.rows[0] == ["a": "1", "b": "", "c": ""])
        #expect(table.rows[1] == ["a": "1", "b": "2", "c": "3"])
    }

    @Test func headerOnlyIsEmpty() {
        let table = CsvParser.parse("first,last\n")
        #expect(table.headers == ["first", "last"])
        #expect(table.rows.isEmpty)
        #expect(table.isEmpty)
    }

    @Test func emptyInputIsEmpty() {
        let table = CsvParser.parse("")
        #expect(table.headers.isEmpty)
        #expect(table.isEmpty)
    }

    @Test func preservesTrailingEmptyField() {
        let table = CsvParser.parse("a,b,c\n1,2,")
        #expect(table.rows[0] == ["a": "1", "b": "2", "c": ""])
    }
}
