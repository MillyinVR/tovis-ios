// Create-opening sheet for the pro "Last Minute" workspace — the native port of
// the web `LastMinuteCreateOpeningPanel` (`OpeningsClient.tsx`). Builds a slot
// (offerings · location · window) and its three tier plans, then POSTs
// /api/v1/pro/openings (an existing route — no backend change). The server owns
// the rollout schedule; typed errors surface inline. On success it calls
// `onCreated` so `ProLastMinuteView` reloads its openings list.
import SwiftUI
import TovisKit

// MARK: - Tier / offer vocabularies (shared with the openings card)

/// The three rollout tiers + their web-parity labels/hints (`tierLabel`/`tierHint`).
enum LastMinuteTierKind: String, CaseIterable, Identifiable {
    case waitlist = "WAITLIST"
    case reactivation = "REACTIVATION"
    case discovery = "DISCOVERY"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .waitlist: return "Tier 1 · Waitlist"
        case .reactivation: return "Tier 2 · Reactivation"
        case .discovery: return "Tier 3 · Discovery"
        }
    }

    var hint: String {
        switch self {
        case .waitlist: return "Highest intent — recommended with no incentive."
        case .reactivation: return "Lapsed clients — use a gentle nudge if needed."
        case .discovery: return "Broadest audience — use sparingly."
        }
    }

    static func label(_ raw: String) -> String {
        LastMinuteTierKind(rawValue: raw.uppercased())?.label ?? raw
    }
}

/// The five incentive types a tier plan can carry (`OFFER_TYPE_OPTIONS`).
enum LastMinuteOfferKind: String, CaseIterable, Identifiable {
    case none = "NONE"
    case percentOff = "PERCENT_OFF"
    case amountOff = "AMOUNT_OFF"
    case freeService = "FREE_SERVICE"
    case freeAddOn = "FREE_ADD_ON"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "No incentive"
        case .percentOff: return "Percent off"
        case .amountOff: return "Amount off"
        case .freeService: return "Free service"
        case .freeAddOn: return "Free add-on"
        }
    }
}

/// A one-line description of a scheduled tier plan (web `describeTierPlan`).
func describeOpeningTierPlan(_ plan: ProOpeningDto.TierPlan) -> String {
    switch plan.offerType.uppercased() {
    case "PERCENT_OFF":
        if let percent = plan.percentOff { return "\(percent)% off" }
    case "AMOUNT_OFF":
        if let amount = Wire.money(plan.amountOff) { return "\(amount) off" }
    case "FREE_SERVICE":
        return "Free service"
    case "FREE_ADD_ON":
        return plan.freeAddOnService?.name ?? "Free add-on"
    default:
        break
    }
    return "No incentive"
}

// MARK: - Create sheet

