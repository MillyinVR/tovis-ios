// Notification preferences — the native editor matching the web client's
// Settings → Notifications surface (app/_components/NotificationPreferencesForm,
// pointed at /api/v1/client/notification-preferences). Same model:
//   - a "preferred channel" quick-pick (Email / Text / Push-coming-soon),
//   - quiet hours (toggle + From/To, start≠end enforced),
//   - per-category, per-notification channel toggles (In-app / SMS / Email),
//     with email-locked critical events shown "always on".
// Reads GET + writes the full declarative state back via PATCH. Pushed from the
// gear in NotificationsView.
import SwiftUI
import TovisKit

struct NotificationPreferencesView: View {
    @Environment(SessionModel.self) private var session

    /// Local, mutable per-event channel state (the wire structs are immutable).
    private struct ChannelDraft: Equatable {
        var inApp: Bool
        var sms: Bool
        var email: Bool
    }

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var categories: [NotificationCategory] = []
    @State private var events: [String: ChannelDraft] = [:]
    @State private var quietEnabled = false
    @State private var quietStart = 22 * 60
    @State private var quietEnd = 8 * 60
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
        .navigationTitle("Notification settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preferredChannel
                smsConsentNote
                quietHours
                ForEach(categories) { category in
                    categorySection(category)
                }
                if let banner { bannerView(banner) }
                saveButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private var preferredChannel: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("How would you like to hear from us?")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Pick one and we'll send notifications there instead of every channel. You'll always see them in-app, and you can fine-tune individual notifications below.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)

                let active = derivedActivePreference()
                HStack(spacing: 8) {
                    preferenceChip(id: "EMAIL", label: "Email", hint: "Your inbox", active: active == "EMAIL", disabled: false)
                    preferenceChip(id: "SMS", label: "Text", hint: "By SMS", active: active == "SMS", disabled: false)
                    preferenceChip(id: "PUSH", label: "Push", hint: "Coming soon", active: false, disabled: true)
                }

