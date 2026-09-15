// The fields that describe a PRO's work — profession, licensed/operating state,
// where they work, their licence, and what they trade under.
//
// Shared by the two doors that can create a ProfessionalProfile:
//   * `ProSignupView` — a brand-new pro account;
//   * `ClientBecomeProView` — "Offer services", an existing client adding a pro
//     workspace.
//
// 🔴 Extracted rather than copied, and not for tidiness: these fields decide
// whether somebody may legally take bookings. A second spelling of the licence
// card or the work-location picker is how one of the two screens quietly stops
// asking — and the person who signed up through THAT door is listed without a
// credential nobody noticed was missing. Web paid for exactly this extraction
// (#993) before it built its own become-a-pro form; this is the native half.
import SwiftUI
import TovisKit

// MARK: - Work location

/// Where a pro offers services, and the Places round-trips that confirm it.
///
/// State only — the network calls take a `PlacesService` from the caller rather
/// than holding a client, so the model stays constructible in a `@State`
/// initializer and testable without one.
///
/// 🔴 A location is only usable once CONFIRMED. Typing invalidates a prior
/// confirmation (`queryChanged`), because the text in the field and the
/// coordinates last resolved from it stop being the same place the moment a
/// character changes — and the coordinates are what a booking radius is measured
/// from.
@MainActor
@Observable
final class ProWorkLocationModel {
    enum Mode: Equatable { case salon, mobile }

    var mode: Mode = .salon
    var query = ""
    var predictions: [PlacePrediction] = []
    /// True while a Places call is in flight — the submit button waits on it, so
    /// a half-resolved address can't be submitted.
    var isResolving = false
    var confirmedSalon: ProSalonLocation?
    var confirmedMobile: ClientSignupLocation?
    var radiusMiles = "15"

    private var searchTask: Task<Void, Never>?
    /// One Places session token for the life of this form — that is what makes
    /// the autocomplete keystrokes and the final details call bill as one
    /// session rather than a dozen.
    private let placesSessionToken = UUID().uuidString

    init() {}

    var isConfirmed: Bool {
        switch mode {
        case .salon: return confirmedSalon != nil
        case .mobile: return confirmedMobile != nil
        }
    }

    func setMode(_ next: Mode) {
        guard mode != next else { return }
        mode = next
        reset()
    }

    func reset() {
        searchTask?.cancel()
        query = ""
        predictions = []
        confirmedSalon = nil
        confirmedMobile = nil
    }

    func cancelSearch() {
        searchTask?.cancel()
    }

    /// React to an edit: drop any confirmation, then (salon only) debounce an
    /// autocomplete.
    func queryChanged(_ newValue: String, places: PlacesService) {
        confirmedSalon = nil
        confirmedMobile = nil

        guard mode == .salon else {
            predictions = []
            return
        }

        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        guard trimmed.count >= 3 else {
            predictions = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self?.runAutocomplete(trimmed, places: places)
        }
    }

    private func runAutocomplete(_ input: String, places: PlacesService) async {
        isResolving = true
        defer { isResolving = false }
        do {
            let results = try await places.autocomplete(
                input: input,
                sessionToken: placesSessionToken
            )
            if Task.isCancelled { return }
            predictions = Array(results.prefix(6))
        } catch {
            predictions = []
        }
    }

    /// Resolve a tapped prediction to coordinates + timezone. Returns a message
    /// on refusal so the host can show it where it shows its other errors.
    func pickPrediction(_ prediction: PlacePrediction, places: PlacesService) async -> String? {
        isResolving = true
        defer { isResolving = false }
        do {
            confirmedSalon = try await places.resolveProSalon(
                placeId: prediction.placeId,
                sessionToken: placesSessionToken
            )
            predictions = []
            return nil
        } catch let error as APIError {
            return error.userMessage
        } catch {
            return "Could not confirm that address."
        }
    }

    /// Resolve the typed ZIP. Returns a message on refusal, nil on success.
    func confirmZip(places: PlacesService) async -> String? {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard raw.range(of: "^\\d{5}(-\\d{4})?$", options: .regularExpression) != nil else {
            return "Please enter a valid 5-digit ZIP code."
        }
        isResolving = true
        defer { isResolving = false }
        do {
            confirmedMobile = try await places.resolveClientZip(postalCode: raw)
            return nil
        } catch let error as APIError {
            return error.userMessage
        } catch {
            return "Could not confirm ZIP code."
        }
    }