/// POST /pro/openings — build a last-minute opening and its tier plans in one Save.
struct ProOpeningCreateSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let offerings: [ProLastMinuteWorkspace.Offering]
    let timeZone: TimeZone
    var onCreated: () -> Void

    /// Per-tier form state (mirrors web `TierPlanFormState`).
    private struct TierPlanForm: Identifiable {
        let tier: LastMinuteTierKind
        var offerType: LastMinuteOfferKind = .none
        var percentOff: String = ""
        var amountOff: String = ""
        var freeAddOnServiceId: String = ""
        var id: String { tier.rawValue }
    }

    @State private var selectedOfferingIds: Set<String>
    @State private var locationType: String = "SALON"
    @State private var visibility: LastMinuteVisibility = .publicAtDiscovery
    @State private var start: Date
    @State private var end: Date
    @State private var useEndAt = true
    @State private var note = ""
    @State private var tierPlans: [TierPlanForm] = LastMinuteTierKind.allCases.map { TierPlanForm(tier: $0) }
    @State private var saving = false
    @State private var error: String?

    init(
        offerings: [ProLastMinuteWorkspace.Offering],
        timeZone: TimeZone,
        onCreated: @escaping () -> Void
    ) {
        self.offerings = offerings
        self.timeZone = timeZone
        self.onCreated = onCreated
        // Default to the first offering selected (web `reconcileSelectedOfferingIds`).
        _selectedOfferingIds = State(initialValue: Set(offerings.first.map { [$0.id] } ?? []))
        let defaultStart = Self.defaultStart(in: timeZone)
        _start = State(initialValue: defaultStart)
        _end = State(initialValue: defaultStart.addingTimeInterval(3600))
    }

    private var windowValid: Bool { !useEndAt || end.timeIntervalSince(start) > 0 }
    private var canSave: Bool { !saving && !selectedOfferingIds.isEmpty && windowValid }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Build the slot once, then let waitlist, reactivation, and discovery roll out through the backend workflow.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)

                    offeringsSection
                    locationAndVisibility
                    windowSection

                    EditField(label: "Note (optional)") {
                        TextField("e.g. Great for trims or quick touch-ups.", text: $note, axis: .vertical)
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.sentences)
                            .editFieldBox()
                    }

                    tierPlansSection

                    Text("Times are in \(timeZone.identifier).")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("New opening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Working…" : "Create") { Task { await save() } }
                        .disabled(!canSave)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
            .environment(\.timeZone, timeZone) // render date pickers in the workspace zone
        }
    }

    // MARK: Offerings

    private var selectedCountLabel: String {
        selectedOfferingIds.count == 1 ? "1 offering selected" : "\(selectedOfferingIds.count) offerings selected"
    }

    @ViewBuilder
    private var offeringsSection: some View {
        EditField(label: "Offerings · \(selectedCountLabel)") {
            if offerings.isEmpty {
                Text("No active offerings available.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textMuted)
                    .editFieldBox()
            } else {
                VStack(spacing: 8) {
                    ForEach(offerings) { offering in
                        offeringRow(offering)
                    }
                }
            }
        }
    }

    private func offeringRow(_ offering: ProLastMinuteWorkspace.Offering) -> some View {
        let checked = selectedOfferingIds.contains(offering.id)
        return Button {
            if checked {
                selectedOfferingIds.remove(offering.id)
            } else {
                selectedOfferingIds.insert(offering.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(checked ? BrandColor.accent : BrandColor.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offering.name)
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    if let base = Wire.money(offering.basePrice) {
                        Text("Starting at \(base)")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(checked ? BrandColor.accent.opacity(0.10) : BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Location + visibility

    private var locationAndVisibility: some View {
        VStack(alignment: .leading, spacing: 20) {
            EditField(label: "Location type") {
                Picker("Location type", selection: $locationType) {
                    Text("Salon").tag("SALON")
                    Text("Mobile").tag("MOBILE")
                }
                .pickerStyle(.segmented)
            }

            EditField(label: "Visibility") {
                Menu {
                    ForEach(LastMinuteVisibility.allCases) { mode in
                        Button(mode.label) { visibility = mode }
                    }
                } label: {
                    HStack {
                        Text(visibility.label)
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    .editFieldBox()
                }
            }
        }
    }

    // MARK: Window

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditField(label: "Start") {
                DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            Toggle(isOn: $useEndAt) {
                Text("Include an end time")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            .tint(BrandColor.accent)

            if useEndAt {
                EditField(label: "End") {
                    DatePicker("", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                if !windowValid {
                    Text("End must be after start.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.amber)
                }
            } else {
                Text("Leave off and the slot runs for the longest selected service.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    // MARK: Tier plans

    private var tierPlansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TIER PLANS")
                .font(BrandFont.mono(11))
                .tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            Text("Waitlist goes first, then reactivation, then discovery. Launch timing stays server-owned.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)

            ForEach($tierPlans) { $plan in
                tierPlanCard($plan)
            }
        }
    }

    private func tierPlanCard(_ plan: Binding<TierPlanForm>) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.wrappedValue.tier.label)
                        .font(BrandFont.body(14, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(plan.wrappedValue.tier.hint)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }

                Menu {
                    ForEach(LastMinuteOfferKind.allCases) { kind in
                        Button(kind.label) { plan.wrappedValue.offerType = kind }
                    }
                } label: {
                    HStack {
                        Text(plan.wrappedValue.offerType.label)
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    .editFieldBox()
                }

                switch plan.wrappedValue.offerType {
                case .percentOff:
                    tierValueField("Percent off", text: plan.percentOff, placeholder: "e.g. 10", keyboard: .numberPad)
                case .amountOff:
                    tierValueField("Amount off", text: plan.amountOff, placeholder: "e.g. 20", keyboard: .decimalPad)
                case .freeAddOn:
                    VStack(alignment: .leading, spacing: 4) {
                        tierValueField("Free add-on service ID", text: plan.freeAddOnServiceId, placeholder: "Paste add-on service ID", keyboard: .default)
                        Text("An ID field until the payload carries eligible add-on services.")
                            .font(BrandFont.body(11))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                case .none, .freeService:
                    EmptyView()
                }
            }
        }
    }

    private func tierValueField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        keyboard: UIKeyboardType
    ) -> some View {
        EditField(label: label) {
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .editFieldBox()
        }
    }

    // MARK: Save

    private struct CreateOpeningError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func buildTierRequest(_ plan: TierPlanForm) throws -> ProOpeningTierPlanRequest {
        switch plan.offerType {
        case .none:
            return ProOpeningTierPlanRequest(tier: plan.tier.rawValue, offerType: "NONE")
        case .freeService:
            return ProOpeningTierPlanRequest(tier: plan.tier.rawValue, offerType: "FREE_SERVICE")
        case .percentOff:
            let trimmed = plan.percentOff.trimmingCharacters(in: .whitespaces)
            guard let parsed = Double(trimmed) else {
                throw CreateOpeningError(message: "\(plan.tier.label) needs a valid percent-off value.")
            }
            return ProOpeningTierPlanRequest(tier: plan.tier.rawValue, offerType: "PERCENT_OFF", percentOff: Int(parsed))
        case .amountOff:
            let trimmed = plan.amountOff.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw CreateOpeningError(message: "\(plan.tier.label) needs an amount-off value.")
            }
            return ProOpeningTierPlanRequest(tier: plan.tier.rawValue, offerType: "AMOUNT_OFF", amountOff: trimmed)
        case .freeAddOn:
            let trimmed = plan.freeAddOnServiceId.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw CreateOpeningError(message: "\(plan.tier.label) needs a free add-on service.")
            }
            return ProOpeningTierPlanRequest(tier: plan.tier.rawValue, offerType: "FREE_ADD_ON", freeAddOnServiceId: trimmed)
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }

        // Preserve display order so the server's per-item sortOrder matches the list.
        let offeringIds = offerings.map(\.id).filter { selectedOfferingIds.contains($0) }
        guard !offeringIds.isEmpty else {
            error = "Select at least one offering."
            return
        }

        let tierRequests: [ProOpeningTierPlanRequest]
        do {
            tierRequests = try tierPlans.map(buildTierRequest)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Check the tier plan values."
            return
        }

        let request = ProOpeningCreateRequest(
            offeringIds: offeringIds,
            startAt: ProCalendarGrid.iso(start),
            endAt: useEndAt ? ProCalendarGrid.iso(end) : nil,
            locationType: locationType,
            visibilityMode: visibility.rawValue,
            note: note.trimmedOrNil,
            tierPlans: tierRequests
        )

        do {
            _ = try await session.client.proSchedule.createOpening(request)
            onCreated()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t create the opening. Try again."
        }
    }

    // MARK: Helpers

    /// Top of the next hour in `tz` — a clean default slot start.
    private static func defaultStart(in tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        let topOfHour = cal.date(from: comps) ?? now
        return topOfHour.addingTimeInterval(3600)
    }
}
