// Pro appointment-reminder settings — native port of the web `/pro` reminder
// cadence (tovis-app #490). Master toggle + which day-before reminders fire.
// Reached from the Profile tab → Business.
import SwiftUI
import TovisKit

struct ProReminderSettingsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded, failed(String) }
    @State private var phase: Phase = .loading
    @State private var enabled = true
    @State private var options: [ReminderOffsetOption] = []
    @State private var selectedDays: Set<Int> = []
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
                                ForEach(options) { option in offsetRow(option) }
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
            Text("We text your clients ahead of their visit so they show up.")
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

    private func offsetRow(_ option: ReminderOffsetOption) -> some View {
        BrandSurface {
            Toggle(isOn: Binding(
                get: { selectedDays.contains(option.days) },
                set: { on in
                    if on { selectedDays.insert(option.days) } else { selectedDays.remove(option.days) }
                }
            )) {
                Text(option.label).font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
            }
            .tint(BrandColor.accent)
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

    private func load() async {
        do {
            let res = try await session.client.proSettings.reminderSettings()
            enabled = res.settings.enabled
            options = res.options
            selectedDays = Set(res.settings.offsetDays)
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
            let days = options.map(\.days).filter { selectedDays.contains($0) }
            let res = try await session.client.proSettings.updateReminderSettings(enabled: enabled, offsetDays: days)
            enabled = res.settings.enabled
            selectedDays = Set(res.settings.offsetDays)
            savedTick = true
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save. Try again."
        }
    }
}
