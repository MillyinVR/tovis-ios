// "Offer services" — the client → pro upgrade, native.
//
// Web parity: app/client/(gated)/settings/become-a-pro. The API door
// (POST /api/v1/pro/upgrade) has existed since #987 and the web form since
// #996; native had NO caller at all, so a client on the phone who decided to
// start taking bookings had to find a browser. This screen is that caller.
//
// It asks for LESS than pro signup does, and that is the whole point of the
// door: the person is signed in and already verified, so their name, phone and
// consents carry over server-side. What is left is only what the app cannot know
// about a client — what they do, where they do it, what licenses them to do it,
// and what they trade under. Every one of those fields is the SAME component
// `ProSignupView` renders (`ProWorkFields.swift`), because a fork in the licence
// card is how one of the two doors quietly stops asking.
//
// ⚠️ The upgrade is IRREVERSIBLE from the app and flips the account's home role
// to PRO (the route's own DECISION note explains why it must). So the confirm
// row is not decoration — it is the only place a person is told what is about to
// change about their account before it changes.
import SwiftUI
import TovisKit

/// What `SessionModel.upgradeToPro` did. `alreadyPro` is not a failure: the
/// workspace already existed, so the session was switched into it instead.
enum ProUpgradeOutcome {
    case upgraded
    case alreadyPro
    case failed
}

struct ClientBecomeProView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var profession: ProfessionType = .cosmetologist
    @State private var licenseState = ""
    @State private var licenseNumber = ""
    @State private var addExpiry = false
    @State private var licenseExpiry = Date()
    @State private var businessName = ""
    @State private var handle = ""
    @State private var work = ProWorkLocationModel()
    @State private var confirmed = false
    @State private var formError: String?

    private var needsLicense: Bool { profession.requiresLicenseByDefault }

    private var isBusy: Bool { session.isWorking || work.isResolving }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                ProProfessionFields(
                    profession: $profession,
                    licenseState: $licenseState,
                    onEdit: clearError
                )

                ProWorkLocationFields(
                    model: work,
                    onEdit: clearError,
                    onError: { formError = $0 }
                )

                if needsLicense {
                    ProLicenseFields(
                        licenseState: licenseState,
                        licenseNumber: $licenseNumber,
                        addExpiry: $addExpiry,
                        licenseExpiry: $licenseExpiry,
                        onEdit: clearError
                    )
                }

                ProBrandingFields(
                    businessName: $businessName,
                    handle: $handle,
                    onEdit: clearError
                )

                confirmRow

                // Directly above the control it reports on — the same placement
                // the signup screens use, and this screen borrows their fields.
                if let message = formError ?? session.errorMessage {
                    Text(message)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SignupPrimaryButton(
                    title: session.isWorking ? "Setting up…" : "Set up my pro account",
                    isLoading: isBusy,
                    isDisabled: isBusy
                ) {
                    Task { await submit() }
                }
            }
            .padding(20)
        }
        .cappedWidth(AdaptiveWidth.reading)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Offer services")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .tint(BrandColor.accent)
        .onDisappear {
            work.cancelSearch()
            session.errorMessage = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a pro workspace")
                .font(BrandFont.display(22, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Take bookings, run a calendar and get paid. Your client account stays yours — switch between the two whenever you like.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one place the person is told what this does to their ACCOUNT, not
    /// just what it gives them. Reuses the signup consent row so it reads like
    /// every other thing they have had to agree to.
    private var confirmRow: some View {
        SignupConsentRow(
            isOn: $confirmed,
            text: Text("I understand this account becomes a **pro account**. Your bookings, boards and chart stay exactly where they are — use the workspace switcher to come back to them at any time. This cannot be undone from the app."),
            onToggle: clearError
        )
    }

    private func clearError() {
        formError = nil
        session.errorMessage = nil
    }

    // MARK: - Submit

    private func submit() async {
        clearError()

        if let message = validate() {
            formError = message
            return
        }

        // Unreachable once validate() passed — it narrows the payload.
        guard let location = work.signupLocation() else {
            formError = "Please confirm where you offer services."
            return
        }

        let trimmedBusiness = businessName.trimmingCharacters(in: .whitespaces)
        let trimmedHandle = handle.trimmingCharacters(in: .whitespaces)
        // Calendar-date serialization in the DEVICE calendar — the same calendar
        // the picker displays, so the wire carries the day the person SAW. A UTC
        // formatter here shifts every evening pick west of UTC to the next day.
        let expiry = (needsLicense && addExpiry)
            ? BoardEventDate.ymd(from: licenseExpiry)
            : nil

        let outcome = await session.upgradeToPro(
            professionType: profession,
            licenseState: licenseState,
            businessName: trimmedBusiness.isEmpty ? nil : trimmedBusiness,
            handle: trimmedHandle.isEmpty ? nil : trimmedHandle,
            licenseNumber: proLicenseNumberToSubmit(licenseNumber),
            licenseExpiry: expiry,
            location: location
        )

        switch outcome {
        case .upgraded, .alreadyPro:
            // The session now acts as PRO, so RootView has already swapped the
            // whole shell underneath this screen. Dismissing leaves nothing of
            // the client navigation stack pointing at a workspace that moved.
            dismiss()
        case .failed:
            // The message is on `session.errorMessage`, rendered above the
            // button — the form stays usable so a taken handle or a refused
            // licence can be corrected and retried.
            break
        }
    }

    /// The first thing wrong, or nil. Mirrors the web form's field order so the
    /// person is never told about a later problem while an earlier one stands.
    private func validate() -> String? {
        if licenseState.isEmpty { return "Please select the state you’re licensed or operating in." }
        if let message = work.validate() { return message }
        if needsLicense, proLicenseNumberToSubmit(licenseNumber) == nil {
            return "A license number is required for this profession in your state."
        }
        if !confirmed {
            return "Please confirm you understand your account becomes a pro account."
        }
        return nil
    }
}
