import Foundation

/// On-device CSV parser for the pro data-migration wizard's import steps. iOS has
/// no CSV library, and the web client import parses with PapaParse
/// (`app/pro/migrate/clients/MigrateClientsClient.tsx`, config
/// `{ header: true, skipEmptyLines: true }`). This mirrors that behavior so the
/// raw rows we POST to `/pro/migrate/clients/preview`+`/commit` are the same
/// `Record<string,string>` shape the server's `toStringRecord`/`ColumnMapping`
/// expect: the first non-empty record is the header row, every later record
/// becomes a `[header: cell]` dictionary.
///
/// RFC-4180-ish: quoted fields (`"…"`) may contain commas, CRLF/LF newlines, and
/// escaped quotes (`""` → `"`); a quote only opens a field when it's the field's
/// first character. A leading BOM is stripped (Excel exports include one, and
/// PapaParse strips it too). Fully pure + `Sendable` so it unit-tests like the
/// web `clientImport.test.ts`.
public enum CsvParser {
    /// The parsed table: the ordered header names plus one dictionary per data row.
    public struct Table: Sendable, Equatable {
        public let headers: [String]
        public let rows: [[String: String]]

        public init(headers: [String], rows: [[String: String]]) {
            self.headers = headers
            self.rows = rows
        }

        /// No usable data — no header row, or a header row with no following rows.
        public var isEmpty: Bool { headers.isEmpty || rows.isEmpty }
    }

    /// Parse CSV text into a header-keyed table (PapaParse `header: true`,
    /// `skipEmptyLines: true`). Returns an empty table when there's no header row.
    public static func parse(_ text: String) -> Table {
        let records = parseRecords(text)
        guard let header = records.first else { return Table(headers: [], rows: []) }

        var rows: [[String: String]] = []
        rows.reserveCapacity(records.count - 1)
        for record in records.dropFirst() {
            var row: [String: String] = [:]
            for (index, key) in header.enumerated() {
                // Short rows leave later headers empty; extra cells are ignored
                // (PapaParse buckets them under __parsed_extra — we don't need them).
                row[key] = index < record.count ? record[index] : ""
            }
            rows.append(row)
        }
        return Table(headers: header, rows: rows)
    }

    /// Tokenize into records of raw string fields, dropping empty lines.
    /// Exposed for tests; `parse` layers the header/row mapping on top.
    ///
    /// Iterates over Unicode **scalars**, not `Character`s: a CRLF is a single
    /// grapheme cluster, so a `Character` scan would never see the `\r`/`\n` line
    /// break — scalars keep them distinct.
    static func parseRecords(_ text: String) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        // Strip a leading UTF-8/UTF-16 BOM if present.
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"

        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var fieldStarted = false // has the current field received any scalar yet?
        var inQuotes = false
        var i = 0

        func endField() {
            fields.append(field)
            field = ""
            fieldStarted = false
        }
        func endRecord() {
            endField()
            // skipEmptyLines: a wholly empty line is a single empty field.
            if !(fields.count == 1 && fields[0].isEmpty) {
                records.append(fields)
            }
            fields = []
        }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        field.unicodeScalars.append(quote) // escaped quote
                        i += 1
                    } else {
                        inQuotes = false // closing quote
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == quote && !fieldStarted {
                inQuotes = true
                fieldStarted = true
            } else if c == comma {
                endField()
            } else if c == cr {
                endRecord()
                if i + 1 < scalars.count && scalars[i + 1] == lf { i += 1 } // CRLF
            } else if c == lf {
                endRecord()
            } else {
                field.unicodeScalars.append(c)
                fieldStarted = true
            }
            i += 1
        }

        // Flush a trailing record with no terminating newline.
        if fieldStarted || !field.isEmpty || !fields.isEmpty {
            endRecord()
        }
        return records
    }
}
