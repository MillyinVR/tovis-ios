// Native client signup — mirrors the web client form (SignupClientClient). Name +
// geocoded ZIP + phone + transactional-SMS consent + email + password + TOS, wired
// to POST /api/v1/auth/register via SessionModel.registerClient. The ZIP is
// resolved to coordinates + timezone through PlacesService.resolveClientZip (the
// same two proxied Google calls the web form makes) so the CLIENT_ZIP payload the
// backend requires is complete.
//
// On success the session flips to `.needsVerification`; RootView swaps to the
// phone verification screen (the register endpoint already texted the code).
import SwiftUI
import TovisKit

/// Prefill + handoff for a signup that CLAIMS pro-created history. Built by
/// `ClaimView` from the claim link's booking context; carries the `inviteToken`
/// the register call sends (with intent=CLAIM_INVITE) so the backend adopts the
/// existing unclaimed profile.
struct ClientSignupClaimContext: Equatable {
    let inviteToken: String
    let firstName: String
    let lastName: String
    let email: String
    let phone: String
}

struct ClientSignupView: View {
    @Environment(SessionModel.self) private var session

    private static let passwordMinLength = 10

    /// Non-nil when this signup is claiming pro-created history (fields prefilled;
    /// register carries intent=CLAIM_INVITE + inviteToken). nil for a normal signup.
    private let claimContext: ClientSignupClaimContext?

    @State private var firstName: String
    @State private var lastName: String
    @State private var zip = ""
    @State private var phone: String
    @State private var email: String
    @State private var password = ""
    @State private var smsConsent = false
    @State private var tosAccepted = false

    /// The ZIP resolved to coordinates + timezone. Non-nil once confirmed; cleared
    /// whenever the ZIP text changes so we never submit a stale location.
    @State private var confirmedZip: ClientSignupLocation?
    @State private var zipConfirming = false
    @State private var zipError: String?

    /// Client-side validation message (server errors use session.errorMessage).
    @State private var formError: String?

    init(claimContext: ClientSignupClaimContext? = nil) {
        self.claimContext = claimContext
        _firstName = State(initialValue: claimContext?.firstName ?? "")
        _lastName = State(initialValue: claimContext?.lastName ?? "")
        _phone = State(initialValue: claimContext?.phone ?? "")
        _email = State(initialValue: claimContext?.email ?? "")
    }

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    HStack(spacing: 12) {
                        field(label: "First name", text: $firstName)
                            .textContentType(.givenName)
                        field(label: "Last name", text: $lastName)
                            .textContentType(.familyName)
                    }

                    zipField