    /// The travel radius the backend accepts. ONE definition, read by both
    /// `validate()` and `signupLocation()` — a bound spelled twice is a bound
    /// that eventually disagrees with itself.
    static let radiusRange = 1...200

    /// The radius as a number the wire will accept, or nil.
    private var radiusMilesValue: Int? {
        guard let miles = Int(radiusMiles), Self.radiusRange.contains(miles) else {
            return nil
        }
        return miles
    }

    /// The payload a create/upgrade call sends, or nil while the form is not
    /// ready. Narrowing here is what keeps both call sites from building it.
    ///
    /// 🔴 It applies the SAME radius bound `validate()` does rather than any
    /// parseable number. The two used to disagree — `Int("201")` succeeds — so a
    /// caller that built the payload without validating first could send a
    /// radius the server refuses. Nothing does that today; this is what keeps it
    /// that way, since this is the function whose whole job is narrowing.
    func signupLocation() -> ProSignupLocation? {
        switch mode {
        case .salon:
            guard let salon = confirmedSalon else { return nil }
            return .salon(salon)
        case .mobile:
            guard let mobile = confirmedMobile, let miles = radiusMilesValue else { return nil }
            return .mobile(mobile, radiusMiles: miles)
        }
    }

    /// The first thing wrong with the location, or nil.
    func validate() -> String? {
        if !isConfirmed {
            return mode == .mobile
                ? "Please confirm your base ZIP code."
                : "Please choose your address from the list."
        }
        if mode == .mobile, radiusMilesValue == nil {
            return "Please enter a mobile radius between \(Self.radiusRange.lowerBound) and \(Self.radiusRange.upperBound) miles."
        }
        return nil
    }
}

/// The in-salon / mobile toggle, the address-or-ZIP field with its predictions,
/// the confirmation state, and the mobile radius.
struct ProWorkLocationFields: View {
    @Environment(SessionModel.self) private var session
    @Bindable var model: ProWorkLocationModel
    /// Called on any edit — hosts use it to clear a standing form error.
    var onEdit: () -> Void = {}
    /// A refusal from Places, handed to the host to render where it renders its
    /// own errors rather than in a second place on the same screen.
    var onError: (String) -> Void = { _ in }

