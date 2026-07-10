import Foundation

// Native port of the web client checkout money path + off-platform pay
// affordance (tovis-app `lib/payments/paymentDeepLink.ts` + the tip/total math in
// `ClientCheckoutCard.tsx`). Pure + Decimal-based so the money path is unit-tested
// and never drifts from web: the on-screen total AND the deep-link amount both
// reflect the FULL amount owed, live the instant a tip changes (CHK-tip-live).

/// The tip + total math the client checkout renders. All Decimal so cents are
/// exact (no Double rounding on real money).
public enum CheckoutMoney {
    /// Parse a wire decimal-string amount (e.g. "120.00") to a Decimal; nil/blank
    /// or unparseable → 0, so a missing snapshot never blanks the total.
    public static func amount(_ wire: String?) -> Decimal {
        guard let wire, let value = Decimal(string: wire.trimmingCharacters(in: .whitespaces)) else {
            return 0
        }
        return value
    }

    /// Tip for a whole-percent preset, on the services subtotal only (products
    /// never affect tip — mirrors web `toTipAmountString`). Rounded to cents.
    public static func tip(serviceSubtotal: Decimal, percent: Int) -> Decimal {
        guard serviceSubtotal > 0, percent > 0 else { return 0 }
        return round2(serviceSubtotal * Decimal(percent) / 100)
    }

    /// The full amount owed = service + products + tip + tax − discount. The single
    /// source of truth for the Total row, the CTA amount, and the deep-link amount.
    public static func liveTotal(
        serviceSubtotal: Decimal,
        productSubtotal: Decimal,
        tip: Decimal,
        tax: Decimal,
        discount: Decimal
    ) -> Decimal {
        serviceSubtotal + productSubtotal + tip + tax - discount
    }

    /// Format a Decimal as a fixed 2-decimal amount string ("72.00") — the wire
    /// shape the checkout/stripe routes expect and the deep-link amount uses. No
    /// grouping, POSIX separator, so it's stable regardless of device locale.
    public static func fixed2(_ value: Decimal) -> String {
        Self.fixedFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.00"
    }

    static func round2(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    private static let fixedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
}

/// The off-platform pay affordance for a selected method — the native mirror of
/// web's `PaymentDeepLink`. Two shapes, because not every app exposes a deep link:
///   • `.link`  — Venmo / PayPal open pre-filled via a universal https URL.
///   • `.copy`  — Zelle / Apple Cash have no public deep link, so we surface the
///                handle + amount to copy plus a one-line instruction.
/// Cash, card-on-file, tap-to-pay, Apple Pay and Stripe card have no off-platform
/// action → this returns nil.
public enum PaymentDeepLink: Sendable, Equatable {
    case link(href: URL, label: String)
    case copy(handle: String, amount: String, instruction: String)
}

/// Build the off-platform pay action for a selected method. Returns nil when the
/// method has no off-platform link (cash / card rails / Stripe) or the handle /
/// amount is missing or unusable. Mirrors `buildPaymentDeepLink`.
public func buildPaymentDeepLink(
    methodKey: String,
    handle: String?,
    amountDue: Decimal,
    note: String? = nil
) -> PaymentDeepLink? {
    guard amountDue > 0 else { return nil }
    let amount = CheckoutMoney.fixed2(amountDue)

    let rawHandle = (handle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawHandle.isEmpty else { return nil }

    switch methodKey {
    case "venmo":
        let user = cleanHandle(rawHandle)
        guard !user.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "venmo.com"
        components.path = "/\(user)"
        var items = [
            URLQueryItem(name: "txn", value: "pay"),
            URLQueryItem(name: "amount", value: amount),
        ]
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            items.append(URLQueryItem(name: "note", value: note))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        return .link(href: url, label: "Pay $\(amount) with Venmo")

    case "paypal":
        guard let user = paypalUsername(rawHandle) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "paypal.me"
        // PayPal.Me locks the amount into the URL path; currency is inferred.
        components.path = "/\(user)/\(amount)"
        guard let url = components.url else { return nil }
        return .link(href: url, label: "Pay $\(amount) with PayPal")

    case "zelle":
        return .copy(
            handle: rawHandle,
            amount: amount,
            instruction: "Open Zelle in your bank app and send $\(amount) to \(rawHandle)."
        )

    case "apple_cash":
        return .copy(
            handle: rawHandle,
            amount: amount,
            instruction: "Open Messages or Wallet and send $\(amount) to \(rawHandle) with Apple Cash."
        )

    default:
        return nil
    }
}

/// Strip a leading "@" and surrounding whitespace from a handle.
private func cleanHandle(_ handle: String) -> String {
    var trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasPrefix("@") { trimmed.removeFirst() }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Pull the username out of whatever the pro saved for PayPal: a bare username,
/// "@username", "paypal.me/username", or a full "https://paypal.me/username" URL.
private func paypalUsername(_ handle: String) -> String? {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let range = trimmed.range(of: #"paypal\.me/([^/?#\s]+)"#, options: [.regularExpression, .caseInsensitive]) {
        // Extract the captured segment after the last "/".
        let match = String(trimmed[range])
        if let slash = match.lastIndex(of: "/") {
            let user = String(match[match.index(after: slash)...])
            if !user.isEmpty { return user }
        }
    }

    let cleaned = cleanHandle(trimmed)
    return cleaned.isEmpty ? nil : cleaned
}
