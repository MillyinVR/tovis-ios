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

struct ClientSignupView: View {
    @Environment(SessionModel.self) private var session

    private static let passwordMinLength = 10

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var zip = ""
    @State private var phone = ""
    @State private var email = ""
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

    private let termsURL = URL(string: "https://www.tovis.app/terms")
    private let privacyURL = URL(string: "https://www.tovis.app/privacy")

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
                        BrandField(placeholder: "Password", text: $password, isSecure: true)
                            .textContentType(.newPassword)
                        Text("At least \(Self.passwordMinLength) characters.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }

                    consentRow(isOn: $tosAccepted, text: tosLabel)

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
        .onDisappear { session.errorMessage = nil }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create your client account")
                .font(BrandFont.display(24, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Find pros, book fast, and keep your beauty life organized.")
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
        Button {
            Task { await handleSubmit() }
        } label: {
            Group {
                if session.isWorking || zipConfirming {
                    ProgressView().tint(BrandColor.onAccent)
                } else {
                    Text("Create client account").font(BrandFont.body(17, .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(BrandColor.accent)
            .foregroundStyle(BrandColor.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(session.isWorking || zipConfirming)
        .padding(.top, 4)
    }

    private var tosLabel: Text {
        var label = Text("I agree to the ")
        if let termsURL {
            label = label + Text("[Terms](\(termsURL.absoluteString))")
        } else {
            label = label + Text("Terms")
        }
        label = label + Text(" and ")
        if let privacyURL {
            label = label + Text("[Privacy Policy](\(privacyURL.absoluteString))")
        } else {
            label = label + Text("Privacy Policy")
        }
        return label + Text(".")
    }

    // MARK: - Building blocks

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(BrandColor.textSecondary)
    }

    private func field(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            BrandField(placeholder: label, text: text, isSecure: false)
        }
    }

    private func consentRow(isOn: Binding<Bool>, text: Text) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            formError = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isOn.wrappedValue ? BrandColor.accent : BrandColor.textMuted)
                text
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .tint(BrandColor.accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
            location: location
        )
    }
}
