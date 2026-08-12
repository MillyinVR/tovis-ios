// Who can read this client's chart — and how they take it back.
//
// The native port of web app/client/(gated)/settings/chart-sharing. Until this
// screen existed, an iOS client could be ASKED for chart access (the request
// ships as a push, see CHART_ACCESS_REQUESTED in lib/notifications/eventKeys.ts)
// and had nowhere in the app to answer it, no list of who already held access,
// and no way to revoke. The capability was on the server and unreachable from
// the phone — which for a consent control is the same as not having one.
//
// ⚠️ Two rules this screen inherits from the server, not from taste:
//
//   • REVOKE IS NEVER REFUSED. `PATCH … {action:"REVOKE"}` is accepted even for
//     a pair with no row, because the client asked for "this pro cannot see my
//     chart" and that is the end state either way. Nothing here may gate it, or
//     disable it behind a load, or bury it behind a second screen. Gate the
//     grant; never the undo.
//
//   • A DECLINE IS NEVER ANNOUNCED to the pro who asked (see the ⚠️ block in
//     lib/notifications/chartAccessNotifications.ts). So "No thanks" must not
//     promise to tell them, and must not read as a message being sent.
import SwiftUI
import TovisKit

struct ClientChartAccessView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ClientChartShare])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// A transient action error, shown without blowing away the list.
    @State private var actionError: String?
    /// The pro whose row is mid-write (disables that row's controls only).
    @State private var busyProfessionalId: String?
    /// The pro the client tapped "Turn off" on, pending confirmation. Revoking
    /// is not refusable, but it IS irreversible-ish (the pro faces a cooldown
    /// before they can ask again), so it earns one tap of confirmation.
    @State private var pendingRevoke: ClientChartShare?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro

                if let actionError {
                    BrandErrorBanner(message: actionError)
                }

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 40)
                case let .failed(message):
                    errorState(message)
                case let .loaded(shares):
                    if shares.isEmpty {
                        emptyState
                    } else {
                        // Anyone who can read the chart RIGHT NOW comes first and
                        // is counted. "Who has access" is the question this screen
                        // exists to answer; an open ask is the second question.
                        let granted = shares.filter(\.grantsAccess)
                        let asking = shares.filter { $0.status == .requested }
                        let past = shares.filter {
                            !$0.grantsAccess && $0.status != .requested
                        }

                        if !asking.isEmpty {
                            BrandSection(title: "Waiting on you", trailing: "\(asking.count)") {
                                VStack(spacing: 10) { ForEach(asking) { row($0) } }
                            }
                        }

                        BrandSection(title: "Has access", trailing: "\(granted.count)") {
                            if granted.isEmpty {
                                Text("No one can see your chart right now.")
                                    .font(BrandFont.body(13))
                                    .foregroundStyle(BrandColor.textMuted)
                            } else {
                                VStack(spacing: 10) { ForEach(granted) { row($0) } }
                            }
                        }

                        if !past.isEmpty {
                            BrandSection(title: "Turned off", trailing: "\(past.count)") {
                                VStack(spacing: 10) { ForEach(past) { row($0) } }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Your chart")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .refreshable { await load() }
        .confirmationDialog(
            pendingRevoke.map { "Stop sharing your chart with \($0.professionalName)?" } ?? "",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Turn off sharing", role: .destructive) {
                if let share = pendingRevoke {
                    pendingRevoke = nil
                    Task { await act(share, .revoke) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: {
            Text("They keep the record of work they've already done for you. Everything else closes.")
        }
    }

    // MARK: - Pieces

    private var intro: some View {
        Text("Your chart is the private record a pro keeps about you — allergies, formulas, notes, consent forms. Pros you book with can see the record of the work they do for you. Anyone else has to ask, and you can turn it off at any time.")
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("No one has asked")
                    .font(BrandFont.display(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Pros you book with can always see the record of the work they do for you. Anyone who wants more has to ask here first.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorState(_ message: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textMuted)
                Button("Try again") { Task { await load() } }
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ share: ClientChartShare) -> some View {
        let busy = busyProfessionalId == share.professionalId

        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    BrandAvatar(
                        name: share.professionalName,
                        avatarUrl: share.avatarUrl,
                        size: 38
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(share.professionalName)
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(share.statusCopy)
                            .font(BrandFont.body(12))
                            .foregroundStyle(
                                share.grantsAccess ? BrandColor.accent : BrandColor.textMuted
                            )
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    if share.grantsAccess {
                        // Revoke is never gated — see the ⚠️ block at the top.
                        Button(role: .destructive) {
                            pendingRevoke = share
                        } label: {
                            Text(busy ? "Turning off…" : "Turn off")
                                .font(BrandFont.body(13, .semibold))
                        }
                        .disabled(busy)
                    } else {
                        Button {
                            Task { await act(share, .grant) }
                        } label: {
                            Text(busy ? "Sharing…" : "Share chart")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.accent)
                        }
                        .disabled(busy)

                        // An open ask needs BOTH answers. Without this the only
                        // reachable replies are "yes" and "ignore it forever" —
                        // and an ignored ask sits in the pro's UI as pending.
                        if share.status == .requested {
                            Button(role: .destructive) {
                                Task { await act(share, .decline) }
                            } label: {
                                Text(busy ? "Declining…" : "No thanks")
                                    .font(BrandFont.body(13, .semibold))
                            }
                            .disabled(busy)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(share.professionalName). \(share.statusCopy).")
    }

    // MARK: - Actions

    private func load() async {
        do {
            let shares = try await session.client.clientChartShares.list()
            phase = .loaded(shares)
            actionError = nil
        } catch {
            phase = .failed("Couldn’t load who can see your chart.")
        }
    }

    private func act(
        _ share: ClientChartShare,
        _ action: ClientChartSharesService.Action
    ) async {
        busyProfessionalId = share.professionalId
        actionError = nil
        defer { busyProfessionalId = nil }

        do {
            _ = try await session.client.clientChartShares.update(
                professionalId: share.professionalId,
                action: action
            )
            // Re-read rather than patching in place: the server owns the
            // resulting status (a GRANT on a revoked row is not the same
            // transition as a GRANT on a fresh ask), and the list is short.
            await load()
        } catch {
            actionError = switch action {
            case .grant: "Couldn’t share your chart. Try again."
            case .decline: "Couldn’t save that. Try again."
            case .revoke: "Couldn’t turn off sharing. Try again."
            }
        }
    }
}
