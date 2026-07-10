// Editor sheets for the pro "Last Minute" workspace — native ports of the web
// `/pro/last-minute` settings editor (`settingsClient.tsx`): the "Last-minute
// defaults" form, per-service eligibility rules, and blocked time ranges. Each
// sheet PATCHes/POSTs/DELETEs an existing route (no backend change), then calls
// `onSaved` so `ProLastMinuteView` reloads the workspace. See
// docs/PRO-BACKEND-CONTRACTS.md.
import SwiftUI
import TovisKit

// MARK: - Shared helpers

/// A lightweight money check mirroring the web `isMoney` gate: a non-negative
/// amount with at most two decimals ("80" or "79.99"). The server re-validates.
func isLastMinuteMoney(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    guard trimmed.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil else { return false }
    return true
}

/// The three last-minute visibility modes + their web-parity labels.
enum LastMinuteVisibility: String, CaseIterable, Identifiable {
    case targetedOnly = "TARGETED_ONLY"
    case publicAtDiscovery = "PUBLIC_AT_DISCOVERY"
    case publicImmediate = "PUBLIC_IMMEDIATE"

    var id: String { rawValue }

    /// Mirrors web `visibilityLabel(...)`.
    var label: String {
        switch self {
        case .targetedOnly: return "Targeted only"
        case .publicAtDiscovery: return "Public at discovery"
        case .publicImmediate: return "Public immediately"
        }
    }

    static func from(_ raw: String) -> LastMinuteVisibility {
        LastMinuteVisibility(rawValue: raw.uppercased()) ?? .publicAtDiscovery
    }
}

/// A tier "send time" anchor is stored as minutes-after-midnight (0…1439) in the
/// pro's local zone. We map to/from a `Date` for the time picker — and to a
/// display label — using a fixed UTC-pinned calendar so the arithmetic is pure
/// wall-clock (no DST surprises). Shared by the settings sheet (picker binding)
/// and `ProLastMinuteView` (display).
enum LastMinuteAnchor {
    /// The fixed calendar all anchor math flows through.
    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    static let displayZone = TimeZone(identifier: "UTC") ?? .current

    static func date(fromMinutes minutes: Int) -> Date {
        let safe = max(0, min(1439, minutes))
        var comps = DateComponents()
        comps.year = 2000; comps.month = 1; comps.day = 1
        comps.hour = safe / 60; comps.minute = safe % 60
        return utcCalendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    static func minutes(fromDate date: Date) -> Int {
        let comps = utcCalendar.dateComponents([.hour, .minute], from: date)
        return max(0, min(1439, (comps.hour ?? 0) * 60 + (comps.minute ?? 0)))
    }

    /// A local wall-clock label, e.g. "7:00 PM".
    static func label(_ minutes: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = displayZone
        f.dateFormat = "h:mm a"
        return f.string(from: date(fromMinutes: minutes))
    }
}

// MARK: - Field scaffolding (matches ProBlockTimeSheet's treatment)

private struct EditField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(BrandFont.mono(11))
                .tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            content
        }
    }
}

