// Pro Aftercare — the native counterpart of the web `/pro/aftercare`
// (app/pro/aftercare/AftercareListClient.tsx), backed by GET /api/v1/pro/aftercare
// (tovis-app PR #436). Summary tiles + Draft/Sent/Finished filter tabs + search
// over the derived cards (before/after thumbs · client · service · status ·
// rebook chip · activity stamp). A card taps through to the aftercare authoring
// screen (Phase S3, the web "View full aftercare" destination), where the pro
// writes notes, recommends products, sets a rebook, and sends to the client.
// Lives on the Overview home's Aftercare tab.
import SwiftUI
import TovisKit

struct ProAftercareListView: View {
    @Environment(SessionModel.self) private var session

    private enum Tab: String, CaseIterable, Identifiable {
        case all, draft, sent, finished
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .draft: return "Draft"
            case .sent: return "Sent"
            case .finished: return "Finished"
            }
        }
    }

    private enum Phase {
        case loading
        case loaded([ProAftercareCardItem])
        case failed(String)
    }

    private enum NudgeState: Equatable {
        case sending
        case sent
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var nudgeState: [String: NudgeState] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 50)
                case let .failed(message):
                    errorState(message)
                case let .loaded(items):
                    content(items)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)   // clear the raised footer
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ items: [ProAftercareCardItem]) -> some View {
        summaryRow(items)
        filterTabs(items)
        searchField

        let shown = visible(items)
        if shown.isEmpty {
            Text("No aftercare here yet.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else {
            VStack(spacing: 10) {
                ForEach(shown) { item in
                    BrandSurface(tint: BrandColor.bgSecondary) {
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink {
                                ProAftercareAuthorView(bookingId: item.bookingId)
                            } label: {
                                cardBody(item)
                            }
                            .buttonStyle(.plain)

                            // One-tap re-ping for an already-sent aftercare whose
                            // rebook loop is still open (server marks these
                            // action == "nudge"). Mirrors the web list's Nudge
                            // button → POST .../aftercare/nudge.
                            if item.action == "nudge" {
                                nudgeControl(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func summaryRow(_ items: [ProAftercareCardItem]) -> some View {
        let drafts = items.filter { $0.status == "draft" }.count
        // Awaiting your follow-up: any open rebook loop where a nudge is offered —
        // a sent card OR a finished (paid) card that hasn't rebooked yet. Mirrors
        // the web summarize (action === 'nudge'), so the tile matches 1:1.
        let awaiting = items.filter { $0.action == "nudge" }.count
        let overdue = items.filter { $0.rebook?.kind == "overdue" }.count
        return HStack(spacing: 10) {
            summaryTile(value: drafts, label: "Drafts", tint: BrandColor.gold)
            summaryTile(value: awaiting, label: "Awaiting", tint: BrandColor.accent)
            summaryTile(value: overdue, label: "Overdue", tint: BrandColor.ember)
        }
    }

    private func summaryTile(value: Int, label: String, tint: Color) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(BrandFont.display(24, .bold))
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(BrandFont.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(BrandColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func filterTabs(_ items: [ProAftercareCardItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases) { item in
                    let active = item == tab
                    let count = item == .all ? items.count : items.filter { $0.status == item.rawValue }.count
                    Button { tab = item } label: {
                        Text("\(item.label) \(count)")
                            .font(BrandFont.body(12, .bold))
                            .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(active ? BrandColor.accent : BrandColor.bgSecondary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(BrandColor.textMuted.opacity(active ? 0 : 0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(BrandColor.textMuted)
            TextField("Search client or service", text: $query)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }

    private func cardBody(_ item: ProAftercareCardItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let media = item.media, media.beforeUrl != nil || media.afterUrl != nil {
                HStack(spacing: 8) {
                    thumb(media.beforeUrl, label: "BEFORE")
                    thumb(media.afterUrl, label: "AFTER")
                }
            }

            HStack(spacing: 8) {
                BrandAvatar(name: item.clientName, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.clientName)
                        .font(BrandFont.body(14, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Text(item.serviceName)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                BrandPill(text: statusLabel(item.status), tint: statusTint(item.status))
            }

            HStack(spacing: 8) {
                if let rebook = item.rebook {
                    BrandPill(text: "\(rebookLabel(rebook.kind)) \(rebook.value)", tint: rebookTint(rebook.kind))
                }
                if let label = item.bookingDateLabel {
                    Text(label)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Spacer(minLength: 0)
                if let ago = item.ago {
                    Text("\(ago.verb.capitalized) \(ago.value)")
                        .font(BrandFont.mono(10))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func nudgeControl(_ item: ProAftercareCardItem) -> some View {
        let state = nudgeState[item.bookingId]
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await nudge(item) }
            } label: {
                HStack(spacing: 6) {
                    switch state {
                    case .sending:
                        ProgressView().tint(BrandColor.onAccent).scaleEffect(0.8)
                        Text("Nudging…")
                    case .sent:
                        Image(systemName: "checkmark")
                        Text("Nudge sent")
                    default:
                        Image(systemName: "bell.badge")
                        Text("Nudge")
                    }
                }
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.onAccent)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(state == .sent ? BrandColor.emerald : BrandColor.accent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(state == .sending || state == .sent)

            if case let .failed(message) = state {
                Text(message)
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.ember)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func thumb(_ urlString: String?, label: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BrandColor.bgPrimary)
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(BrandColor.accent)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(label)
                .font(BrandFont.mono(8))
                .tracking(1.0)
                .foregroundStyle(BrandColor.textPrimary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(BrandColor.bgPrimary.opacity(0.7))
                .clipShape(Capsule())
                .padding(6)
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private func visible(_ items: [ProAftercareCardItem]) -> [ProAftercareCardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items
            .filter { tab == .all || $0.status == tab.rawValue }
            .filter { trimmed.isEmpty || $0.searchText.contains(trimmed) }
            .sorted { $0.sortKey > $1.sortKey }
    }

    private func statusLabel(_ status: String) -> String {
        status.prefix(1).uppercased() + status.dropFirst()
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "draft": return BrandColor.gold
        case "finished": return BrandColor.emerald
        default: return BrandColor.accent
        }
    }

    private func rebookLabel(_ kind: String) -> String {
        switch kind {
        case "next": return "Next"
        case "overdue": return "Overdue"
        default: return "Rebook"
        }
    }

    private func rebookTint(_ kind: String) -> Color {
        switch kind {
        case "overdue": return BrandColor.ember
        case "next": return BrandColor.emerald
        default: return BrandColor.accent
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func load() async {
        do {
            let items = try await session.client.proBookings.aftercareList()
            phase = .loaded(items)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your aftercare.")
        }
    }

    private func nudge(_ item: ProAftercareCardItem) async {
        nudgeState[item.bookingId] = .sending
        do {
            try await session.client.proBookings.nudgeAftercare(bookingId: item.bookingId)
            nudgeState[item.bookingId] = .sent
        } catch let error as APIError {
            nudgeState[item.bookingId] = .failed(error.userMessage)
        } catch {
            nudgeState[item.bookingId] = .failed("Couldn’t nudge the client.")
        }
    }
}