    private var places: PlacesService { session.client.places }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Where do you offer services?")
                HStack(spacing: 10) {
                    modePill(title: "In salon / suite", mode: .salon)
                    modePill(title: "Mobile", mode: .mobile)
                }
            }

            locationField

            if model.mode == .mobile { radiusField }
        }
    }

    private func modePill(title: String, mode: ProWorkLocationModel.Mode) -> some View {
        let selected = model.mode == mode
        return Button {
            model.setMode(mode)
            onEdit()
        } label: {
            Text(title)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(selected ? BrandColor.textPrimary : BrandColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selected ? BrandColor.accent.opacity(0.14) : BrandColor.bgSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        selected ? BrandColor.accent.opacity(0.4) : BrandColor.textMuted.opacity(0.18),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SignupFieldLabel(model.mode == .mobile ? "Base ZIP code" : "Salon / suite address")
                Spacer()
                if model.isResolving {
                    Text("Confirming…")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }

            BrandField(
                placeholder: model.mode == .mobile ? "e.g. 92101" : "Search your salon / suite address",
                text: $model.query,
                isSecure: false
            )
            .keyboardType(model.mode == .mobile ? .numberPad : .default)
            .textInputAutocapitalization(model.mode == .mobile ? .never : .words)
            .autocorrectionDisabled(model.mode == .mobile)
            .onChange(of: model.query) { _, newValue in
                model.queryChanged(newValue, places: places)
                onEdit()
            }

            if model.mode == .salon, !model.predictions.isEmpty {
                predictionList
            }

            statusRow
        }
    }

    private var predictionList: some View {
        VStack(spacing: 0) {
            ForEach(model.predictions) { prediction in
                Button {
                    Task {
                        if let message = await model.pickPrediction(prediction, places: places) {
                            onError(message)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prediction.mainText.isEmpty ? prediction.description : prediction.mainText)
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if !prediction.secondaryText.isEmpty {
                            Text(prediction.secondaryText)
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if prediction.id != model.predictions.last?.id {
                    Divider().overlay(BrandColor.textMuted.opacity(0.12))
                }
            }
        }
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        if model.mode == .salon, let salon = model.confirmedSalon {
            confirmedCard(primary: salon.formattedAddress, secondary: zoneText(salon.timeZoneId))
        } else if model.mode == .mobile, let mobile = model.confirmedMobile {
            confirmedCard(
                primary: "Near \([mobile.city, mobile.state].compactMap { $0 }.joined(separator: ", "))",
                secondary: zoneText(mobile.timeZoneId)
            )
        } else if model.mode == .mobile {
            Button {
                Task {
                    if let message = await model.confirmZip(places: places) {
                        onError(message)
                    }
                }
            } label: {
                Text("Confirm ZIP")
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.isResolving || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
        } else {
            Text("Pick your address from the list to confirm.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    private func confirmedCard(primary: String, secondary: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrandColor.emerald)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary {
                    Text(secondary)
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.emerald.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var radiusField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Mobile radius (miles)")
            BrandField(placeholder: "e.g. 15", text: $model.radiusMiles, isSecure: false)
                .keyboardType(.numberPad)
                .onChange(of: model.radiusMiles) { _, _ in onEdit() }
            Text("How far you travel from your base ZIP.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    private func zoneText(_ timeZoneId: String) -> String? {
        timeZoneId.isEmpty ? nil : timeZoneId
    }
}

// MARK: - Profession + state

/// The profession picker and the licensed/operating-state picker, with the note
/// that appears for a profession this build treats as unlicensed by default.
struct ProProfessionFields: View {
    @Binding var profession: ProfessionType
    @Binding var licenseState: String
    var onEdit: () -> Void = {}

    private var selectedStateName: String? {
        usStates.first { $0.code == licenseState }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Profession")
                Menu {
                    ForEach(ProfessionType.allCases) { option in
                        Button(option.label) {
                            profession = option
                            onEdit()
                        }
                    }
                } label: {
                    SignupPickerChrome(text: profession.label, muted: false)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("State you’re licensed / operating in")
                Menu {
                    ForEach(usStates) { state in
                        Button(state.name) {
                            licenseState = state.code
                            onEdit()
                        }
                    }
                } label: {
                    SignupPickerChrome(
                        text: selectedStateName ?? "Select your state…",
                        muted: licenseState.isEmpty
                    )
                }

                if !licenseState.isEmpty, !profession.requiresLicenseByDefault {
                    Text("No state license is required for this profession in \(selectedStateName ?? "your state"). You’ll upload a certificate and photo ID on the Verification page after signup.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Licence

/// The licence number + optional expiry card. Render it only when the profession
/// needs one (`ProfessionType.requiresLicenseByDefault`); the backend still
/// enforces the per-state specialty overrides this build does not carry, and
/// surfaces them as a `LICENSE_REQUIRED` error.
struct ProLicenseFields: View {
    let licenseState: String
    @Binding var licenseNumber: String
    @Binding var addExpiry: Bool
    @Binding var licenseExpiry: Date
    var onEdit: () -> Void = {}

    private var stateName: String {
        usStates.first { $0.code == licenseState }?.name ?? "State"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel("\(stateName) license number")
            BrandField(placeholder: "e.g. 123456", text: $licenseNumber, isSecure: false)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: licenseNumber) { _, _ in onEdit() }

            Toggle(isOn: $addExpiry) {
                Text("Add expiration date")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            .tint(BrandColor.accent)

            if addExpiry {
                DatePicker(
                    "Expiration date",
                    selection: $licenseExpiry,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .tint(BrandColor.accent)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
            }

            Text("We’ll review your credential after signup. You can still set up services and your calendar immediately.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }
}

/// The licence number as the wire wants it, or nil when there is none to send.
func proLicenseNumberToSubmit(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Branding

/// Business name + handle — both optional, both settable later.
struct ProBrandingFields: View {
    @Binding var businessName: String
    @Binding var handle: String
    var onEdit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Business name (optional)")
                BrandField(placeholder: "Your business name", text: $businessName, isSecure: false)
                    .textContentType(.organizationName)
                    .onChange(of: businessName) { _, _ in onEdit() }
                Text("You can add this later — we won’t block signup.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Handle (optional)")
                BrandField(placeholder: "yourhandle", text: $handle, isSecure: false)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: handle) { _, _ in onEdit() }
                Text("Your public profile link. You can set or change this later.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }
}

// MARK: - Shared chrome

/// The tap target a `Menu` wears so it reads like the `BrandField`s around it.
struct SignupPickerChrome: View {
    let text: String
    let muted: Bool

    var body: some View {
        HStack {
            Text(text)
                .font(BrandFont.body(16))
                .foregroundStyle(muted ? BrandColor.textMuted : BrandColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }
}
