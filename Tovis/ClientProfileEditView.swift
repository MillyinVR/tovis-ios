// Native port of the web Settings → Profile card
// (app/client/(gated)/settings/ClientProfileSettings.tsx), backed by
// GET/PATCH /api/v1/client/settings via ClientSettingsService. Edits the client's
// identity details — first/last name, phone, birthday, avatar URL. Saved addresses
// are a separate surface (as on web), so they're intentionally not here.
import SwiftUI
import TovisKit

struct ClientProfileEditView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// The last-saved profile, used both for the email chip and dirty-tracking.
    @State private var original: ClientSettingsProfile?

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var phone = ""
    @State private var avatarUrl = ""
    @State private var hasBirthday = false
    @State private var birthday = Date()

    @State private var saving = false
    @State private var banner: Banner?

    private struct Banner: Equatable {
        enum Kind { case success, error }
        let kind: Kind
        let text: String
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().tint(BrandColor.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                errorState(message)
            case .loaded:
                form
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let email = original?.email {
                    Text(email)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(BrandColor.bgSurface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
                }

                if let banner {
                    Text(banner.text)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(banner.kind == .success ? BrandColor.accent : BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background((banner.kind == .success ? BrandColor.accent : BrandColor.ember).opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                HStack(spacing: 12) {
                    field("First name") {
                        BrandField(
                            placeholder: "First name", text: $firstName, isSecure: false,
                            textContentType: .givenName, autocapitalization: .words
                        )
                    }
                    field("Last name") {
                        BrandField(
                            placeholder: "Last name", text: $lastName, isSecure: false,
                            textContentType: .familyName, autocapitalization: .words
                        )
                    }
                }

                field("Phone", help: "Used for booking updates and communication.") {
                    BrandField(
                        placeholder: "+1 (___) ___-____", text: $phone, isSecure: false,
                        keyboardType: .phonePad, textContentType: .telephoneNumber
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $hasBirthday) {
                        SignupFieldLabel("Birthday")
                    }
                    .tint(BrandColor.accent)

                    if hasBirthday {
                        DatePicker(
                            "Birthday",
                            selection: $birthday,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(BrandColor.accent)
                        .foregroundStyle(BrandColor.textPrimary)
                        .environment(\.calendar, Self.utcCalendar)
                    }

                    Text("Optional for now. Later this can support better personalization.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                field("Avatar URL", help: "Optional. Leave blank if you don't want to set this yet.") {
                    BrandField(
                        placeholder: "https://…", text: $avatarUrl, isSecure: false,
                        keyboardType: .URL, textContentType: .URL,
                        autocapitalization: .never, autocorrectionDisabled: true
                    )
                }

                Text("Address management lives in Saved addresses, so your search area and mobile service locations stay separate from your identity details.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BrandColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                SignupPrimaryButton(
                    title: "Save profile",
                    isLoading: saving,
                    isDisabled: !dirty
                ) {
                    Task { await save() }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String, help: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel(label)
            content()
            if let help {
                Text(help)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 24)
    }

    // MARK: - Dirty tracking (mirrors the web form's comparison)

    private var dirty: Bool {
        guard let original else { return false }
        return firstName != original.firstName
            || lastName != original.lastName
            || phone != (original.phone ?? "")
            || avatarUrl != (original.avatarUrl ?? "")
            || birthdayWireValue != (original.dateOfBirth ?? "")
    }

    /// The current birthday as the `YYYY-MM-DD` the wire wants, or "" when off.
    private var birthdayWireValue: String {
        hasBirthday ? Self.dateFormatter.string(from: birthday) : ""
    }

    // MARK: - Load / save

    private func load() async {
        phase = .loading
        do {
            let profile = try await session.client.clientSettings.profile()
            apply(profile)
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Failed to load profile.")
        }
    }

    private func apply(_ profile: ClientSettingsProfile) {
        original = profile
        firstName = profile.firstName
        lastName = profile.lastName
        phone = profile.phone ?? ""
        avatarUrl = profile.avatarUrl ?? ""
        if let dob = profile.dateOfBirth, let date = Self.dateFormatter.date(from: dob) {
            hasBirthday = true
            birthday = date
        } else {
            hasBirthday = false
            birthday = Date()
        }
    }

    private func save() async {
        guard !saving, dirty else { return }
        saving = true
        banner = nil
        defer { saving = false }


        do {
            let updated = try await session.client.clientSettings.updateProfile(
                firstName: firstName,
                lastName: lastName,
                phone: phone.trimmedOrNil,
                avatarUrl: avatarUrl.trimmedOrNil,
                dateOfBirth: hasBirthday ? Self.dateFormatter.string(from: birthday) : nil
            )
            apply(updated)
            banner = Banner(kind: .success, text: "Profile updated.")
        } catch let error as APIError {
            banner = Banner(kind: .error, text: error.userMessage)
        } catch {
            banner = Banner(kind: .error, text: "Failed to save profile.")
        }
    }

    // Date-only formatter for the birthday ("YYYY-MM-DD"), matching the web
    // endpoint's shape. Fixed UTC + POSIX locale so the day never shifts with the
    // device zone (same convention as ProVerificationView's license expiry).
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A UTC-pinned Gregorian calendar so the DatePicker operates in the same zone
    /// the formatter reads, keeping the picked day and the wire string aligned.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
