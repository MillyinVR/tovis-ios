import Foundation

// Wire models for POST /api/v1/pro/migrate/parse — server-side spreadsheet
// parsing for the migration wizard (web `lib/migration/tableParse.ts`). Binary
// Excel exports (Vagaro/Fresha hand out .xlsx by default) can't be parsed by the
// on-device CsvParser, so the raw file is shuttled up as base64 and comes back in
// the same headers + rows shape the CSV path produces — downstream mapping/
// preview/commit is identical either way. 404s while ENABLE_PRO_MIGRATION is off.

/// The POST body: the picked file's raw bytes, base64-encoded. The server sniffs
/// the format from magic bytes (xlsx zip / legacy xls OLE / CSV text) and caps
/// size at 8 MB, so no client-side format detection is needed.
struct SpreadsheetParseRequestBody: Encodable {
    let contentBase64: String
}

/// `POST /pro/migrate/parse` envelope (the `ok:true` field is ignored by
/// `Decodable`). `truncated` is true when the server's row/column caps clipped
/// the output.
public struct SpreadsheetParseResponse: Decodable, Sendable {
    public let headers: [String]
    public let rows: [[String: String]]
    public let truncated: Bool
}
