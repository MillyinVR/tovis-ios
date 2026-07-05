// Pro "Your Looks performance" — the native port of the web pro-dashboard C1
// creator analytics. Aggregate engagement + follower growth + top-performing
// looks for the pro's own published Looks. Read-only. Reached from the Profile
// tab → Growth.
import SwiftUI
import TovisKit

struct ProLooksPerformanceView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded(ProLooksAnalytics), failed(String) }
    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(a):
                    if a.publishedCount == 0 {
                        emptyState
                    } else {
                        header(a)
                        totalsGrid(a.totals)
                        followers(a.followers)
                        topLooks(a.topLooks)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Your Looks")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    // MARK: - Sections

    private func header(_ a: ProLooksAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("◆ Performance")
                .font(BrandFont.mono(11)).tracking(0.6).foregroundStyle(BrandColor.accent)
            Text("\(a.publishedCount) published \(a.publishedCount == 1 ? "look" : "looks")")
                .font(BrandFont.display(22, .semibold)).foregroundStyle(BrandColor.textPrimary)
        }
    }

    private func totalsGrid(_ t: ProLooksAnalytics.Totals) -> some View {
        let tiles: [(String, Int, String)] = [
            ("Views", t.views, "eye"),
            ("Likes", t.likes, "heart"),
            ("Comments", t.comments, "bubble.left"),
            ("Saves", t.saves, "bookmark"),
            ("Shares", t.shares, "arrowshape.turn.up.right"),
            ("Booked", t.bookings, "calendar.badge.plus"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(tiles, id: \.0) { tile in
                BrandSurface {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: tile.2).font(.system(size: 14)).foregroundStyle(BrandColor.accent)
                        Text(Self.compact(tile.1)).font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text(tile.0).font(BrandFont.mono(9)).tracking(0.5).foregroundStyle(BrandColor.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func followers(_ f: ProLooksAnalytics.FollowerGrowth) -> some View {
        BrandSection(title: "Followers") {
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.compact(f.total)).font(BrandFont.display(24, .semibold)).foregroundStyle(BrandColor.textPrimary)
                            Text("Total").font(BrandFont.mono(9)).tracking(0.5).foregroundStyle(BrandColor.textMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("+\(f.new30d)").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.emerald)
                            Text("Last 30 days").font(BrandFont.mono(9)).tracking(0.5).foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    if !f.weekly.isEmpty {
                        sparkline(f.weekly)
                    }
                }
            }
        }
    }

    // Oldest → newest weekly bars, height scaled to the busiest week.
    private func sparkline(_ weekly: [ProLooksAnalytics.FollowerBucket]) -> some View {
        let ordered = weekly.sorted { $0.weeksAgo > $1.weeksAgo }
        let peak = max(ordered.map(\.count).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(ordered) { bucket in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(bucket.weeksAgo == 0 ? BrandColor.accent : BrandColor.accent.opacity(0.4))
                    .frame(height: max(4, CGFloat(bucket.count) / CGFloat(peak) * 44))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 48)
    }

    private func topLooks(_ looks: [ProLooksAnalytics.LookStats]) -> some View {
        BrandSection(title: "Top looks") {
            VStack(spacing: 10) {
                ForEach(looks) { look in
                    BrandSurface {
                        HStack(spacing: 12) {
                            thumb(look.thumbUrl)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(look.caption?.isEmpty == false ? look.caption! : "Untitled look")
                                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                    .lineLimit(1)
                                Text(Self.statLine(look))
                                    .font(BrandFont.mono(10)).tracking(0.3).foregroundStyle(BrandColor.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func thumb(_ url: String?) -> some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    BrandColor.bgSecondary
                }
            } else {
                BrandColor.bgSecondary
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(BrandColor.textMuted)
            Text("No published looks yet").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("Share a look to start tracking views, saves, and bookings.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
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

    private static func statLine(_ l: ProLooksAnalytics.LookStats) -> String {
        "\(compact(l.views)) views · \(compact(l.likes)) likes · \(compact(l.saves)) saves · \(compact(l.bookings)) booked"
    }

    /// 1234 → "1.2k".
    private static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return String(format: k < 10 ? "%.1fk" : "%.0fk", k)
    }

    private func load() async {
        do {
            let a = try await session.client.proLooks.analytics()
            phase = .loaded(a)
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your Looks performance.")
        }
    }
}
