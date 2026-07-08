import Foundation

// Value types the native PRO signup needs, mirroring the web SignupProClient form
// (app/(auth)/_components/signup/SignupProClient.tsx) and the backend register
// route's PRO branch (app/api/v1/auth/register/route.ts).

/// The professions the pro signup offers. Raw values are the backend
/// `ProfessionType` enum literals sent as `professionType`.
public enum ProfessionType: String, CaseIterable, Sendable, Identifiable {
    case cosmetologist = "COSMETOLOGIST"
    case barber = "BARBER"
    case esthetician = "ESTHETICIAN"
    case manicurist = "MANICURIST"
    case hairstylist = "HAIRSTYLIST"
    case electrologist = "ELECTROLOGIST"
    case massageTherapist = "MASSAGE_THERAPIST"
    case makeupArtist = "MAKEUP_ARTIST"
    case lashTechnician = "LASH_TECHNICIAN"
    case hairBraider = "HAIR_BRAIDER"
    case permanentMakeupArtist = "PERMANENT_MAKEUP_ARTIST"

    public var id: String { rawValue }

    /// Human label shown in the picker (matches the web `<option>` text).
    public var label: String {
        switch self {
        case .cosmetologist: return "Cosmetologist"
        case .barber: return "Barber"
        case .esthetician: return "Esthetician"
        case .manicurist: return "Manicurist"
        case .hairstylist: return "Hairstylist"
        case .electrologist: return "Electrologist"
        case .massageTherapist: return "Massage therapist"
        case .makeupArtist: return "Makeup artist"
        case .lashTechnician: return "Lash technician"
        case .hairBraider: return "Hair braider"
        case .permanentMakeupArtist: return "Permanent makeup artist"
        }
    }

    /// The core barbering/cosmetology professions every state licenses — those for
    /// which a license number is required at signup in all states (`BASELINE` =
    /// LICENSED for these in lib/licensing/licenseRequirement.ts). The specialty
    /// professions are EXEMPT by default with a few per-state overrides the backend
    /// still enforces (surfaced as a `LICENSE_REQUIRED` error), so this set is a
    /// stable common-case hint, not a re-implementation of the 50-state matrix.
    public var requiresLicenseByDefault: Bool {
        switch self {
        case .cosmetologist, .barber, .esthetician,
             .manicurist, .hairstylist, .electrologist:
            return true
        case .massageTherapist, .makeupArtist, .lashTechnician,
             .hairBraider, .permanentMakeupArtist:
            return false
        }
    }
}

/// A US state option for the license/operating-state picker. Mirrors
/// `US_STATES` in lib/usStates.ts (the backend validates against the same list).
public struct USState: Sendable, Identifiable, Equatable {
    public let code: String
    public let name: String
    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public let usStates: [USState] = [
    USState(code: "AL", name: "Alabama"),
    USState(code: "AK", name: "Alaska"),
    USState(code: "AZ", name: "Arizona"),
    USState(code: "AR", name: "Arkansas"),
    USState(code: "CA", name: "California"),
    USState(code: "CO", name: "Colorado"),
    USState(code: "CT", name: "Connecticut"),
    USState(code: "DE", name: "Delaware"),
    USState(code: "DC", name: "District of Columbia"),
    USState(code: "FL", name: "Florida"),
    USState(code: "GA", name: "Georgia"),
    USState(code: "HI", name: "Hawaii"),
    USState(code: "ID", name: "Idaho"),
    USState(code: "IL", name: "Illinois"),
    USState(code: "IN", name: "Indiana"),
    USState(code: "IA", name: "Iowa"),
    USState(code: "KS", name: "Kansas"),
    USState(code: "KY", name: "Kentucky"),
    USState(code: "LA", name: "Louisiana"),
    USState(code: "ME", name: "Maine"),
    USState(code: "MD", name: "Maryland"),
    USState(code: "MA", name: "Massachusetts"),
    USState(code: "MI", name: "Michigan"),
    USState(code: "MN", name: "Minnesota"),
    USState(code: "MS", name: "Mississippi"),
    USState(code: "MO", name: "Missouri"),
    USState(code: "MT", name: "Montana"),
    USState(code: "NE", name: "Nebraska"),
    USState(code: "NV", name: "Nevada"),
    USState(code: "NH", name: "New Hampshire"),
    USState(code: "NJ", name: "New Jersey"),
    USState(code: "NM", name: "New Mexico"),
    USState(code: "NY", name: "New York"),
    USState(code: "NC", name: "North Carolina"),
    USState(code: "ND", name: "North Dakota"),
    USState(code: "OH", name: "Ohio"),
    USState(code: "OK", name: "Oklahoma"),
    USState(code: "OR", name: "Oregon"),
    USState(code: "PA", name: "Pennsylvania"),
    USState(code: "RI", name: "Rhode Island"),
    USState(code: "SC", name: "South Carolina"),
    USState(code: "SD", name: "South Dakota"),
    USState(code: "TN", name: "Tennessee"),
    USState(code: "TX", name: "Texas"),
    USState(code: "UT", name: "Utah"),
    USState(code: "VT", name: "Vermont"),
    USState(code: "VA", name: "Virginia"),
    USState(code: "WA", name: "Washington"),
    USState(code: "WV", name: "West Virginia"),
    USState(code: "WI", name: "Wisconsin"),
    USState(code: "WY", name: "Wyoming"),
]

/// A salon/suite address resolved to coordinates + IANA timezone for the
/// `PRO_SALON` `signupLocation` payload. Produced by `PlacesService.resolveProSalon`
/// (place details + timezone), the pro analogue of `ClientSignupLocation`.
public struct ProSalonLocation: Sendable, Equatable {
    public let placeId: String
    public let formattedAddress: String
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let countryCode: String?
    public let lat: Double
    public let lng: Double
    public let timeZoneId: String

    public init(
        placeId: String,
        formattedAddress: String,
        city: String?,
        state: String?,
        postalCode: String?,
        countryCode: String?,
        lat: Double,
        lng: Double,
        timeZoneId: String
    ) {
        self.placeId = placeId
        self.formattedAddress = formattedAddress
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.countryCode = countryCode
        self.lat = lat
        self.lng = lng
        self.timeZoneId = timeZoneId
    }
}

/// Where a pro offers services — the two `signupLocation` variants a PRO signup
/// sends. `AuthService.registerPro` maps this to the wire `SignupLocationPayload`
/// (and the mobile radius to `mobileRadiusMiles`).
public enum ProSignupLocation: Sendable {
    /// In-salon / suite: a confirmed Google place.
    case salon(ProSalonLocation)
    /// Mobile: a base ZIP (same resolution as a client ZIP) + travel radius.
    case mobile(ClientSignupLocation, radiusMiles: Int)
}
