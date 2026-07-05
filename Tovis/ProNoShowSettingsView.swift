// Pro no-show / late-cancel fee settings — native port of the web `/pro`
// no-show settings (tovis-app #488, Phase 2 revenue protection). Dark unless
// ENABLE_NO_SHOW_PROTECTION is on: the endpoint 404s while the flag is off, so
// we show a "not available yet" state. Reached from the Profile tab → Business.
import SwiftUI
import TovisKit

struct ProNoShowSettingsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded, unavailable, failed(String) }
    @State private var phase: Phase = .loading

    @State private var enabled = false
    @State private var isPercent = false
    @State private var flatAmount = ""
    @State private var percent = ""
    @State private var cancelWindowHours = 24
    @State private var chargeNoShow = true
    @State private var chargeLateCancel = true
    @State private var saving = false
    @State private var savedTick = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case .unavailable:
                    unavailableState
                case let .failed(message):
                    Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                case .loaded:
                    intro
                    BrandSurface {
                        Toggle(isOn: $enabled) {
                            Text("Charge no-show & late-cancel fees")
                                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        }.tint(BrandColor.accent)
                    }
                    if enabled { feeForm }
                    saveButton
                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("No-show fees")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("◆ Protect your time")
                .font(BrandFont.mono(11)).tracking(0.6).foregroundStyle(BrandColor.accent)
            Text("Charge a fee when a client no-shows or cancels last minute. Requires a card on file.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        }
    }

    private var feeForm: some View {
        VStack(spacing: 12) {
            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("FEE").font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(BrandColor.textMuted)
                    Picker("Fee type", selection: $isPercent) {
                        Text("Flat $").tag(false)
                        Text("Percent").tag(true)
                    }.pickerStyle(.segmented)
                    if isPercent {
                        labeledField("Percent of total", text: $percent, suffix: "%", keyboard: .numberPad)
                    } else {
                        labeledField("Amount", text: $flatAmount, prefix: "$", keyboard: .decimalPad)
                    }
                }
            }
            BrandSurface {
                Stepper(value: $cancelWindowHours, in: 1...168) {
                    HStack {
                        Text("Late-cancel window").font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                        Spacer()
                        Text("\(cancelWindowHours)h").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textSecondary)
                    }
                }.tint(BrandColor.accent)
            }
            BrandSurface {
                VStack(spacing: 10) {
                    Toggle(isOn: $chargeNoShow) {
                        Text("Charge on no-show").font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                    }.tint(BrandColor.accent)
                    Toggle(isOn: $chargeLateCancel) {
                        Text("Charge on late cancel").font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                    }.tint(BrandColor.accent)
                }
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, prefix: String? = nil, suffix: String? = nil, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 8) {
            Text(label).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
            Spacer()
            if let prefix { Text(prefix).font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted) }
            TextField("0", text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                .frame(width: 90)
            if let suffix { Text(suffix).font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted) }
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 26)).foregroundStyle(BrandColor.textMuted)
            Text("Coming soon").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("No-show protection isn't switched on for your account yet.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
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
            let s = try await session.client.proSettings.noShowSettings()
            enabled = s.enabled
            isPercent = s.feeType.uppercased() == "PERCENT"
            flatAmount = s.feeFlatAmount ?? ""
            percent = s.feePercent.map(String.init) ?? ""
            cancelWindowHours = s.cancelWindowHours
            chargeNoShow = s.chargeNoShow
            chargeLateCancel = s.chargeLateCancel
            phase = .loaded
        } catch let e as APIError {
            if case .server(404, _, _) = e { phase = .unavailable } else { phase = .failed(e.userMessage) }
        } catch {
            phase = .failed("Couldn’t load your fee settings.")
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true; error = nil; savedTick = false
        defer { saving = false }
        let update = ProNoShowSettingsUpdate(
            enabled: enabled,
            feeType: isPercent ? "PERCENT" : "FLAT",
            feeFlatAmount: isPercent ? nil : (flatAmount.trimmingCharacters(in: .whitespaces).isEmpty ? nil : flatAmount),
            feePercent: isPercent ? Int(percent.trimmingCharacters(in: .whitespaces)) : nil,
            cancelWindowHours: cancelWindowHours,
            chargeNoShow: chargeNoShow,
            chargeLateCancel: chargeLateCancel
        )
        do {
            let s = try await session.client.proSettings.updateNoShowSettings(update)
            enabled = s.enabled
            savedTick = true
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save. Try again."
        }
    }
}