private extension View {
    func editFieldBox() -> some View {
        padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Settings sheet ("Last-minute defaults")

/// PATCH /pro/last-minute/settings — the master toggle, default visibility,
/// floor, tier anchors, priority offers, and per-day disables in one Save.
struct ProLastMinuteSettingsSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let settings: ProLastMinuteWorkspace.Settings
    var onSaved: () -> Void

    @State private var enabled: Bool
    @State private var visibility: LastMinuteVisibility
    @State private var minSubtotal: String
    @State private var tier2Anchor: Date
    @State private var tier3Anchor: Date
    @State private var priorityOfferEnabled: Bool
    @State private var priorityOfferMinutes: Int
    @State private var disabledDays: [Bool]   // Mon…Sun
    @State private var saving = false
    @State private var error: String?

    private static let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    init(settings: ProLastMinuteWorkspace.Settings, onSaved: @escaping () -> Void) {
        self.settings = settings
        self.onSaved = onSaved
        _enabled = State(initialValue: settings.enabled)
        _visibility = State(initialValue: .from(settings.defaultVisibilityMode))
        _minSubtotal = State(initialValue: settings.minCollectedSubtotal ?? "")
        _tier2Anchor = State(initialValue: LastMinuteAnchor.date(fromMinutes: settings.tier2NightBeforeMinutes))
        _tier3Anchor = State(initialValue: LastMinuteAnchor.date(fromMinutes: settings.tier3DayOfMinutes))
        _priorityOfferEnabled = State(initialValue: settings.priorityOfferEnabled)
        _priorityOfferMinutes = State(initialValue: min(120, max(5, settings.priorityOfferMinutes)))
        _disabledDays = State(initialValue: [
            settings.disableMon, settings.disableTue, settings.disableWed, settings.disableThu,
            settings.disableFri, settings.disableSat, settings.disableSun,
        ])
    }

    private var minSubtotalValid: Bool {
        let trimmed = minSubtotal.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || isLastMinuteMoney(trimmed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Set the default visibility, floor protection, tier anchors, and blocked days for last-minute openings.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)

                    Toggle(isOn: $enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last-minute openings")
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(enabled ? "Enabled" : "Disabled")
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    .tint(BrandColor.accent)

                    EditField(label: "Default visibility") { visibilityMenu }

                    EditField(label: "Minimum collected subtotal") {
                        TextField("e.g. 80 or 79.99", text: $minSubtotal)
                            .keyboardType(.decimalPad)
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textPrimary)
                            .editFieldBox()
                    }
                    if !minSubtotalValid {
                        Text("Minimum collected subtotal must be like 80 or 79.99.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.amber)
                    }
                    Text("Leave blank for no floor. Openings below this collected subtotal are held back.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)

                    anchorField("Tier 2 · night-before send time", selection: $tier2Anchor)
                    anchorField("Tier 3 · day-of send time", selection: $tier3Anchor)

                    priorityOfferCard

                    EditField(label: "Disable last-minute on days") { dayGrid }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Last-minute defaults")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || !minSubtotalValid)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private var visibilityMenu: some View {
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

    private func anchorField(_ label: String, selection: Binding<Date>) -> some View {
        EditField(label: label) {
            DatePicker("", selection: selection, displayedComponents: [.hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                // Anchors are pure wall-clock minutes; pin the picker to the same
                // UTC calendar the minute<->Date mapping uses.
                .environment(\.timeZone, LastMinuteAnchor.displayZone)
        }
    }

    private var priorityOfferCard: some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $priorityOfferEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Priority offers for your waitlist")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(priorityOfferEnabled ? "Offered one at a time in join order" : "Notify all at once")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                .tint(BrandColor.accent)

                if priorityOfferEnabled {
                    Stepper(value: $priorityOfferMinutes, in: 5...120, step: 5) {
                        HStack {
                            Text("Claim window")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                            Spacer()
                            Text("\(priorityOfferMinutes) min")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                    }
                    Text("How long each client has to claim before the offer moves on. 5–120 minutes.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    private var dayGrid: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.dayLabels.enumerated()), id: \.offset) { idx, label in
                let disabled = disabledDays[idx]
                Button {
                    disabledDays[idx].toggle()
                } label: {
                    Text(label.uppercased())
                        .font(BrandFont.mono(9))
                        // A day that is NOT disabled is "on" (eligible) → accent.
                        .foregroundStyle(disabled ? BrandColor.textMuted : BrandColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(disabled ? BrandColor.bgSurface : BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func save() async {
        guard !saving, minSubtotalValid else { return }
        saving = true
        error = nil
        defer { saving = false }

        let trimmedFloor = minSubtotal.trimmingCharacters(in: .whitespaces)
        let request = ProLastMinuteSettingsPatchRequest(
            enabled: enabled,
            defaultVisibilityMode: visibility.rawValue,
            minCollectedSubtotal: trimmedFloor.isEmpty ? nil : trimmedFloor,
            tier2NightBeforeMinutes: LastMinuteAnchor.minutes(fromDate: tier2Anchor),
            tier3DayOfMinutes: LastMinuteAnchor.minutes(fromDate: tier3Anchor),
            priorityOfferEnabled: priorityOfferEnabled,
            priorityOfferMinutes: priorityOfferMinutes,
            disableMon: disabledDays[0],
            disableTue: disabledDays[1],
            disableWed: disabledDays[2],
            disableThu: disabledDays[3],
            disableFri: disabledDays[4],
            disableSat: disabledDays[5],
            disableSun: disabledDays[6]
        )

        do {
            try await session.client.proSchedule.updateLastMinuteSettings(request)
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save your settings. Try again."
        }
    }
}

// MARK: - Service rule sheet ("Service eligibility")

/// PATCH /pro/last-minute/rules — one per-service eligibility rule (enabled +
/// optional floor). A blank floor inherits the global minimum.
struct ProLastMinuteServiceRuleSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let offering: ProLastMinuteWorkspace.Offering
    let rule: ProLastMinuteWorkspace.ServiceRule?
    var onSaved: () -> Void

    @State private var enabled: Bool
    @State private var minSubtotal: String
    @State private var saving = false
    @State private var error: String?

    init(
        offering: ProLastMinuteWorkspace.Offering,
        rule: ProLastMinuteWorkspace.ServiceRule?,
        onSaved: @escaping () -> Void
    ) {
        self.offering = offering
        self.rule = rule
        self.onSaved = onSaved
        _enabled = State(initialValue: rule?.enabled ?? true)
        _minSubtotal = State(initialValue: rule?.minCollectedSubtotal ?? "")
    }

    private var minSubtotalValid: Bool {
        let trimmed = minSubtotal.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || isLastMinuteMoney(trimmed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let base = Wire.money(offering.basePrice) {
                        Text("Base price: \(base)")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }

                    Toggle(isOn: $enabled) {
                        Text(enabled ? "Eligible for last-minute" : "Excluded from last-minute")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                    .tint(BrandColor.accent)

                    EditField(label: "Minimum collected subtotal") {
                        TextField("Leave blank to inherit global floor", text: $minSubtotal)
                            .keyboardType(.decimalPad)
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textPrimary)
                            .editFieldBox()
                    }
                    if !minSubtotalValid {
                        Text("Minimum collected subtotal must be like 80 or 79.99.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.amber)
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(offering.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || !minSubtotalValid)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func save() async {
        guard !saving, minSubtotalValid else { return }
        saving = true
        error = nil
        defer { saving = false }

        let trimmedFloor = minSubtotal.trimmingCharacters(in: .whitespaces)
        do {
            try await session.client.proSchedule.updateLastMinuteServiceRule(
                serviceId: offering.serviceId,
                enabled: enabled,
                minCollectedSubtotal: trimmedFloor.isEmpty ? nil : trimmedFloor
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save the rule. Try again."
        }
    }
}

// MARK: - Add block sheet ("Blocks")

/// POST /pro/last-minute/blocks — block a time range from ever being offered as
/// a last-minute opening. The route rejects overlaps (409, surfaced inline).
struct ProLastMinuteAddBlockSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let timeZone: TimeZone
    var onSaved: () -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var reason = ""
    @State private var saving = false
    @State private var error: String?

    init(timeZone: TimeZone, defaultStart: Date, onSaved: @escaping () -> Void) {
        self.timeZone = timeZone
        self.onSaved = onSaved
        _start = State(initialValue: defaultStart)
        _end = State(initialValue: defaultStart.addingTimeInterval(3600))
    }

    private var windowValid: Bool { end.timeIntervalSince(start) > 0 }
    private var canSave: Bool { !saving && windowValid }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Block a time range from ever being offered as a last-minute opening.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)

                    EditField(label: "Start") {
                        DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }

                    EditField(label: "End") {
                        DatePicker("", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }

                    if !windowValid {
                        Text("Block end must be after start.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.amber)
                    }

                    EditField(label: "Reason") {
                        TextField("Reason (optional)", text: $reason, axis: .vertical)
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.sentences)
                            .editFieldBox()
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Block time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add block") { Task { await save() } }
                        .disabled(!canSave)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
            .environment(\.timeZone, timeZone) // render pickers in the workspace zone
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }

        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await session.client.proSchedule.addLastMinuteBlock(
                startAt: ProCalendarGrid.iso(start),
                endAt: ProCalendarGrid.iso(end),
                reason: trimmed.isEmpty ? nil : trimmed
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t add the block. Try again."
        }
    }
}
