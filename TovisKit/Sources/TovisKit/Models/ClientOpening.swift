import Foundation

// Wire models for the client last-minute openings feed — GET /api/v1/client/openings.
// Mirrors the recipient feed envelope `{ notifications: [{ id, tier, sentAt, …,
// opening }] }` built by app/api/v1/client/openings/route.ts (services + incentive
// via lib/lastMinute/openingDto.ts). The card-facing derivation below (primary
// service → offering, discounted price math, meta line) mirrors the web `parseCard`
// in app/client/(gated)/openings/OpeningsFeedClient.tsx so both feeds render the
// same thing. Nullable fields are Swift optionals and unknown keys are ignored, so
// a partial payload never fails to decode.

/// Envelope for `GET /api/v1/client/openings` → `{ ok, notifications }`.
struct ClientOpeningFeedResponse: Decodable, Sendable {
    let notifications: [ClientOpening]
}

/// One recipient row in the openings feed. `id` is the `LastMinuteRecipient` id
/// (the row key); `opening` carries the freed-up slot's detail.
public struct ClientOpening: Decodable, Sendable, Identifiable {
    public let id: String
    /// `notifiedTier ?? firstMatchedTier`; `"WAITLIST"` flags a matched-waitlist row.
    public let tier: String?
    public let opening: ClientOpeningDetail
}

public struct ClientOpeningDetail: Decodable, Sendable, Identifiable {
    public let id: String
    public let professionalId: String
    public let startAt: String
    public let endAt: String?
    public let note: String?
    public let locationType: String?
    public let timeZone: String?
    public let professional: ClientOpeningPro
    /// The opening's bookable location. Nullable on the recipient feed (a MOBILE
    /// opening has no salon row to point at), which is why the claim path sends
    /// `locationId` only when it is present and lets the server pick otherwise.
    public let location: ClientOpeningLocation?
    /// Active services on this opening (drives the title + starting price). Optional
    /// so a sparse payload still decodes; an opening with none is not bookable.
    public let services: [ClientOpeningServiceItem]?
    public let publicIncentive: ClientOpeningIncentive?
}

public struct ClientOpeningLocation: Decodable, Sendable, Identifiable {
    public let id: String?
    public let type: String?
    public let timeZone: String?
    public let city: String?
    public let state: String?
    public let formattedAddress: String?
}

public struct ClientOpeningPro: Decodable, Sendable, Identifiable {
    public let id: String
    public let businessName: String?
    public let displayName: String?
    public let handle: String?
    public let avatarUrl: String?
    public let professionType: String?
    public let locationLabel: String?
    public let timeZone: String?
}

public struct ClientOpeningServiceItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let serviceId: String?
    public let offeringId: String?
    public let sortOrder: Int?
    public let service: ClientOpeningServiceRef?
    public let offering: ClientOpeningOffering?
}

public struct ClientOpeningServiceRef: Decodable, Sendable {
    public let id: String?
    public let name: String?
    public let minPrice: String?
    public let defaultDurationMinutes: Int?
}

public struct ClientOpeningOffering: Decodable, Sendable {
    public let id: String?
    public let title: String?
    public let salonPriceStartingAt: String?
    public let mobilePriceStartingAt: String?
    public let salonDurationMinutes: Int?
    public let mobileDurationMinutes: Int?
    public let offersInSalon: Bool?
    public let offersMobile: Bool?
}

public struct ClientOpeningIncentive: Decodable, Sendable {
    public let tier: String?
    public let offerType: String?
    public let label: String?
    public let percentOff: Int?
    public let amountOff: String?
    public let freeAddOnService: ClientOpeningFreeAddOn?
}

public struct ClientOpeningFreeAddOn: Decodable, Sendable {
    public let id: String?
    public let name: String?
}

// MARK: - Card derivation (mirrors web `parseCard`)

public extension ClientOpening {
    /// The first service row — the one the card books. Web `parseCard` takes the
    /// first service and drops the card when it carries no offering.
    var primaryService: ClientOpeningServiceItem? { opening.services?.first }

    /// The offering the "Grab it" tap routes into. Nil → not bookable (the card is
    /// dropped, mirroring `parseCard` returning null when the primary row has no
    /// offeringId).
    var offeringId: String? { primaryService?.offeringId?.trimmedOrNil }

    /// Whether this opening can be shown/booked (has an offering to route to).
    var isBookable: Bool { offeringId != nil }

    /// The service the offering is resolved by on the pro's profile.
    var serviceId: String? {
        primaryService?.serviceId?.trimmedOrNil ?? primaryService?.service?.id?.trimmedOrNil
    }

    /// Headline: offering title → service name → neutral label.
    var serviceName: String {
        primaryService?.offering?.title?.trimmedOrNil
            ?? primaryService?.service?.name?.trimmedOrNil
            ?? "Last-minute opening"
    }

    /// Pro display name with the same fallbacks as the web card (no handle fallback).
    var proName: String {
        opening.professional.displayName?.trimmedOrNil
            ?? opening.professional.businessName?.trimmedOrNil
            ?? "Your pro"
    }

