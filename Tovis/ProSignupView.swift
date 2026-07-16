// Native PRO signup — mirrors the web pro form (SignupProClient): a 3-step flow
// (Your work · About you · Account) wired to POST /api/v1/auth/register with
// role=PRO via SessionModel.registerPro. Step 1 collects the profession, the
// licensed/operating state, and where they work (in-salon Google-autocomplete
// address → PRO_SALON, or a base ZIP + travel radius → PRO_MOBILE), resolving the
// location's coordinates + timezone through PlacesService. On success the session
// flips to `.needsVerification` and RootView swaps to phone verification (register
// already texted the code).
//
// Deviation from web: the per-state license matrix (lib/licensing) is not ported
// to Swift (it's flagged as legally volatile). The license field is marked
// required for the six core BBC professions — LICENSED in every state — and
// optional otherwise; the backend stays the source of truth and still enforces the
// specialty per-state overrides (surfaced as a server error).
import SwiftUI
import TovisKit

struct ProSignupView: View {
    @Environment(SessionModel.self) private var session

    private static let passwordMinLength = 10
    private static let stepLabels = ["Your work", "About you", "Account"]
    private static let lastStep = stepLabels.count - 1

    private enum ProMode { case salon, mobile }

    // Step 0 — your work
    @State private var profession: ProfessionType = .cosmetologist
    @State private var licenseState = ""
    @State private var proMode: ProMode = .salon
    @State private var licenseNumber = ""
    @State private var addExpiry = false
    @State private var licenseExpiry = Date()

    // Location resolution
    @State private var locQuery = ""
    @State private var predictions: [PlacePrediction] = []
    @State private var locLoading = false
    @State private var confirmedSalon: ProSalonLocation?
    @State private var confirmedMobile: ClientSignupLocation?
    @State private var mobileRadius = "15"
    @State private var searchTask: Task<Void, Never>?
    private let placesSessionToken = UUID().uuidString

    // Step 1 — about you
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var businessName = ""
    @State private var handle = ""
    @State private var phone = ""
    @State private var smsConsent = false

    // Step 2 — account
    @State private var email = ""
    @State private var password = ""
    @State private var tosAccepted = false

    @State private var step = 0
    @State private var formError: String?

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var needsLicense: Bool { profession.requiresLicenseByDefault }

    private var isLocationConfirmed: Bool {
        switch proMode {
        case .salon: return confirmedSalon != nil
        case .mobile: return confirmedMobile != nil
        }
    }

    private var selectedStateName: String? {
        usStates.first { $0.code == licenseState }?.name
    }

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    SignupStepIndicator(step: step, labels: Self.stepLabels)

                    switch step {
                    case 0: workStep
                    case 1: aboutStep
                    default: accountStep
                    }

