// Pro "Referral rewards" — the native port of the whole web `/pro/referral-rewards`
// page: the reward CONFIG editor (`ReferralRewardsClient`) on top of the read-only
// activity feed (`ProReferralActivitySection`). Config is backed by
// GET/PATCH /api/v1/pro/settings/referral-rewards; activity by GET /api/v1/pro/referrals
// — both routes already exist, so this is an iOS-only port. Reached from the
// Profile tab → Growth. Every activity row is at least CONVERTED (scope =
// Referral.professionalId).
import SwiftUI
import TovisKit

struct ProReferralActivityView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded(ProReferralActivity), failed(String) }
    @State private var phase: Phase = .loading

    // The reward config loads independently of the activity feed so one failing
    // doesn't blank the other.
    private enum SettingsPhase { case loading, loaded(ProReferralRewardSettings), failed }
    @State private var settingsPhase: SettingsPhase = .loading
    @State private var showSettingsEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rewardSettingsSection

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 40)
                case let .failed(message):
                    errorState(message)
                case let .loaded(activity):
                    summary(activity.summary)
                    if activity.rows.isEmpty {
                        emptyState
                    } else {
                        BrandSection(title: "Activity") { rows(activity.rows) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Referrals")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task {
            if case .loading = phase { await loadActivity() }
            if case .loading = settingsPhase { await loadSettings() }
        }
        .sheet(isPresented: $showSettingsEditor) {
            if case let .loaded(settings) = settingsPhase {
                ProReferralRewardSettingsSheet(initial: settings) { updated in
                    settingsPhase = .loaded(updated)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Reward settings

    @ViewBuilder
    private var rewardSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reward settings")
                    .font(BrandFont.mono(11)).tracking(0.8)
                    .foregroundStyle(BrandColor.textMuted)
                Spacer()
                if case .loaded = settingsPhase {
                    Button("Edit") { showSettingsEditor = true }
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }

            switch settingsPhase {
            case .loading:
                BrandSurface {
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.vertical, 6)
                }
            case .failed:
                BrandSurface {
                    HStack {
                        Text("Couldn't load your reward settings.")
                            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                        Spacer()
                        Button("Retry") { Task { settingsPhase = .loading; await loadSettings() } }
                            .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.accent)
                    }
                }
            case let .loaded(settings):
                settingsCard(settings)
            }
        }
    }

    private func settingsCard(_ settings: ProReferralRewardSettings) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Referral rewards")
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    statusChip(settings.enabled)
                }
                Text(Self.rewardSummary(settings))
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusChip(_ on: Bool) -> some View {
        Text(on ? "On" : "Off")
            .font(BrandFont.mono(9)).tracking(0.5)
            .foregroundStyle(on ? BrandColor.emerald : BrandColor.textMuted)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background((on ? BrandColor.emerald : BrandColor.textMuted).opacity(0.12))
            .clipShape(Capsule())
    }

    /// One-line description of the current reward, mirroring the web tier copy.
    private static func rewardSummary(_ s: ProReferralRewardSettings) -> String {
        guard s.enabled else {
            return "Turn on to reward clients who send new bookings your way."
        }
        switch s.tier {
        case "DISCOUNT":
            return "Referrers get \(s.discountPercent ?? 10)% off their next booking with you."
        case "CREDIT":
            let credit = ProReferralRewardSettingsSheet.moneyLabel(s.creditAmount ?? 10)
            return "Referrers get \(credit) credit on their next booking with you."
        default:
            return "Referrers get a thank-you notification — no cost to you."
        }
    }

    // MARK: - Activity sections

    private func summary(_ s: ProReferralActivity.Summary) -> some View {
        let tiles: [(String, String)] = [
            ("\(s.total)", "Referred"),
            ("\(s.rewarded)", "Rewarded"),
            (Wire.money(String(s.creditDollarsApplied)) ?? "$0", "Credits given"),
        ]
        return HStack(spacing: 10) {
            ForEach(tiles, id: \.1) { tile in
                BrandSurface {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tile.0).font(BrandFont.display(22, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text(tile.1).font(BrandFont.mono(9)).tracking(0.5).foregroundStyle(BrandColor.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func rows(_ rows: [ProReferralActivity.Row]) -> some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                BrandSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(row.referrerName) referred \(row.referredName)")
                                .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            statusBadge(row.status)
                        }
                        HStack(spacing: 10) {
                            if let reward = Self.rewardLabel(row) {
                                Text(reward).font(BrandFont.mono(10)).tracking(0.3).foregroundStyle(BrandColor.accent)
                            }
                            if let code = row.cardShortCode {
                                Text("Card \(code)").font(BrandFont.mono(10)).tracking(0.3).foregroundStyle(BrandColor.textMuted)
                            }
                            Spacer()
                            Text(Wire.dateOnly(row.convertedAt ?? row.createdAt))
                                .font(BrandFont.mono(10)).tracking(0.3).foregroundStyle(BrandColor.textMuted)
                        }
                    }
                }
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let rewarded = status == "REWARDED"
        return Text(rewarded ? "Rewarded" : "Converted")
            .font(BrandFont.mono(9)).tracking(0.5)
            .foregroundStyle(rewarded ? BrandColor.emerald : BrandColor.accent)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background((rewarded ? BrandColor.emerald : BrandColor.accent).opacity(0.12))
            .clipShape(Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gift").font(.system(size: 26)).foregroundStyle(BrandColor.textMuted)
            Text("No referrals yet").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("When a client you've referred books with you, it'll show up here.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 20)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { phase = .loading; await loadActivity() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    // MARK: - Helpers

    private static func rewardLabel(_ row: ProReferralActivity.Row) -> String? {
        guard let tier = row.rewardTier, let value = row.rewardValue else { return nil }
        switch tier {
        case "CREDIT": return (Wire.money(String(value)) ?? "$\(Int(value))") + " credit"
        case "DISCOUNT": return "\(Int(value))% off"
        default: return nil
        }
    }

    private func loadActivity() async {
        do {
            let activity = try await session.client.proReferrals.activity()
            phase = .loaded(activity)
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your referral activity.")
        }
    }

    private func loadSettings() async {
        do {
            let settings = try await session.client.proReferrals.rewardSettings()
            settingsPhase = .loaded(settings)
        } catch {
            settingsPhase = .failed
        }
    }
}

// MARK: - Reward settings editor

/// Edit the pro's referral-reward config (web `ReferralRewardsClient`): the master
/// toggle, the reward tier, and the tier-specific discount % / credit $ value. One
/// Save PATCHes the config (unlike the web page's per-field auto-save; the native
/// idiom is a sheet that applies on Save). Only the fields relevant to the chosen
/// tier are sent, so switching tiers back and forth never wipes the other value.
struct ProReferralRewardSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session

    let initial: ProReferralRewardSettings
    /// Called with the server's canonical settings after a successful save.
    var onSaved: (ProReferralRewardSettings) -> Void

    @State private var enabled: Bool
    @State private var tier: String
    @State private var discountPercent: Int
    @State private var creditText: String
    @State private var saving = false
    @State private var error: String?

    init(initial: ProReferralRewardSettings, onSaved: @escaping (ProReferralRewardSettings) -> Void) {
        self.initial = initial
        self.onSaved = onSaved
        _enabled = State(initialValue: initial.enabled)
        _tier = State(initialValue: initial.tier)
        _discountPercent = State(initialValue: initial.discountPercent ?? 10)
        _creditText = State(initialValue: Self.moneyEditString(initial.creditAmount ?? 10))
    }

    private static let tiers: [(key: String, label: String, description: String)] = [
        ("RECOGNITION", "Recognition only", "Referrer gets a thank-you notification — no cost to you."),
        ("DISCOUNT", "Percentage discount", "Referrer gets X% off their next booking with you."),
        ("CREDIT", "Dollar credit", "Referrer gets $X off their next booking with you."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Reward clients who refer new bookings to you.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    enableRow

                    if enabled {
                        tierPicker
                        if tier == "DISCOUNT" { discountField }
                        if tier == "CREDIT" { creditField }
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Referral rewards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().tint(BrandColor.accent)
                        } else {
                            Text("Save").font(BrandFont.body(15, .semibold))
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private var enableRow: some View {
        BrandSurface {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable referral rewards")
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Text("Clients who refer others earn a reward when the referred client books with you.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private var tierPicker: some View {
        EditField(label: "Reward tier") {
            VStack(spacing: 8) {
                ForEach(Self.tiers, id: \.key) { option in
                    Button { tier = option.key } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: tier == option.key ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(tier == option.key ? BrandColor.accent : BrandColor.textMuted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label)
                                    .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                Text(option.description)
                                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(tier == option.key ? BrandColor.accent.opacity(0.08) : BrandColor.bgSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(tier == option.key ? BrandColor.accent.opacity(0.5) : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var discountField: some View {
        EditField(label: "Discount percentage") {
            VStack(alignment: .leading, spacing: 6) {
                Stepper(value: $discountPercent, in: 1...100) {
                    Text("\(discountPercent)%")
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                }
                .tint(BrandColor.accent)
                Text("Applied to the referrer’s next booking with you (1–100%).")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            }
            .editFieldBox()
        }
    }

    private var creditField: some View {
        EditField(label: "Credit amount") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("$").foregroundStyle(BrandColor.textMuted)
                    TextField("10", text: $creditText)
                        .keyboardType(.decimalPad)
                        .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                }
                Text("Applied to the referrer’s next booking with you.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            }
            .editFieldBox()
        }
    }

    private func save() async {
        guard !saving else { return }

        // Always send the master switch + tier; add the tier-specific value only for
        // the active tier so the other's stored value is left untouched (partial
        // PATCH), matching the web editor.
        var patch = ProReferralRewardSettingsPatch(enabled: enabled, tier: tier)
        switch tier {
        case "DISCOUNT":
            patch.referralDiscountPercent = max(1, min(100, discountPercent))
        case "CREDIT":
            guard let amount = Self.parseCredit(creditText), amount > 0 else {
                error = "Enter a credit amount above $0."
                return
            }
            patch.referralCreditAmount = amount
        default:
            break
        }

        saving = true
        error = nil
        defer { saving = false }
        do {
            let updated = try await session.client.proReferrals.updateRewardSettings(patch)
            onSaved(updated)
            dismiss()
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t save your reward settings. Please try again."
        }
    }

    // MARK: - Money formatting

    /// Parse a user-typed dollar amount, tolerating a stray `$` or spaces, rounded to
    /// cents (the column is `Decimal(10,2)`).
    static func parseCredit(_ text: String) -> Double? {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned) else { return nil }
        return (value * 100).rounded() / 100
    }

    /// A clean editor seed: whole dollars show without a trailing ".0".
    static func moneyEditString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Display currency (reuses the shared decimal-string formatter).
    static func moneyLabel(_ value: Double) -> String {
        Wire.money(moneyEditString(value)) ?? "$\(Int(value))"
    }
}
