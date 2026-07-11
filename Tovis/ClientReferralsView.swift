// The client's "Your Referrals" list — a native port of web
// `app/client/(gated)/referrals/ReferralListClient.tsx`. Reached from the Me tab,
// just below the invite card (the invite/share half of the web page already
// lives there as `inviteCard`, so this screen is the list half: the friends
// you've referred + their reward + a Confirm/Decline on anything still pending).
//
// Backed by GET /api/v1/client/referrals (list) and POST
// /client/referrals/{id}/{confirm,decline} — all live JSON routes, so this is an
// iOS-only parity build (no paired web PR). Status + reward tier are raw strings
// (server-driven-labels convention), formatted here to match the web copy.
import SwiftUI
import TovisKit

struct ClientReferralsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded([ClientReferral]), failed(String) }
    @State private var phase: Phase = .loading
    /// The referral currently being confirmed/declined (disables its buttons).
    @State private var busyId: String?
    /// A transient action error, shown as a banner without blowing away the list.
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let actionError {
                    banner(actionError)
                }

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(referrals):
                    if referrals.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 12) {
                            ForEach(Self.pendingFirst(referrals)) { referral in
                                row(referral)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Your Referrals")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    // MARK: - Row

    private func row(_ r: ClientReferral) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(r.referredFirstName)
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            statusBadge(r.status)
                        }

                        Text(subtitle(r))
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let reward = Self.rewardDescription(r) {
                            Text(reward)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if r.isPending {
                    HStack(spacing: 10) {
                        Spacer()
                        Button {
                            Task { await act(r, .decline) }
                        } label: {
                            Text("Decline")
                                .font(BrandFont.body(14, .semibold))
                                .foregroundStyle(BrandColor.textSecondary)
                                .padding(.vertical, 8).padding(.horizontal, 16)
                                .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(busyId == r.id)

                        Button {
                            Task { await act(r, .confirm) }
                        } label: {
                            Group {
                                if busyId == r.id {
                                    ProgressView().tint(BrandColor.onAccent)
                                } else {
                                    Text("Confirm").font(BrandFont.body(14, .semibold))
                                }
                            }
                            .foregroundStyle(BrandColor.onAccent)
                            .padding(.vertical, 8).padding(.horizontal, 20)
                            .background(BrandColor.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(busyId == r.id)
                    }
                }
            }
        }
    }

    /// "Tapped Jul 1, 2026" + optionally " · Booked with {pro}" (mirrors the web row).
    private func subtitle(_ r: ClientReferral) -> String {
        var text = "Tapped \(Wire.dateOnly(r.createdAt))"
        if let pro = r.proName { text += " · Booked with \(pro)" }
        return text
    }

    private func statusBadge(_ status: String) -> some View {
        Text(Self.statusLabel(status))
            .font(BrandFont.mono(9)).tracking(0.5)
            .foregroundStyle(Self.statusColor(status))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Self.statusColor(status).opacity(0.14))
            .clipShape(Capsule())
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gift").font(.system(size: 26)).foregroundStyle(BrandColor.textMuted)
            Text("No referrals yet").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("Share your referral card to get started — when a friend signs up and books, it'll show up here.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { phase = .loading; await load() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func banner(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BrandColor.ember.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    private enum Action { case confirm, decline }

    private func load() async {
        do {
            let referrals = try await session.client.referrals.list()
            phase = .loaded(referrals)
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your referrals.")
        }
    }

    private func act(_ r: ClientReferral, _ action: Action) async {
        guard busyId == nil else { return }
        busyId = r.id
        actionError = nil
        do {
            switch action {
            case .confirm: try await session.client.referrals.confirm(id: r.id)
            case .decline: try await session.client.referrals.decline(id: r.id)
            }
            await load() // reflect the server's authoritative status
        } catch let e as APIError {
            actionError = e.userMessage
        } catch {
            actionError = action == .confirm ? "Couldn’t confirm that referral." : "Couldn’t decline that referral."
        }
        busyId = nil
    }

    // MARK: - Web-parity formatting (mirrors ReferralListClient.tsx)

    /// Pending referrals float to the top (stable otherwise) — matches the web sort.
    static func pendingFirst(_ referrals: [ClientReferral]) -> [ClientReferral] {
        referrals.enumerated()
            .sorted { a, b in
                if a.element.isPending != b.element.isPending { return a.element.isPending }
                return a.offset < b.offset // stable
            }
            .map(\.element)
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "PENDING": return "Pending"
        case "CONFIRMED": return "Confirmed"
        case "CONVERTED": return "Reward earned"
        case "REWARDED": return "Rewarded"
        case "DECLINED": return "Declined"
        case "EXPIRED": return "Expired"
        default: return status
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "PENDING": return BrandColor.amber
        case "CONFIRMED": return BrandColor.iris
        case "CONVERTED": return BrandColor.emerald
        case "REWARDED": return BrandColor.accent
        default: return BrandColor.textMuted // DECLINED / EXPIRED / unknown
        }
    }

    /// Reward copy, mirroring the web `rewardDescription` + its "(applied)" suffix.
    static func rewardDescription(_ r: ClientReferral) -> String? {
        guard let tier = r.rewardTier else { return nil }
        let base: String?
        switch tier {
        case "RECOGNITION":
            base = "Thank-you recognition"
        case "DISCOUNT":
            base = r.rewardValue.map { "\(percentLabel($0))% off next booking" }
        case "CREDIT":
            base = r.rewardValue.map { "\(Wire.moneyDecimal(Decimal($0)) ?? "$\(Int($0))") off next booking" }
        default:
            base = nil
        }
        guard let base else { return nil }
        return r.rewardAppliedAt != nil ? "\(base) (applied)" : base
    }

    /// Whole percents drop the ".0" (e.g. 10 → "10", 12.5 → "12.5").
    private static func percentLabel(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
