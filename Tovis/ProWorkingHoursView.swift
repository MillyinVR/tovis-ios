// Pro working hours — the native port of the web `/pro/calendar` working-hours
// form. Per-day open/closed toggle + start/end time pickers; Save persists the
// week (POST /pro/working-hours). Reached from the Profile tab → Business.
import SwiftUI
import TovisKit

struct ProWorkingHoursView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded, failed(String) }
    @State private var phase: Phase = .loading
    @State private var week = ProWeekHours(
        sun: .init(enabled: false, start: "09:00", end: "17:00"),
        mon: .init(enabled: true, start: "09:00", end: "17:00"),
        tue: .init(enabled: true, start: "09:00", end: "17:00"),
        wed: .init(enabled: true, start: "09:00", end: "17:00"),
        thu: .init(enabled: true, start: "09:00", end: "17:00"),
        fri: .init(enabled: true, start: "09:00", end: "17:00"),
        sat: .init(enabled: false, start: "09:00", end: "17:00")
    )
    @State private var saving = false
    @State private var savedTick = false
    @State private var error: String?

    /// Mon-first display order, paired with the binding keypath into the week.
    private let days: [(label: String, key: WritableKeyPath<ProWeekHours, ProDayHours>)] = [
        ("Monday", \.mon), ("Tuesday", \.tue), ("Wednesday", \.wed),
        ("Thursday", \.thu), ("Friday", \.fri), ("Saturday", \.sat), ("Sunday", \.sun),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                case .loaded:
                    headerHint
                    ForEach(days, id: \.label) { day in
                        dayRow(label: day.label, hours: Binding(
                            get: { week[keyPath: day.key] },
                            set: { week[keyPath: day.key] = $0 }
                        ))
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
        .navigationTitle("Working hours")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    private var daysOn: Int {
        days.filter { week[keyPath: $0.key].enabled }.count
    }

    // Web parity: eyebrow + "Base schedule" + location-specific blurb + days-on count.
    private var headerHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("◆ Salon hours")
                .font(BrandFont.mono(11)).tracking(0.6)
                .foregroundStyle(BrandColor.accent)
            HStack(alignment: .firstTextBaseline) {
                Text("Base schedule")
                    .font(BrandFont.display(22, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Text("\(daysOn) Days on")
                    .font(BrandFont.mono(10)).tracking(0.5)
                    .foregroundStyle(BrandColor.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(BrandColor.bgSecondary)
                    .clipShape(Capsule())
            }
            Text("Fixed location availability. Applies to your salon, suite, or studio.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.bottom, 6)
    }

    /// "HH:MM" (24h) → "9:00 AM".
    private func fmt12(_ hhmm: String) -> String {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        let h = p.first ?? 0, m = p.count > 1 ? p[1] : 0
        let period = h < 12 ? "AM" : "PM"
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, period)
    }

    private func dayRow(label: String, hours: Binding<ProDayHours>) -> some View {
        BrandSurface {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(hours.enabled.wrappedValue
                             ? "\(fmt12(hours.start.wrappedValue)) → \(fmt12(hours.end.wrappedValue))"
                             : "Off")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                    Toggle("", isOn: hours.enabled)
                        .labelsHidden()
                        .tint(BrandColor.accent)
                }

                if hours.enabled.wrappedValue {
                    HStack(spacing: 12) {
                        timeField("Open", value: hours.start)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11)).foregroundStyle(BrandColor.textMuted)
                        timeField("Close", value: hours.end)
                        Spacer()
                    }
                }
            }
        }
    }

    private func timeField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(BrandFont.mono(9)).tracking(0.6)
                .foregroundStyle(BrandColor.textMuted)
            DatePicker(
                "",
                selection: Binding(
                    get: { Self.date(from: value.wrappedValue) },
                    set: { value.wrappedValue = Self.hhmm(from: $0) }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .tint(BrandColor.accent)
        }
    }

    private var saveButton: some View {
        Button { Task { await save() } } label: {
            Group {
                if saving { Text("Saving…").font(BrandFont.body(16, .semibold)) }
                else { Text(savedTick ? "Saved" : "Save schedule").font(BrandFont.body(16, .semibold)) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(BrandColor.onAccent)
            .background(savedTick ? BrandColor.emerald : BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(saving)
        .padding(.top, 6)
    }

    // MARK: - Time helpers ("HH:MM" ⇄ Date)

    private static func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var comps = DateComponents()
        comps.hour = parts.first ?? 9
        comps.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - Load / save

    private func load() async {
        do {
            let res = try await session.client.proSchedule.workingHours(locationType: "SALON")
            week = res.workingHours
            phase = .loaded
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your working hours.")
        }
    }

    /// Minutes-since-midnight for "HH:MM".
    private func minutes(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }

    private func save() async {
        guard !saving else { return }
        // Web parity: each enabled day must have end after start.
        for day in days {
            let h = week[keyPath: day.key]
            if h.enabled, minutes(h.end) <= minutes(h.start) {
                error = "\(day.label): End time must be after start time."
                savedTick = false
                return
            }
        }
        saving = true
        error = nil
        savedTick = false
        defer { saving = false }
        do {
            let res = try await session.client.proSchedule.updateWorkingHours(week, locationType: "SALON")
            week = res.workingHours
            savedTick = true
            session.signalRefresh()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save your hours. Try again."
        }
    }
}
