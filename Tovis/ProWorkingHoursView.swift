// Pro working hours — the native port of the web `/pro/calendar` working-hours
// form. Per-day open/closed toggle + start/end time pickers; Save persists the
// week (POST /pro/working-hours). Reached from the Profile tab → Business.
//
// The week is scoped to a specific bookable LOCATION, not a hardcoded type: we
// list the pro's locations, keep the bookable ones, and edit the primary one by
// default (a picker switches between them when there's more than one). This
// mirrors the web, whose editor resolves the pro's primary bookable location.
// Hardcoding `locationType=SALON` (the old behavior) 409'd for mobile-only pros
// — their salon is archived, so no bookable salon exists — and silently loaded
// default hours instead of theirs.
import SwiftUI
import TovisKit

struct ProWorkingHoursView: View {
    @Environment(SessionModel.self) private var session

    /// The bookable location whose week we're editing (id + POST mode + label).
    private struct HoursTarget: Equatable {
        let locationId: String
        /// The working-hours API's `locationType` param — "SALON" | "MOBILE".
        let mode: String
        let name: String
        let isMobile: Bool
    }

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

    /// This pro's bookable locations (from GET /pro/locations, minus archived).
    @State private var bookableLocations: [ProLocationSummary] = []
    /// The location currently being edited; nil until resolved on load.
    @State private var target: HoursTarget?

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
                    if bookableLocations.count > 1, let target {
                        locationPicker(current: target)
                    }
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

    // Web parity: eyebrow + "Base schedule" + location-specific blurb + days-on
    // count. The eyebrow + blurb follow the resolved location's type.
    private var headerHint: some View {
        let isMobile = target?.isMobile ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Text(isMobile ? "◆ Mobile hours" : "◆ Salon hours")
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
            Text(isMobile
                 ? "Travel availability. Applies to your mobile base."
                 : "Fixed location availability. Applies to your salon, suite, or studio.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.bottom, 6)
    }

    /// A location switcher, shown only when the pro has more than one bookable
    /// location — pick which one's week you're editing.
    private func locationPicker(current: HoursTarget) -> some View {
        Menu {
            ForEach(bookableLocations) { loc in
                Button {
                    Task { await load(preferredLocationId: loc.id) }
                } label: {
                    if loc.id == current.locationId {
                        Label(displayName(loc), systemImage: "checkmark")
                    } else {
                        Text(displayName(loc))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current.isMobile ? "car.fill" : "building.2.fill")
                    .font(.system(size: 12)).foregroundStyle(BrandColor.accent)
                Text(current.name)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11)).foregroundStyle(BrandColor.textMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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

    // MARK: - Location resolution

    /// A human label for a location — its name, else a type fallback.
    private func displayName(_ loc: ProLocationSummary) -> String {
        let trimmed = loc.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return loc.isMobileBase ? "Mobile base" : "Salon"
    }

    /// Pick the location to edit (pure logic + tests live in TovisKit
    /// `ProWorkingHours`), then wrap it as a `HoursTarget` for the view.
    private func resolveTarget(
        from bookable: [ProLocationSummary],
        preferredLocationId: String?
    ) -> HoursTarget? {
        guard let loc = ProWorkingHours.locationToEdit(
            from: bookable, preferredLocationId: preferredLocationId
        ) else { return nil }
        return HoursTarget(
            locationId: loc.id,
            mode: ProWorkingHours.mode(for: loc),
            name: displayName(loc),
            isMobile: loc.isMobileBase
        )
    }

    // MARK: - Load / save

    private func load(preferredLocationId: String? = nil) async {
        phase = .loading
        error = nil
        savedTick = false
        do {
            let bookable = try await session.client.proLocations.list()
                .filter(\.isBookable)
            bookableLocations = bookable

            guard let resolved = resolveTarget(
                from: bookable, preferredLocationId: preferredLocationId
            ) else {
                // No bookable location → the working-hours endpoint would 409 on
                // save. Tell the pro what to do instead of loading fake defaults.
                target = nil
                phase = .failed(
                    "You don’t have a bookable location yet. Add and publish a location, then set your working hours.")
                return
            }
            target = resolved

            let res = try await session.client.proSchedule.workingHours(
                locationType: resolved.mode, locationId: resolved.locationId)
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
        guard !saving, let target else { return }
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
            let res = try await session.client.proSchedule.updateWorkingHours(
                week, locationType: target.mode, locationId: target.locationId)
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
