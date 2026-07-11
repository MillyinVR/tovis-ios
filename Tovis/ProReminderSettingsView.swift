// Pro appointment-reminder settings — native port of the web `/pro` reminder
// cadence (tovis-app §11 RT3). A pro builds a fully custom list of reminders,
// each with an arbitrary lead time (any number of days OR hours before the
// appointment), plus the master on/off. Reached from the Profile tab → Business.
import SwiftUI
import TovisKit

struct ProReminderSettingsView: View {
    @Environment(SessionModel.self) private var session

    /// The lead unit as edited locally (the wire carries it as a raw string).
    private enum LeadUnit: String, CaseIterable {
        case days
        case hours

        var minutesPer: Int { self == .days ? 1440 : 60 }
        /// A generous per-unit ceiling for the stepper (server bound is 90 days).
        var stepperMax: Int { self == .days ? 90 : 2160 }
    }

    /// One editable reminder row.
    private struct EditableLead: Identifiable {
        let id = UUID()
        var value: Int
        var unit: LeadUnit

        var minutes: Int { value * unit.minutesPer }
        var summary: String {
            "\(value) \(value == 1 ? String(unit.rawValue.dropLast()) : unit.rawValue) before"
        }
    }

    private static let maxReminders = 10

    private enum Phase { case loading, loaded, failed(String) }
    @State private var phase: Phase = .loading
    @State private var enabled = true
    @State private var leads: [EditableLead] = []
    @State private var presets: [ReminderPreset] = []
    @State private var saving = false
    @State private var savedTick = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                case .loaded:
                    intro
                    masterToggle
                    if enabled {
                        BrandSection(title: "When to remind") {
                            VStack(spacing: 10) {
                                if leads.isEmpty {
                                    emptyRow
                                } else {
                                    ForEach($leads) { $lead in leadRow($lead) }
                                }
                                addControls
                            }
                        }
                    }
                    saveButton
                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("◆ Appointment reminders")
                .font(BrandFont.mono(11)).tracking(0.6).foregroundStyle(BrandColor.accent)
            Text("We text your clients ahead of their visit so they show up. Add as many reminders as you like — days or hours before.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        }
    }

    private var masterToggle: some View {
        BrandSurface {
            Toggle(isOn: $enabled) {
                Text("Send reminders").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            }
            .tint(BrandColor.accent)
        }
    }

    private var emptyRow: some View {
        Text("No reminders yet — clients won’t get a reminder until you add at least one.")
            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func leadRow(_ lead: Binding<EditableLead>) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(lead.wrappedValue.summary)
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    Button {
                        leads.removeAll { $0.id == lead.wrappedValue.id }
                        savedTick = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(BrandColor.textMuted)
                    }
                    .accessibilityLabel("Remove reminder")
                }
                HStack(spacing: 12) {
                    Stepper(
                        value: Binding(
                            get: { lead.wrappedValue.value },
                            set: { newValue in
                                lead.wrappedValue.value = max(1, min(newValue, lead.wrappedValue.unit.stepperMax))
                                savedTick = false
                            }
                        ),
                        in: 1...lead.wrappedValue.unit.stepperMax
                    ) {
                        Text("\(lead.wrappedValue.value)")
                            .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                    }
                    Picker(
                        "Unit",
                        selection: Binding(
                            get: { lead.wrappedValue.unit },
                            set: { newUnit in
                                lead.wrappedValue.unit = newUnit
                                lead.wrappedValue.value = min(lead.wrappedValue.value, newUnit.stepperMax)
                                savedTick = false
                            }
                        )
                    ) {
                        Text("days").tag(LeadUnit.days)
                        Text("hours").tag(LeadUnit.hours)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }
        }
    }

    private var presentMinutes: Set<Int> { Set(leads.map(\.minutes)) }

    private var addControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let atMax = leads.count >= Self.maxReminders
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(presets) { preset in
                    let unit = LeadUnit(rawValue: preset.unit) ?? .days
                    let already = presentMinutes.contains(preset.value * unit.minutesPer)
                    Button {
                        addLead(value: preset.value, unit: unit)
                    } label: {
                        Text(already ? "✓ \(preset.label)" : "+ \(preset.label)")
                            .font(BrandFont.body(12, .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(BrandColor.textPrimary)
                            .background(BrandColor.bgSecondary)
                            .clipShape(Capsule())
                    }
                    .disabled(already || atMax)
                    .opacity(already || atMax ? 0.4 : 1)
                }
                Button {
                    addLead(value: 1, unit: .days)
                } label: {
                    Text("+ Add reminder")
                        .font(BrandFont.body(12, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(BrandColor.onAccent)
                        .background(BrandColor.accent)
                        .clipShape(Capsule())
                }
                .disabled(atMax)
                .opacity(atMax ? 0.4 : 1)
            }
            if atMax {
                Text("You’ve reached the maximum of \(Self.maxReminders) reminders.")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private var saveButton: some View {
        Button { Task { await save() } } label: {
            Text(saving ? "Saving…" : (savedTick ? "Saved" : "Save"))
                .font(BrandFont.body(16, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .foregroundStyle(BrandColor.onAccent)
                .background(savedTick ? BrandColor.emerald : BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(saving)
        .padding(.top, 6)
    }

    private func addLead(value: Int, unit: LeadUnit) {
        guard leads.count < Self.maxReminders else { return }
        let minutes = value * unit.minutesPer
        guard !presentMinutes.contains(minutes) else { return }
        leads.append(EditableLead(value: value, unit: unit))
        savedTick = false
    }

    private func editableLeads(from settings: ProReminderSettings) -> [EditableLead] {
        settings.leads.map { lead in
            EditableLead(value: lead.value, unit: LeadUnit(rawValue: lead.unit) ?? .days)
        }
    }

    private func load() async {
        do {
            let res = try await session.client.proSettings.reminderSettings()
            enabled = res.settings.enabled
            presets = res.presets
            leads = editableLeads(from: res.settings)
            phase = .loaded
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your reminder settings.")
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true; error = nil; savedTick = false
        defer { saving = false }
        do {
            let reminders = leads.map { ReminderLeadInput(value: $0.value, unit: $0.unit.rawValue) }
            let res = try await session.client.proSettings.updateReminderSettings(
                enabled: enabled, reminders: reminders
            )
            enabled = res.settings.enabled
            leads = editableLeads(from: res.settings)
            savedTick = true
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save. Try again."
        }
    }
}