                    if let message = formError ?? session.errorMessage {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    buttons
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Pro account")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            searchTask?.cancel()
            session.errorMessage = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create your pro account")
                .font(BrandFont.display(24, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Run your business from your phone — setup takes minutes.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Step 0: your work

    private var workStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Profession")
                Menu {
                    ForEach(ProfessionType.allCases) { option in
                        Button(option.label) {
                            profession = option
                            formError = nil
                        }
                    }
                } label: {
                    pickerChrome(profession.label, muted: false)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("State you’re licensed / operating in")
                Menu {
                    ForEach(usStates) { state in
                        Button(state.name) {
                            licenseState = state.code
                            formError = nil
                        }
                    }
                } label: {
                    pickerChrome(selectedStateName ?? "Select your state…", muted: licenseState.isEmpty)
                }

                if !licenseState.isEmpty, !needsLicense {
                    Text("No state license is required for this profession in \(selectedStateName ?? "your state"). You’ll upload a certificate and photo ID on the Verification page after signup.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            modeToggle
            locationField
            if proMode == .mobile { radiusField }
            if needsLicense { licenseBlock }
        }
    }

    private var modeToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Where do you offer services?")
            HStack(spacing: 10) {
                modePill(title: "In salon / suite", mode: .salon)
                modePill(title: "Mobile", mode: .mobile)
            }
        }
    }

    private func modePill(title: String, mode: ProMode) -> some View {
        let selected = proMode == mode
        return Button {
            guard proMode != mode else { return }
            proMode = mode
            resetLocation()
            formError = nil
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
                SignupFieldLabel(proMode == .mobile ? "Base ZIP code" : "Salon / suite address")
                Spacer()
                if locLoading {
                    Text("Confirming…")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }

            BrandField(
                placeholder: proMode == .mobile ? "e.g. 92101" : "Search your salon / suite address",
                text: $locQuery,
                isSecure: false
            )
            .keyboardType(proMode == .mobile ? .numberPad : .default)
            .textInputAutocapitalization(proMode == .mobile ? .never : .words)
            .autocorrectionDisabled(proMode == .mobile)
            .onChange(of: locQuery) { _, newValue in onLocQueryChange(newValue) }

            if proMode == .salon, !predictions.isEmpty {
                predictionList
            }

            locationStatusRow
        }
    }

    private var predictionList: some View {
        VStack(spacing: 0) {
            ForEach(predictions) { prediction in
                Button {
                    Task { await pickPrediction(prediction) }
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
                if prediction.id != predictions.last?.id {
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
    private var locationStatusRow: some View {
        if proMode == .salon, let salon = confirmedSalon {
            confirmedCard(
                primary: salon.formattedAddress,
                secondary: friendlyZone(salon.timeZoneId)
            )
        } else if proMode == .mobile, let mobile = confirmedMobile {
            confirmedCard(
                primary: "Near \([mobile.city, mobile.state].compactMap { $0 }.joined(separator: ", "))",
                secondary: friendlyZone(mobile.timeZoneId)
            )
        } else if proMode == .mobile {
            Button {
                Task { await confirmZip() }
            } label: {
                Text("Confirm ZIP")
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.accent)
            }
            .buttonStyle(.plain)
            .disabled(locLoading || locQuery.trimmingCharacters(in: .whitespaces).isEmpty)
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
            BrandField(placeholder: "e.g. 15", text: $mobileRadius, isSecure: false)
                .keyboardType(.numberPad)
                .onChange(of: mobileRadius) { _, _ in formError = nil }
            Text("How far you travel from your base ZIP.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    private var licenseBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel("\(selectedStateName ?? "State") license number")
            BrandField(placeholder: "e.g. 123456", text: $licenseNumber, isSecure: false)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: licenseNumber) { _, _ in formError = nil }

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

    // MARK: - Step 1: about you

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                labeledField("First name", text: $firstName)
                    .textContentType(.givenName)
                labeledField("Last name", text: $lastName)
                    .textContentType(.familyName)
            }

            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Business name (optional)")
                BrandField(placeholder: "Your business name", text: $businessName, isSecure: false)
                    .textContentType(.organizationName)
                Text("You can add this later — we won’t block signup.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Handle (optional)")
                BrandField(placeholder: "yourhandle", text: $handle, isSecure: false)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Your public profile link. You can set or change this later.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Phone")
                BrandField(placeholder: "+1 555 555 5555", text: $phone, isSecure: false)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            }

            SignupConsentRow(
                isOn: $smsConsent,
                text: Text("I agree to receive transactional texts (verification codes and appointment updates). Message and data rates may apply."),
                onToggle: { formError = nil }
            )
        }
    }

    // MARK: - Step 2: account

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Email address")
                BrandField(placeholder: "you@email.com", text: $email, isSecure: false)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 6) {
                SignupFieldLabel("Password")
                PasswordRevealField(placeholder: "Password", text: $password, textContentType: .newPassword)
                Text("At least \(Self.passwordMinLength) characters.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }

            SignupConsentRow(isOn: $tosAccepted, text: SignupCopy.tosLabel, onToggle: { formError = nil })
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            SignupPrimaryButton(
                title: step < Self.lastStep ? "Continue" : "Create pro account",
                isLoading: session.isWorking || locLoading,
                isDisabled: session.isWorking || locLoading
            ) {
                Task { await handlePrimary() }
            }
            if step > 0 {
                SignupBackButton {
                    formError = nil
                    session.errorMessage = nil
                    step -= 1
                }
            }
        }
    }

    // MARK: - Building blocks

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel(label)
            BrandField(placeholder: label, text: text, isSecure: false)
                .onChange(of: text.wrappedValue) { _, _ in formError = nil }
        }
    }

    private func pickerChrome(_ text: String, muted: Bool) -> some View {
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

    private func friendlyZone(_ timeZoneId: String) -> String? {
        timeZoneId.isEmpty ? nil : timeZoneId
    }

    // MARK: - Location handlers

    private func resetLocation() {
        searchTask?.cancel()
        locQuery = ""
        predictions = []
        confirmedSalon = nil
        confirmedMobile = nil
    }

    private func onLocQueryChange(_ newValue: String) {
        // Any edit invalidates a prior confirmation.
        confirmedSalon = nil
        confirmedMobile = nil
        formError = nil

        guard proMode == .salon else {
            predictions = []
            return
        }

        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        guard trimmed.count >= 3 else {
            predictions = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await runAutocomplete(trimmed)
        }
    }

    private func runAutocomplete(_ input: String) async {
        locLoading = true
        defer { locLoading = false }
        do {
            let results = try await session.client.places.autocomplete(
                input: input,
                sessionToken: placesSessionToken
            )
            if Task.isCancelled { return }
            predictions = Array(results.prefix(6))
        } catch {
            predictions = []
        }
    }

    private func pickPrediction(_ prediction: PlacePrediction) async {
        locLoading = true
        defer { locLoading = false }
        do {
            let salon = try await session.client.places.resolveProSalon(
                placeId: prediction.placeId,
                sessionToken: placesSessionToken
            )
            confirmedSalon = salon
            predictions = []
        } catch let error as APIError {
            formError = error.userMessage
        } catch {
            formError = "Could not confirm that address."
        }
    }

    private func confirmZip() async {
        let raw = locQuery.trimmingCharacters(in: .whitespaces)
        guard raw.range(of: "^\\d{5}(-\\d{4})?$", options: .regularExpression) != nil else {
            formError = "Please enter a valid 5-digit ZIP code."
            return
        }
        locLoading = true
        defer { locLoading = false }
        do {
            let resolved = try await session.client.places.resolveClientZip(postalCode: raw)
            confirmedMobile = resolved
        } catch let error as APIError {
            formError = error.userMessage
        } catch {
            formError = "Could not confirm ZIP code."
        }
    }

    // MARK: - Submit

    /// Advance to the next step (validating the current one) or, on the last step,
    /// validate everything and create the account.
    private func handlePrimary() async {
        formError = nil
        session.errorMessage = nil

        if step < Self.lastStep {
            if let message = validate(step: step) {
                formError = message
                return
            }
            step += 1
            return
        }

        // Final step: validate every step, jumping to the first that fails.
        for candidate in 0...Self.lastStep {
            if let message = validate(step: candidate) {
                step = candidate
                formError = message
                return
            }
        }

        guard let location = buildLocation() else {
            step = 0
            formError = "Please confirm where you offer services."
            return
        }

        let trimmedHandle = handle.trimmingCharacters(in: .whitespaces)
        let trimmedBusiness = businessName.trimmingCharacters(in: .whitespaces)
        let expiry = (needsLicense && addExpiry)
            ? Self.expiryFormatter.string(from: licenseExpiry)
            : nil

        _ = await session.registerPro(
            email: email.trimmingCharacters(in: .whitespaces),
            password: password,
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            phone: phone.trimmingCharacters(in: .whitespaces),
            professionType: profession,
            licenseState: licenseState,
            businessName: trimmedBusiness.isEmpty ? nil : trimmedBusiness,
            handle: trimmedHandle.isEmpty ? nil : trimmedHandle,
            licenseNumber: licenseNumberToSubmit,
            licenseExpiry: expiry,
            location: location
        )
    }

    private var licenseNumberToSubmit: String? {
        let trimmed = licenseNumber.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func buildLocation() -> ProSignupLocation? {
        switch proMode {
        case .salon:
            guard let salon = confirmedSalon else { return nil }
            return .salon(salon)
        case .mobile:
            guard let mobile = confirmedMobile, let miles = Int(mobileRadius) else { return nil }
            return .mobile(mobile, radiusMiles: miles)
        }
    }

    /// Returns the first validation error for `step`, or nil when it's complete.
    private func validate(step: Int) -> String? {
        switch step {
        case 0:
            if licenseState.isEmpty { return "Please select the state you’re licensed or operating in." }
            if !isLocationConfirmed {
                return proMode == .mobile
                    ? "Please confirm your base ZIP code."
                    : "Please choose your address from the list."
            }
            if proMode == .mobile {
                guard let miles = Int(mobileRadius), (1...200).contains(miles) else {
                    return "Please enter a mobile radius between 1 and 200 miles."
                }
            }
            if needsLicense, licenseNumberToSubmit == nil {
                return "A license number is required for this profession in your state."
            }
            return nil
        case 1:
            if firstName.trimmingCharacters(in: .whitespaces).isEmpty { return "First name is required." }
            if lastName.trimmingCharacters(in: .whitespaces).isEmpty { return "Last name is required." }
            if phone.trimmingCharacters(in: .whitespaces).isEmpty { return "Phone number is required." }
            if !smsConsent { return "Please agree to receive verification and appointment texts." }
            return nil
        default:
            if email.trimmingCharacters(in: .whitespaces).isEmpty { return "Email is required." }
            if password.count < Self.passwordMinLength {
                return "Password must be at least \(Self.passwordMinLength) characters."
            }
            if !tosAccepted { return "Please accept the Terms and Privacy Policy." }
            return nil
        }
    }
}