                if active == nil {
                    Text("Your notifications are customized below.")
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    private func preferenceChip(id: String, label: String, hint: String, active: Bool, disabled: Bool) -> some View {
        Button {
            guard !disabled else { return }
            applyPreferredChannel(id)
            banner = nil
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(BrandFont.body(13, .semibold))
                Text(hint).font(BrandFont.body(10.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9).padding(.horizontal, 11)
            .background(active ? BrandColor.accent : BrandColor.bgSecondary)
            .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(active ? 0 : 0.18), lineWidth: 1)
            )
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var smsConsentNote: some View {
        Text("SMS is only sent when you have a verified phone number and have consented to texts. Turning SMS on here won't send texts until both are in place.")
            .font(BrandFont.body(11.5))
            .foregroundStyle(BrandColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BrandColor.iris.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var quietHours: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Quiet hours")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Pause SMS and email during these hours. In-app notifications are never paused.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { quietEnabled },
                        set: { quietEnabled = $0; banner = nil }
                    ))
                    .labelsHidden()
                    .tint(BrandColor.accent)
                }

                if quietEnabled {
                    HStack(spacing: 20) {
                        timeField("From", minutes: $quietStart)
                        timeField("To", minutes: $quietEnd)
                    }
                    if quietInvalid {
                        Text("Start and end times can't be the same.")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.ember)
                    }
                }
            }
        }
    }

    private func timeField(_ label: String, minutes: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(BrandFont.mono(10)).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(BrandColor.textSecondary)
            DatePicker("", selection: Binding(
                get: { Self.dateFor(minutes: minutes.wrappedValue) },
                set: { minutes.wrappedValue = Self.minutesOf($0); banner = nil }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .tint(BrandColor.accent)
        }
    }

    private func categorySection(_ category: NotificationCategory) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.label)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(category.description)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                    .padding(.bottom, 6)

                ForEach(Array(category.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 {
                        Divider().overlay(BrandColor.textMuted.opacity(0.12))
                    }
                    eventRow(event)
                        .padding(.vertical, 9)
                }
            }
        }
    }

    private func eventRow(_ event: NotificationCategoryEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            HStack(spacing: 16) {
                ForEach(event.supportedChannels, id: \.self) { channel in
                    channelToggle(eventKey: event.eventKey, channel: channel, emailLocked: event.emailLocked)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func channelToggle(eventKey: String, channel: String, emailLocked: Bool) -> some View {
        let locked = channel == "EMAIL" && emailLocked
        let draft = events[eventKey] ?? ChannelDraft(inApp: true, sms: true, email: true)
        let isOn: Bool = {
            switch channel {
            case "IN_APP": return draft.inApp
            case "SMS": return draft.sms
            case "EMAIL": return locked ? true : draft.email
            default: return false
            }
        }()
        return HStack(spacing: 6) {
            Text(channelLabel(channel) + (locked ? " · on" : ""))
                .font(BrandFont.mono(10)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(BrandColor.textSecondary)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { setChannel(eventKey: eventKey, channel: channel, value: $0) }
            ))
            .labelsHidden()
            .tint(BrandColor.accent)
            .disabled(locked)
            .scaleEffect(0.8)
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        Text(banner.text)
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(banner.kind == .success ? BrandColor.emerald : BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background((banner.kind == .success ? BrandColor.emerald : BrandColor.ember).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var saveButton: some View {
        Button(action: { Task { await save() } }) {
            Group {
                if saving { ProgressView().tint(BrandColor.onAccent) }
                else { Text("Save preferences").font(BrandFont.body(15, .semibold)) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(BrandColor.accent)
            .foregroundStyle(BrandColor.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(saving || quietInvalid)
        .opacity(quietInvalid ? 0.6 : 1)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.accent)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - State helpers

    private var quietInvalid: Bool { quietEnabled && quietStart == quietEnd }

    private func channelLabel(_ channel: String) -> String {
        switch channel {
        case "IN_APP": return "In-app"
        case "SMS": return "SMS"
        case "EMAIL": return "Email"
        default: return channel
        }
    }

    private func setChannel(eventKey: String, channel: String, value: Bool) {
        var draft = events[eventKey] ?? ChannelDraft(inApp: true, sms: true, email: true)
        switch channel {
        case "IN_APP": draft.inApp = value
        case "SMS": draft.sms = value
        case "EMAIL": draft.email = value
        default: break
        }
        events[eventKey] = draft
        banner = nil
    }

    /// Map every event's `supportedChannels`, keyed by event key.
    private func supportedChannels() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for category in categories {
            for event in category.events { map[event.eventKey] = event.supportedChannels }
        }
        return map
    }

    private func lockedEmailEvents() -> Set<String> {
        var set: Set<String> = []
        for category in categories {
            for event in category.events where event.emailLocked { set.insert(event.eventKey) }
        }
        return set
    }

    /// Which single external channel the toggles correspond to (or nil = custom).
    /// Mirrors the web's `deriveActivePreference` (only dual email+SMS events count).
    private func derivedActivePreference() -> String? {
        let supported = supportedChannels()
        let locked = lockedEmailEvents()
        var sawDual = false
        var allEmail = true
        var allSms = true
        for (eventKey, channels) in supported {
            if locked.contains(eventKey) { continue }
            guard channels.contains("EMAIL"), channels.contains("SMS") else { continue }
            sawDual = true
            guard let state = events[eventKey] else { continue }
            if !(state.email && !state.sms) { allEmail = false }
            if !(state.sms && !state.email) { allSms = false }
        }
        if !sawDual { return nil }
        if allEmail { return "EMAIL" }
        if allSms { return "SMS" }
        return nil
    }

    /// Apply a preferred channel onto every event's toggles. Mirrors the web's
    /// `applyPreferredChannel`: in-app is never touched, the chosen channel is
    /// enabled where supported, the other external channel is disabled only when
    /// the chosen one is also available, and email-locked events keep email on.
    private func applyPreferredChannel(_ channel: String) {
        let supported = supportedChannels()
        let locked = lockedEmailEvents()
        for (eventKey, channels) in supported {
            var draft = events[eventKey] ?? ChannelDraft(inApp: true, sms: true, email: true)
            let supportsEmail = channels.contains("EMAIL")
            let supportsSms = channels.contains("SMS")
            let supportsBoth = supportsEmail && supportsSms
            if channel == "EMAIL" {
                if supportsEmail { draft.email = true }
                if supportsBoth { draft.sms = false }
            } else {
                if supportsSms { draft.sms = true }
                if locked.contains(eventKey) { draft.email = true }
                else if supportsBoth { draft.email = false }
            }
            events[eventKey] = draft
        }
    }

    // MARK: - Time conversion

    private static func dateFor(minutes: Int) -> Date {
        let safe = min(1439, max(0, minutes))
        var comps = DateComponents()
        comps.hour = safe / 60
        comps.minute = safe % 60
        return Calendar.current.date(from: comps) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func minutesOf(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    // MARK: - Data

    private func load() async {
        do {
            let prefs = try await session.client.notifications.preferences()
            apply(prefs)
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't load your notification settings.")
        }
    }

    private func apply(_ prefs: NotificationPreferences) {
        categories = prefs.categories
        var drafts: [String: ChannelDraft] = [:]
        for (key, channel) in prefs.events {
            drafts[key] = ChannelDraft(
                inApp: channel.inAppEnabled,
                sms: channel.smsEnabled,
                email: channel.emailEnabled
            )
        }
        events = drafts
        quietEnabled = prefs.quietHours.enabled
        quietStart = prefs.quietHours.startMinutes
        quietEnd = prefs.quietHours.endMinutes
    }

    private func save() async {
        guard !saving else { return }
        if quietInvalid {
            banner = Banner(kind: .error, text: "Quiet hours start and end can't be the same.")
            return
        }
        saving = true
        defer { saving = false }

        let payload = events.reduce(into: [String: NotificationChannelPreference]()) { acc, pair in
            acc[pair.key] = NotificationChannelPreference(
                inAppEnabled: pair.value.inApp,
                smsEnabled: pair.value.sms,
                emailEnabled: pair.value.email
            )
        }
        let quiet = NotificationQuietHours(
            enabled: quietEnabled,
            startMinutes: quietStart,
            endMinutes: quietEnd
        )
        do {
            let updated = try await session.client.notifications.updatePreferences(
                events: payload, quietHours: quiet
            )
            apply(updated)
            banner = Banner(kind: .success, text: "Notification preferences saved.")
            session.signalRefresh()
        } catch {
            banner = Banner(kind: .error, text: "Couldn't save your changes. Please try again.")
        }
    }
}