                    Divider().overlay(BrandColor.textMuted.opacity(0.15))

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Phone")
                        BrandField(placeholder: "+1 555 555 5555", text: $phone, isSecure: false)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }

                    consentRow(
                        isOn: $smsConsent,
                        text: Text("I agree to receive transactional texts (verification codes and appointment updates). Message and data rates may apply.")
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Email address")
                        BrandField(placeholder: "you@email.com", text: $email, isSecure: false)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Password")
                        PasswordRevealField(placeholder: "Password", text: $password, textContentType: .newPassword)
                        Text("At least \(Self.passwordMinLength) characters.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }

                    consentRow(isOn: $tosAccepted, text: SignupCopy.tosLabel)

                    if let claimMessage = session.claimableHistoryMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check your email or text")
                                .font(BrandFont.body(14))
                                .fontWeight(.semibold)
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(claimMessage)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(BrandColor.emerald.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(BrandColor.emerald.opacity(0.35), lineWidth: 1)
                        )
                    }

                    if let message = formError ?? session.errorMessage {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    submitButton

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Client account")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            session.errorMessage = nil
            session.clearClaimableHistory()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(claimContext != nil ? "Claim your history" : "Create your client account")
                .font(BrandFont.display(24, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(
                claimContext != nil
                    ? "Create your account to attach your booking history to the right identity."
                    : "Find pros, book fast, and keep your beauty life organized."
            )
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var zipField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel("ZIP code")
                Spacer()
                if zipConfirming {
                    Text("Confirming…")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                } else if let confirmedZip {
                    Text(confirmedZip.timeZoneId)
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }

            BrandField(placeholder: "e.g. 92024", text: $zip, isSecure: false)
                .keyboardType(.numberPad)
                .textContentType(.postalCode)
                .onChange(of: zip) { _, _ in
                    confirmedZip = nil
                    zipError = nil
                }

            if let confirmedZip, confirmedZip.city != nil || confirmedZip.state != nil {
                Text("Near \([confirmedZip.city, confirmedZip.state].compactMap { $0 }.joined(separator: ", "))")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.emerald)
            } else if let zipError {
                Text(zipError)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.ember)
            } else {
                Text("We'll confirm your area when you create the account.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private var submitButton: some View {
        SignupPrimaryButton(
            title: "Create client account",
            isLoading: session.isWorking || zipConfirming,
            isDisabled: session.isWorking || zipConfirming
        ) {
            Task { await handleSubmit() }
        }
    }

    // MARK: - Building blocks

    private func fieldLabel(_ text: String) -> some View {
        SignupFieldLabel(text)
    }

    private func field(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            BrandField(placeholder: label, text: text, isSecure: false)
        }
    }

    private func consentRow(isOn: Binding<Bool>, text: Text) -> some View {
        SignupConsentRow(isOn: isOn, text: text, onToggle: { formError = nil })
    }

    // MARK: - Submit

    /// Confirm the ZIP against the geocode + timezone proxies. Returns the resolved
    /// location, or nil (and sets `zipError`) when it can't be confirmed. Skips the
    /// network call when the current ZIP is already confirmed.
    private func confirmZip() async -> ClientSignupLocation? {
        let raw = zip.trimmingCharacters(in: .whitespaces)

        if let confirmedZip, confirmedZip.postalCode == raw { return confirmedZip }

        guard raw.range(of: "^\\d{5}(-\\d{4})?$", options: .regularExpression) != nil else {
            zipError = "Please enter a valid 5-digit ZIP code."
            return nil
        }

        zipConfirming = true
        defer { zipConfirming = false }
        do {
            let resolved = try await session.client.places.resolveClientZip(postalCode: raw)
            confirmedZip = resolved
            zip = resolved.postalCode
            zipError = nil
            return resolved
        } catch let error as APIError {
            zipError = error.userMessage
            return nil
        } catch {
            zipError = "Could not confirm ZIP code."
            return nil
        }
    }

    private func handleSubmit() async {
        formError = nil
        session.errorMessage = nil

        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)

        guard !trimmedFirst.isEmpty else { formError = "First name is required."; return }
        guard !trimmedLast.isEmpty else { formError = "Last name is required."; return }

        guard let location = await confirmZip() else {
            formError = zipError ?? "Please confirm your ZIP code."
            return
        }

        guard !trimmedPhone.isEmpty else { formError = "Phone number is required."; return }
        guard smsConsent else {
            formError = "Please agree to receive verification and appointment texts."
            return
        }
        guard !trimmedEmail.isEmpty else { formError = "Email is required."; return }
        guard password.count >= Self.passwordMinLength else {
            formError = "Password must be at least \(Self.passwordMinLength) characters."
            return
        }
        guard tosAccepted else {
            formError = "Please accept the Terms and Privacy Policy."
            return
        }

        // Success flips session.state to .needsVerification; RootView swaps to the
        // verification screen and the presenting cover is dismissed with it.
        _ = await session.registerClient(
            email: trimmedEmail,
            password: password,
            firstName: trimmedFirst,
            lastName: trimmedLast,
            phone: trimmedPhone,
            location: location,
            intent: claimContext != nil ? "CLAIM_INVITE" : nil,
            inviteToken: claimContext?.inviteToken
        )
    }
}
