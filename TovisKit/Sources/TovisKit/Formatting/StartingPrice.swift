import Foundation

/// 🔴 Tori's standing rule: **a price is a STARTING price.** Never render a bare
/// figure — always "From $250". The pro sets the final number at the chair, so a
/// bare "$250" is a promise the product cannot keep.
///
/// The wire deliberately sends the figure WITHOUT the word: `priceFromLabel`
/// (`lib/profiles/publicProfileMappers.ts` → `priceLabel`) is just the formatted
/// money, and web supplies the word at the call site (`<ProfileHeroStat
/// label="From" …>`). That left every native call site free to forget it — and
/// three of them had: the booking sheet header, the booking CONFIRMATION summary
/// card, and the pro profile's offering rows.
///
/// So the wording lives here, once, rather than in each view.
public enum StartingPrice {
    /// "From $250" for an already-formatted money label, or nil when there is no
    /// price to state (never "From —", and never a bare figure).
    ///
    /// Idempotent: a label that already leads with "From" is returned unchanged,
    /// so a server that starts sending the full phrase can't produce
    /// "From From $250".
    public static func label(_ formatted: String?) -> String? {
        guard let trimmed = formatted?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }

        if trimmed.lowercased().hasPrefix("from ") { return trimmed }
        return "From \(trimmed)"
    }

    /// "From $30" for a raw wire decimal string ("30.00"), for the surfaces that
    /// carry the number rather than a formatted label — add-on rows.
    public static func labelFromAmount(_ amount: String?) -> String? {
        label(Wire.money(amount))
    }
}
