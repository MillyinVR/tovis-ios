import Foundation

/// Load + parse picked spreadsheet files for the migration wizard's import steps
/// — the iOS counterpart of the web `app/pro/migrate/_utils/parseSpreadsheetFile.ts`,
/// shared by the clients + services views so the pick/parse logic lives once.
///
/// Text files parse on-device (CsvParser, PapaParse parity). Binary Excel
/// exports — Vagaro and Fresha hand out .xlsx by default — are shuttled to
/// POST /pro/migrate/parse (server-side, shared with web) and come back in the
/// same headers + rows shape, so callers never care where parsing ran.
public enum SpreadsheetFileLoader {
    public enum LoadError: Error, Sendable {
        /// Parsed fine but there's no header row / no data rows.
        case emptyTable
    }

    /// True when the raw bytes are a binary spreadsheet container — the same
    /// magic-byte sniff the server does: xlsx (zip, `PK\u{3}\u{4}`) or legacy
    /// .xls (OLE compound, `D0 CF 11 E0`). Everything else is treated as text.
    public static func looksBinary(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [data[data.startIndex], data[data.index(data.startIndex, offsetBy: 1)],
                 data[data.index(data.startIndex, offsetBy: 2)], data[data.index(data.startIndex, offsetBy: 3)]]
        if b == [0x50, 0x4B, 0x03, 0x04] { return true }
        if b == [0xD0, 0xCF, 0x11, 0xE0] { return true }
        return false
    }

    /// Read one picked (security-scoped) URL into memory.
    public static func read(url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// Parse one picked file's bytes into a header-keyed table. Binary Excel →
    /// the server parse endpoint (throws `APIError` on failure, including the
    /// flag-off 404); text → on-device CsvParser. Throws `LoadError.emptyTable`
    /// when there's nothing usable either way.
    public static func parse(
        data: Data,
        using migration: ProMigrationService
    ) async throws -> CsvParser.Table {
        let table: CsvParser.Table
        if looksBinary(data) {
            let response = try await migration.parseSpreadsheet(data: data)
            table = CsvParser.Table(headers: response.headers, rows: response.rows)
        } else {
            // isoLatin1 decodes any byte sequence, so text decoding can't fail —
            // binary containers are already routed above by magic bytes.
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            table = CsvParser.parse(text)
        }
        guard !table.isEmpty else { throw LoadError.emptyTable }
        return table
    }

    /// Read + parse several picked files, preserving pick order. Fails fast on
    /// the first unreadable/empty file.
    public static func loadAll(
        urls: [URL],
        using migration: ProMigrationService
    ) async throws -> [CsvParser.Table] {
        var tables: [CsvParser.Table] = []
        tables.reserveCapacity(urls.count)
        for url in urls {
            let data = try read(url: url)
            tables.append(try await parse(data: data, using: migration))
        }
        return tables
    }

    /// True when every table has the same header set (order-insensitive) — the
    /// condition for safely concatenating rows from multiple files of one export
    /// (web `tablesShareHeaders`).
    public static func tablesShareHeaders(_ tables: [CsvParser.Table]) -> Bool {
        guard let first = tables.first else { return true }
        let key = Set(first.headers)
        return tables.allSatisfy { Set($0.headers) == key }
    }
}
