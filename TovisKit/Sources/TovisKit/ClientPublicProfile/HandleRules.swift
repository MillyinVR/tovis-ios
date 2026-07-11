import Foundation

/// Client-side handle rules — a Swift port of `lib/handles.ts` used to sanitize the
/// `@handle` field as the user types and to render the format hint. The backend
/// (`app/api/v1/client/profile/route.ts`) remains the source of truth: it re-runs
/// `normalizeHandle` + `isValidHandle` + the reserved-word + uniqueness checks and
/// surfaces any rejection as an error message, exactly as the web form relies on.
/// We port only the input sanitizer + bounds (no reserved list) to match the web
/// card's live behavior without duplicating the server's authoritative validation.
public enum HandleRules {
    public static let min = 3
    public static let max = 24

    /// Sanitize free-text input into a candidate handle for the input field:
    /// lowercase, drop everything outside `[a-z0-9-]`, trim leading/trailing hyphens,
    /// and cap at `max`. 1:1 with web `sanitizeHandleInput`. The result should still
    /// be validated server-side before it is persisted.
    public static func sanitizeInput(_ raw: String) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = lowered.unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "-"
        }
        var s = String(String.UnicodeScalarView(allowed))
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        if s.count > max { s = String(s.prefix(max)) }
        return s
    }
}
