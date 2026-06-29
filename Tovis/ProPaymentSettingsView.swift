// Pro payment settings — native port of the web Edit payment settings modal
// (app/pro/profile/public-profile/EditPaymentSettingsButton.tsx), 1:1 copy. Reads
// GET /pro/payment-settings, edits collection timing / deposits / accepted methods
// (with handles) / tips (+ suggestions) / a client note, and PATCHes the upsert.
// Presented as a sheet from the profile card's "Payment settings" button.
import SwiftUI
import TovisKit

struct ProPaymentSettingsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case loading, ready, failed(String) }
    @State private var phase: Phase = .loading

    @State private var collectPaymentAt = "AFTER_SERVICE"

    @State private var depositEnabled = false
    @State private var depositType = "FLAT"
    @State private var depositFlatAmount = ""
    @State private var depositPercent = ""
    @State private var depositScope = "NEW_DISCOVERY_ONLY"

    @State private var acceptCash = true
    @State private var acceptCardOnFile = false
    @State private var acceptTapToPay = false
    @State private var acceptVenmo = false
    @State private var acceptZelle = false
    @State private var acceptAppleCash = false
    @State private var acceptPaypal = false
    @State private var acceptApplePay = false

    @State private var tipsEnabled = true
    @State private var allowCustomTip = true
    @State private var tips: [TipDraft] = TipDraft.defaults

    @State private var venmoHandle = ""
    @State private var zelleHandle = ""
    @State private var appleCashHandle = ""
    @State private var paypalHandle = ""
    @State private var paymentNote = ""

    @State private var saving = false
    @State private var savedFlash = false
    @State private var error: String?

    private struct TipDraft: Identifiable, Equatable {
        let id = UUID()
        var label: String
        var percent: String
        static let defaults: [TipDraft] = [
            TipDraft(label: "18%", percent: "18"),
            TipDraft(label: "20%", percent: "20"),
            TipDraft(label: "25%", percent: "25"),
        ]
    }

    private var acceptedMethodsCount: Int {
        [acceptCash, acceptCardOnFile, acceptTapToPay, acceptVenmo,
         acceptZelle, acceptAppleCash, acceptPaypal, acceptApplePay].filter { $0 }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    errorState(message)
                case .ready:
                    form
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Payment settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .ready = phase {
                        Button(savedFlash ? "Saved ✓" : (saving ? "Saving…" : "Save")) {
                            Task { await save() }
                        }
                        .disabled(saving).tint(BrandColor.accent)
                    }
                }
            }
            .task { if case .loading = phase { await load() } }
            .tint(BrandColor.accent)
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Control checkout timing, accepted methods, and tipping.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)

                collectionTiming
                deposits
                acceptedMethods
                tipsSection
                clientNote

                if let error {
                    Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Sections

    private var collectionTiming: some View {
        sectionCard(
            title: "Collection timing",
            subtitle: "Choose when payment is normally collected for this professional."
        ) {
            VStack(spacing: 8) {
                radioRow(
                    checked: collectPaymentAt == "AT_BOOKING",
                    label: "Collect at booking",
                    description: "Use this when bookings should be paid up front."
                ) { collectPaymentAt = "AT_BOOKING" }
                radioRow(
                    checked: collectPaymentAt == "AFTER_SERVICE",
                    label: "Collect after service",
                    description: "Use this when checkout happens after the booking."
                ) { collectPaymentAt = "AFTER_SERVICE" }
            }
        }
    }

    private var deposits: some View {
        sectionCard(
            title: "Deposits",
            subtitle: "Require a deposit to hold the booking. New clients who find you through the Looks feed or Discovery also pay a one-time booking fee, processed with the deposit through Stripe."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(
                    isOn: $depositEnabled,
                    label: "Require a deposit",
                    description: "Collected up front via card and credited toward the final total."
                )

                if depositEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldHeader("Deposit amount")
                        radioRow(
                            checked: depositType == "FLAT",
                            label: "Flat amount",
                            description: "A fixed dollar deposit."
                        ) { depositType = "FLAT" }
                        radioRow(
                            checked: depositType == "PERCENT",
                            label: "Percent of price",
                            description: "A share of the service price."
                        ) { depositType = "PERCENT" }
                    }

                    if depositType == "FLAT" {
                        textInput("Deposit amount ($)", text: $depositFlatAmount, placeholder: "e.g. 20", keyboard: .decimalPad)
                    } else {
                        textInput("Deposit percent (1–100)", text: $depositPercent, placeholder: "e.g. 25", keyboard: .numberPad)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        fieldHeader("Who leaves a deposit")
                        radioRow(
                            checked: depositScope == "NEW_DISCOVERY_ONLY",
                            label: "New clients from Looks / Discovery only",
                            description: "Recommended. Only brand-new clients who found you through the feed."
                        ) { depositScope = "NEW_DISCOVERY_ONLY" }
                        radioRow(
                            checked: depositScope == "ALL_NEW_CLIENTS",
                            label: "All first-time clients",
                            description: "Any client booking with you for the first time."
                        ) { depositScope = "ALL_NEW_CLIENTS" }
                        radioRow(
                            checked: depositScope == "ALL_CLIENTS",
                            label: "Every booking",
                            description: "Charge a deposit on all bookings."
                        ) { depositScope = "ALL_CLIENTS" }
                    }

                    Text("Deposits require Stripe payouts to be set up. The one-time booking fee applies only to brand-new Looks/Discovery clients — never to your existing clients.")
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(BrandColor.bgPrimary.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var acceptedMethods: some View {
        sectionCard(
            title: "Accepted methods",
            subtitle: "Currently enabled: \(acceptedMethodsCount)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(isOn: $acceptCash, label: "Cash", description: "Show cash as an accepted payment method.")
                toggleRow(isOn: $acceptCardOnFile, label: "Card on file", description: "Show saved card payment as accepted.")
                toggleRow(isOn: $acceptTapToPay, label: "Tap to pay", description: "Show in-person tap to pay as accepted.")
                toggleRow(isOn: $acceptVenmo, label: "Venmo", description: "Show Venmo as accepted.")
                if acceptVenmo {
                    textInput("Venmo handle", text: $venmoHandle, placeholder: "@yourhandle")
                }
                toggleRow(isOn: $acceptZelle, label: "Zelle", description: "Show Zelle as accepted.")
                if acceptZelle {
                    textInput("Zelle handle or contact", text: $zelleHandle, placeholder: "email or phone")
                }
                toggleRow(isOn: $acceptAppleCash, label: "Apple Cash", description: "Show Apple Cash as accepted.")
                if acceptAppleCash {
                    textInput("Apple Cash handle or contact", text: $appleCashHandle, placeholder: "phone, email, or handle")
                }
                toggleRow(isOn: $acceptPaypal, label: "PayPal", description: "Show PayPal as accepted.")
                if acceptPaypal {
                    textInput("PayPal link or handle", text: $paypalHandle, placeholder: "paypal.me/you or @handle")
                }
                toggleRow(isOn: $acceptApplePay, label: "Apple Pay", description: "Show Apple Pay as accepted (in person).")
            }
        }
    }

    private var tipsSection: some View {
        sectionCard(
            title: "Tips",
            subtitle: "Tip applies to services only, not product purchases."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(isOn: $tipsEnabled, label: "Enable tips", description: "Allow clients to add a tip during checkout.")

                if tipsEnabled {
                    toggleRow(isOn: $allowCustomTip, label: "Allow custom tip", description: "Clients can enter a custom tip amount.")

                    VStack(alignment: .leading, spacing: 8) {
                        fieldHeader("Suggested tip options")
                        ForEach($tips) { $row in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .bottom, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        smallHeader("Label")
                                        plainField(text: $row.label, placeholder: "e.g. 20%")
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        smallHeader("Percent")
                                        plainField(text: $row.percent, placeholder: "20", keyboard: .decimalPad)
                                            .frame(width: 90)
                                    }
                                    Button("Remove") { tips.removeAll { $0.id == row.id } }
                                        .font(BrandFont.body(12, .semibold))
                                        .foregroundStyle(tips.count <= 1 ? BrandColor.textMuted : BrandColor.textPrimary)
                                        .disabled(tips.count <= 1)
                                }
                            }
                            .padding(12)
                            .background(BrandColor.bgPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Button("Add tip option") {
                            tips.append(TipDraft(label: "", percent: ""))
                        }
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(BrandColor.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var clientNote: some View {
        sectionCard(
            title: "Client note",
            subtitle: "Optional note shown with payment methods during checkout."
        ) {
            TextEditor(text: $paymentNote)
                .frame(minHeight: 90)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(BrandColor.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textPrimary)
        }
    }

    // MARK: - Reusable rows (mirror the web SectionCard / ToggleRow / RadioRow / TextInput)

    private func sectionCard<C: View>(title: String, subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text(subtitle).font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgPrimary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    private func toggleRow(isOn: Binding<Bool>, label: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text(description).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(BrandColor.accent).disabled(saving)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func radioRow(checked: Bool, label: String, description: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: checked ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(checked ? BrandColor.accent : BrandColor.textMuted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Text(description).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandColor.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    private func textInput(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldHeader(label)
            plainField(text: text, placeholder: placeholder, keyboard: keyboard)
        }
    }

    private func plainField(text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textPrimary)
            .padding(12)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(saving)
    }

    private func fieldHeader(_ t: String) -> some View {
        Text(t).font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
    }

    private func smallHeader(_ t: String) -> some View {
        Text(t).font(BrandFont.mono(10)).tracking(0.6).foregroundStyle(BrandColor.textSecondary)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Data

    private func load() async {
        do {
            let settings = try await session.client.proProfile.paymentSettings()
            if let s = settings { apply(s) }
            phase = .ready
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your payment settings.")
        }
    }

    private func apply(_ s: ProPaymentSettings) {
        collectPaymentAt = s.collectPaymentAt
        depositEnabled = s.depositEnabled
        depositType = s.depositType
        depositFlatAmount = s.depositFlatAmount ?? ""
        depositPercent = s.depositPercent.map(String.init) ?? ""
        depositScope = s.depositScope
        acceptCash = s.acceptCash
        acceptCardOnFile = s.acceptCardOnFile
        acceptTapToPay = s.acceptTapToPay
        acceptVenmo = s.acceptVenmo
        acceptZelle = s.acceptZelle
        acceptAppleCash = s.acceptAppleCash
        acceptPaypal = s.acceptPaypal
        acceptApplePay = s.acceptApplePay
        tipsEnabled = s.tipsEnabled
        allowCustomTip = s.allowCustomTip
        if let suggestions = s.tipSuggestions, !suggestions.isEmpty {
            tips = suggestions.map { TipDraft(label: $0.label, percent: String(Int($0.percent))) }
        }
        venmoHandle = s.venmoHandle ?? ""
        zelleHandle = s.zelleHandle ?? ""
        appleCashHandle = s.appleCashHandle ?? ""
        paypalHandle = s.paypalHandle ?? ""
        paymentNote = s.paymentNote ?? ""
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }

        let parsedTips: [ProPaymentTipSuggestion] = tipsEnabled
            ? tips.compactMap { draft in
                let label = draft.label.trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, let pct = Double(draft.percent.trimmingCharacters(in: .whitespaces)),
                      pct >= 0, pct <= 100 else { return nil }
                return ProPaymentTipSuggestion(label: label, percent: pct)
            }
            : []

        let update = ProPaymentSettingsUpdate(
            collectPaymentAt: collectPaymentAt,
            depositEnabled: depositEnabled,
            depositType: depositType,
            depositScope: depositScope,
            depositFlatAmount: depositEnabled && depositType == "FLAT" ? trimmedOrNil(depositFlatAmount) : nil,
            depositPercent: depositEnabled && depositType == "PERCENT" ? trimmedOrNil(depositPercent) : nil,
            acceptCash: acceptCash,
            acceptCardOnFile: acceptCardOnFile,
            acceptTapToPay: acceptTapToPay,
            acceptVenmo: acceptVenmo,
            acceptZelle: acceptZelle,
            acceptAppleCash: acceptAppleCash,
            acceptPaypal: acceptPaypal,
            acceptApplePay: acceptApplePay,
            tipsEnabled: tipsEnabled,
            allowCustomTip: allowCustomTip,
            tipSuggestions: parsedTips,
            venmoHandle: acceptVenmo ? trimmedOrNil(venmoHandle) : nil,
            zelleHandle: acceptZelle ? trimmedOrNil(zelleHandle) : nil,
            appleCashHandle: acceptAppleCash ? trimmedOrNil(appleCashHandle) : nil,
            paypalHandle: acceptPaypal ? trimmedOrNil(paypalHandle) : nil,
            paymentNote: trimmedOrNil(paymentNote)
        )

        do {
            if let saved = try await session.client.proProfile.updatePaymentSettings(update) {
                apply(saved)
            }
            savedFlash = true
            session.signalRefresh()
            try? await Task.sleep(nanoseconds: 250_000_000)
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Failed to save payment settings."
        }
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
