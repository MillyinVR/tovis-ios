// File types the migration wizard's import pickers accept — CSV/plain text
// (parsed on-device) plus Excel (routed to POST /pro/migrate/parse). Shared by
// the clients + services steps so the pickers never drift apart. Kept in the app
// layer: UTType is presentation-adjacent and TovisKit stays UI-framework-free.
import UniformTypeIdentifiers

let migrationSpreadsheetContentTypes: [UTType] = {
    var types: [UTType] = [.commaSeparatedText, .plainText, .text, .spreadsheet]
    // Excel's concrete types aren't exported constants; resolve by extension.
    for ext in ["xlsx", "xlsm", "xls"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}()
