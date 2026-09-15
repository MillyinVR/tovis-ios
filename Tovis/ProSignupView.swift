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

    // Step 0 — your work. The fields themselves live in `ProWorkFields.swift`,
    // shared with "Offer services" (`ClientBecomeProView`) — the other door that
    // can create a ProfessionalProfile. A second copy of the licence card or the
    // location picker is how one door quietly stops asking.
    @State private var profession: ProfessionType = .cosmetologist
    @State private var licenseState = ""
    @State private var licenseNumber = ""
    @State private var addExpiry = false
    @State private var licenseExpiry = Date()
    @State private var work = ProWorkLocationModel()

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
    @State private var signupInviteCode = ""
    @State private var tosAccepted = false

    @State private var step = 0
    @State private var formError: String?

    private var needsLicense: Bool { profession.requiresLicenseByDefault }

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
            work.cancelSearch()
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
            ProProfessionFields(
                profession: $profession,
                licenseState: $licenseState,
                onEdit: { formError = nil }
            )

            ProWorkLocationFields(
                model: work,
                onEdit: { formError = nil },
                onError: { formError = $0 }
            )

            if needsLicense {
                ProLicenseFields(
                    licenseState: licenseState,
                    licenseNumber: $licenseNumber,
                    addExpiry: $addExpiry,
                    licenseExpiry: $licenseExpiry,
                    onEdit: { formError = nil }
                )
            }
        }
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

            ProBrandingFields(
                businessName: $businessName,
                handle: $handle,
                onEdit: { formError = nil }
            )

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
            SignupInviteCodeField(code: $signupInviteCode) {
                formError = nil
            }

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
                isLoading: session.isWorking || work.isResolving,
                isDisabled: session.isWorking || work.isResolving
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

        guard let location = work.signupLocation() else {
            step = 0
            formError = "Please confirm where you offer services."
            return
        }

        let trimmedHandle = handle.trimmingCharacters(in: .whitespaces)
        let trimmedBusiness = businessName.trimmingCharacters(in: .whitespaces)
        // Calendar-date serialization in the device calendar — the same calendar
        // the (unpinned) picker displays, so the wire carries the day the user
        // SAW. A UTC formatter here shifted every evening pick west of UTC to
        // the next day (the BoardEventDate doc has the bug-class writeup).
        let expiry = (needsLicense && addExpiry)
            ? BoardEventDate.ymd(from: licenseExpiry)
            : nil

        _ = await session.registerPro(
            email: email.trimmingCharacters(in: .whitespaces),
            password: password,
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            phone: phone.trimmingCharacters(in: .whitespaces),
            signupInviteCode: signupInviteCode.trimmingCharacters(in: .whitespaces),
            professionType: profession,
            licenseState: licenseState,
            businessName: trimmedBusiness.isEmpty ? nil : trimmedBusiness,
            handle: trimmedHandle.isEmpty ? nil : trimmedHandle,
            licenseNumber: proLicenseNumberToSubmit(licenseNumber),
            licenseExpiry: expiry,
            location: location
        )
    }

    /// Returns the first validation error for `step`, or nil when it's complete.
    private func validate(step: Int) -> String? {
        switch step {
        case 0:
            if licenseState.isEmpty { return "Please select the state you’re licensed or operating in." }
            if let message = work.validate() { return message }
            if needsLicense, proLicenseNumberToSubmit(licenseNumber) == nil {
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
            if signupInviteCode.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Invite code is required while signup is private."
            }
            if email.trimmingCharacters(in: .whitespaces).isEmpty { return "Email is required." }
            if password.count < Self.passwordMinLength {
                return "Password must be at least \(Self.passwordMinLength) characters."
            }
            if !tosAccepted { return "Please accept the Terms and Privacy Policy." }
            return nil
        }
    }
}