    /// "Pro · Place" meta line; the place is omitted when the pro has no label.
    var meta: String {
        [proName, opening.professional.locationLabel?.trimmedOrNil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var startAt: String { opening.startAt }
    var timeZone: String? { opening.timeZone }

    /// SALON / MOBILE, upper-cased, defaulting to SALON exactly as the booking
    /// endpoints do when a caller omits `locationType`.
    var claimLocationType: String {
        let raw = opening.locationType?.trimmedOrNil?.uppercased()
        return raw == "MOBILE" ? "MOBILE" : "SALON"
    }

    var isMobile: Bool { claimLocationType == "MOBILE" }

    /// The location the hold should be pinned to. Nil is fine — `POST /holds`
    /// treats `locationId` as a HINT and falls back to the pro's bookable
    /// location, which is what a MOBILE opening (no salon row) relies on.
    var claimLocationId: String? { opening.location?.id?.trimmedOrNil }

    /// "Where" line on the claim sheet, mirroring the web claim page's `place`:
    /// the street address when there is one, else "City, ST", else nil so the
    /// row can render an em dash rather than an empty string.
    var placeLine: String? {
        if let address = opening.location?.formattedAddress?.trimmedOrNil { return address }
        let cityState = [opening.location?.city?.trimmedOrNil, opening.location?.state?.trimmedOrNil]
            .compactMap { $0 }
            .joined(separator: ", ")
        return cityState.trimmedOrNil ?? opening.professional.locationLabel?.trimmedOrNil
    }

    /// Duration for the "Duration" row — the offering's mode duration, falling
    /// back to the service default (same precedence as the price).
    var durationMinutes: Int? {
        let modeDuration = isMobile
            ? primaryService?.offering?.mobileDurationMinutes
            : primaryService?.offering?.salonDurationMinutes
        return modeDuration ?? primaryService?.service?.defaultDurationMinutes
    }

    /// The pro's profession label, shown beside the name on the claim sheet the
    /// same way the web claim page does.
    var professionLabel: String? {
        opening.professional.professionType?.trimmedOrNil?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// True when this opening matched one of the client's waitlists.
    var matchedWaitlist: Bool { (tier?.uppercased() ?? "") == "WAITLIST" }

    /// Human incentive copy ("20% off", "$15 off", "Free service", …) when the
    /// opening carries one. Built server-side by `incentiveLabel` in
    /// lib/lastMinute/openingDto.ts, so both platforms say the same thing.
    var incentiveLabel: String? { opening.publicIncentive?.label?.trimmedOrNil }

    /// The deal, sized to matter. A pro creating a last-minute opening picks ONE
    /// of percent-off / amount-off / free service / free add-on, and that choice
    /// — not the starting price, which the pro re-quotes at the appointment
    /// anyway — is the reason to drop everything and claim the slot. So the
    /// headline is the incentive, upper-cased, and the price sits under it.
    var incentiveHeadline: String? { incentiveLabel?.uppercased() }

    /// One line of context under the headline, so "FREE SERVICE" and "20% OFF"
    /// both read as something concrete rather than a floating badge.
    var incentiveSubline: String? {
        guard incentiveLabel != nil else { return nil }
        switch opening.publicIncentive?.offerType?.uppercased() {
        case "PERCENT_OFF", "AMOUNT_OFF":
            return "Off this last-minute opening"
        case "FREE_SERVICE":
            return "This last-minute opening is on your pro"
        case "FREE_ADD_ON":
            return "Free add-on with this last-minute opening"
        default:
            return "On this last-minute opening"
        }
    }

    /// Base "starting at" price for the opening's location mode, before any incentive
    /// (mobile → mobile offering price; else salon; falling back to the service min).
    /// Nil → no price shown.
    var basePrice: Decimal? {
        let isMobile = (opening.locationType?.uppercased() ?? "") == "MOBILE"
        let modePrice = isMobile
            ? primaryService?.offering?.mobilePriceStartingAt
            : primaryService?.offering?.salonPriceStartingAt
        return Self.decimal(modePrice) ?? Self.decimal(primaryService?.service?.minPrice)
    }

    /// The price after applying the incentive (percent/amount off), falling back to
    /// the base when no discount applies. Mirrors the web `parseCard` discount math.
    var finalPrice: Decimal? {
        guard let base = basePrice else { return nil }
        guard let incentive = opening.publicIncentive,
              let type = incentive.offerType?.uppercased() else { return base }
        if type == "PERCENT_OFF", let pct = incentive.percentOff, pct > 0 {
            let discounted = base * (1 - Decimal(pct) / 100)
            return discounted < 0 ? 0 : discounted
        }
        if type == "AMOUNT_OFF", let amount = Self.decimal(incentive.amountOff),
           amount > 0, amount < base {
            return base - amount
        }
        return base
    }

    /// Whether to show a struck-through "was" price beside the discounted price.
    var hasDiscount: Bool {
        guard let base = basePrice, let final = finalPrice else { return false }
        return final < base
    }

    private static func decimal(_ raw: String?) -> Decimal? {
        guard let raw = raw?.trimmedOrNil else { return nil }
        return Decimal(string: raw)
    }
}

