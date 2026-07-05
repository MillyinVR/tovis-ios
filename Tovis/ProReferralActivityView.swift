// Pro "Referral activity" — the native port of the web `/pro/referral-rewards`
// viewer (tovis-app PR #500). Who-referred-whom + conversion/reward state for
// referrals credited to this pro. Read-only. Reached from the Profile tab →
// Growth. Every row is at least CONVERTED (scope = Referral.professionalId).
import SwiftUI
import TovisKit

struct ProReferralActivityView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded(ProReferralActivity), failed(String) }
    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(activity):
                    summary(activity.summary)
                    if activity.rows.isEmpty {
                        emptyState
                    } else {
                        rows(activity.rows)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Referrals")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    // MARK: - Sections

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
        BrandSection(title: "Activity") {
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

    // MARK: - Helpers

    private static func rewardLabel(_ row: ProReferralActivity.Row) -> String? {
        guard let tier = row.rewardTier, let value = row.rewardValue else { return nil }
        switch tier {
        case "CREDIT": return (Wire.money(String(value)) ?? "$\(Int(value))") + " credit"
        case "DISCOUNT": return "\(Int(value))% off"
        default: return nil
        }
    }

    private func load() async {
        do {
            let activity = try await session.client.proReferrals.activity()
            phase = .loaded(activity)
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your referral activity.")
        }
    }
}
