// The "Me" tab — a native rebuild of the web client dashboard
// (app/client/(gated)/ClientMeDashboard.tsx + /api/v1/me). Same sections in the
// same order: profile header + stats, creator card, upcoming, Your Looks, and
// the BOARDS / FOLLOWING / HISTORY tabs. Reads GET /api/v1/me via MeService.
import SwiftUI
import TovisKit

struct MeView: View {
    @Environment(SessionModel.self) private var session
    @Environment(ThemeStore.self) private var theme

    private enum Phase {
        case loading
        case loaded(ClientMe)
        case failed(String)
    }

    private enum MeTab: String, CaseIterable {
        case boards = "BOARDS"
        case following = "FOLLOWING"
        case history = "HISTORY"
    }

    @State private var phase: Phase = .loading
    @State private var tab: MeTab = .boards

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch phase {
                    case .loading:
                        loadingState
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(me):
                        content(me)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .onChange(of: session.refreshTick) { Task { await load() } }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func content(_ me: ClientMe) -> some View {
        header(me)

        if me.creator.isCreator {
            creatorCard(me.creator).padding(.top, 24)
        }

        if let upcoming = me.upcomingNotificationBooking {
            upcomingCard(upcoming).padding(.top, 24)
        }

        if !me.myLooks.isEmpty {
            yourLooks(me.myLooks).padding(.top, 32)
        }

        sectionTabs.padding(.top, 32)

        Group {
            switch tab {
            case .boards: boardsTab(me.boards)
            case .following: followingTab(me.following.items)
            case .history: historyTab(me.history)
            }
        }
        .padding(.top, 18)
    }

    // MARK: - Header

    private func header(_ me: ClientMe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(formattedHandle(me).uppercased())
                    .font(BrandFont.mono(11))
                    .tracking(1.8)
                    .foregroundStyle(BrandColor.textSecondary)
                Spacer()
                accountMenu(me)
            }

            HStack(alignment: .top, spacing: 16) {
                BrandAvatar(name: displayName(me), avatarUrl: me.profile.avatarUrl, size: 86)

                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName(me))
                        .font(BrandFont.display(28, .semibold).italic())
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)

                    if let since = memberSince(me) {
                        Text("joined \(since)")
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textSecondary)
                            .padding(.top, 8)
                    }

                    HStack(alignment: .bottom, spacing: 22) {
                        if me.profile.isPublicProfile {
                            stat("FOLLOWERS", me.counts.followers)
                        }
                        stat("BOARDS", me.counts.boards)
                        stat("SAVED", me.counts.saved)
                        stat("BOOKED", me.counts.booked)
                    }
                    .padding(.top, 18)
                }
            }
            .padding(.top, 20)
        }
    }

    private func accountMenu(_ me: ClientMe) -> some View {
        Menu {
            if let email = me.user.email { Text(email) }

            Picker("Theme", selection: Binding(
                get: { theme.preference },
                set: { theme.preference = $0 }
            )) {
                ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
            }

            Divider()

            Button(role: .destructive) {
                Task { await session.logout() }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 26))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(BrandFont.display(18, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(label)
                .font(BrandFont.mono(10))
                .tracking(1.6)
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - Creator card

    private func creatorCard(_ creator: ClientMeCreator) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 14) {
                Label("YOUR INFLUENCE", systemImage: "sparkles")
                    .font(BrandFont.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(BrandColor.textSecondary)
                    .labelStyle(.titleAndIcon)

                Divider().overlay(BrandColor.textMuted.opacity(0.12))

                HStack(spacing: 16) {
                    influenceStat("SAVES ON YOUR LOOKS", creator.savesOnYourLooks)
                    Rectangle().fill(BrandColor.textMuted.opacity(0.12)).frame(width: 1, height: 34)
                    influenceStat("BOOKED FROM YOU", creator.bookedFromYou)
                }
            }
        }
    }

    private func influenceStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(BrandFont.display(18, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(label)
                .font(BrandFont.mono(9))
                .tracking(1.2)
                .foregroundStyle(BrandColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Upcoming

    private func upcomingCard(_ booking: ClientBooking) -> some View {
        NavigationLink {
            BookingDetailView(booking: booking, onDecision: { await load() })
        } label: {
            BrandSurface(tint: BrandColor.accent.opacity(0.08)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Circle().fill(BrandColor.accent).frame(width: 6, height: 6)
                        Text("UPCOMING")
                        Text("·")
                        Text(Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone))
                    }
                    .font(BrandFont.mono(10))
                    .tracking(1.4)
                    .foregroundStyle(BrandColor.accent)
                    .lineLimit(1)

                    Text(booking.display.title)
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)

                    let pieces = [
                        booking.professional?.displayName,
                        Wire.money(booking.checkout.totalAmount ?? booking.checkout.subtotalSnapshot),
                    ].compactMap { $0 }
                    if !pieces.isEmpty {
                        Text(pieces.joined(separator: " · "))
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Your looks

    private func yourLooks(_ looks: [ClientMeLook]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR LOOKS")
                    .font(BrandFont.mono(11)).tracking(1.4)
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Text("\(looks.count)")
                    .font(BrandFont.mono(11)).tracking(1.2)
                    .foregroundStyle(BrandColor.textSecondary)
            }
            LazyVGrid(columns: twoCol, spacing: 18) {
                ForEach(looks) { look in
                    VStack(alignment: .leading, spacing: 8) {
                        tile(look.imageUrl, fallback: look.name, aspect: 1)
                        Text(look.name)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1)
                        Text(look.isPublic ? "PUBLIC" : "PRIVATE")
                            .font(BrandFont.mono(9)).tracking(1.2)
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Tabs

    private var sectionTabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                ForEach(MeTab.allCases, id: \.self) { item in
                    let active = item == tab
                    Button { tab = item } label: {
                        VStack(spacing: 10) {
                            Text(item.rawValue)
                                .font(BrandFont.mono(12)).tracking(0.8)
                                .foregroundStyle(active ? BrandColor.textPrimary : BrandColor.textSecondary)
                            Rectangle()
                                .fill(active ? BrandColor.accent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(BrandColor.textMuted.opacity(0.12)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func boardsTab(_ boards: [ClientMeBoard]) -> some View {
        if boards.isEmpty {
            emptyState("No boards yet", "Save looks from the feed to start building boards.")
        } else {
            LazyVGrid(columns: twoCol, spacing: 18) {
                ForEach(boards) { board in
                    VStack(alignment: .leading, spacing: 8) {
                        boardPreview(board.previewImageUrls)
                        Text(board.name)
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1)
                        Text("\(board.itemCount) SAVED")
                            .font(BrandFont.mono(9)).tracking(1.2)
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func followingTab(_ items: [ClientMeFollowingItem]) -> some View {
        if items.isEmpty {
            emptyState("No follows yet", "When you follow a pro, they’ll show up here.")
        } else {
            VStack(spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        ProProfileView(professionalId: item.professional.id,
                                       fallbackName: item.professional.displayName)
                    } label: {
                        BrandSurface {
                            HStack(spacing: 12) {
                                BrandAvatar(name: item.professional.displayName,
                                            avatarUrl: item.professional.avatarUrl, size: 52)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.professional.displayName)
                                        .font(BrandFont.body(15, .semibold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    if let handle = item.professional.handle {
                                        Text("@\(handle)")
                                            .font(BrandFont.body(12))
                                            .foregroundStyle(BrandColor.textSecondary)
                                    }
                                    if let subtitle = item.professional.subtitle {
                                        Text(subtitle)
                                            .font(BrandFont.body(12))
                                            .foregroundStyle(BrandColor.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func historyTab(_ items: [ClientMeHistoryItem]) -> some View {
        if items.isEmpty {
            emptyState("No history yet", "Your upcoming and past bookings will appear here.")
        } else {
            VStack(spacing: 18) {
                ForEach(items) { item in
                    NavigationLink {
                        BookingDetailView(booking: item.booking, onDecision: { await load() })
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            tile(item.heroImageUrl, fallback: item.booking.display.title, aspect: 1.18)
                            Text(item.booking.display.title)
                                .font(BrandFont.body(14, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            Text(item.label)
                                .font(BrandFont.mono(9)).tracking(1.2)
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Small pieces

    private var twoCol: [GridItem] {
        [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }

    /// A rounded media tile with a branded fallback when there's no image.
    private func tile(_ url: String?, fallback: String, aspect: CGFloat) -> some View {
        ZStack {
            BrandColor.bgSecondary
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(BrandColor.accent)
                }
            } else {
                Text(fallback)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
        }
        .aspectRatio(aspect, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    /// 2×2 thumbnail mosaic for a board (mirrors the web PrototypeThumb).
    private func boardPreview(_ urls: [String]) -> some View {
        let four = Array(urls.prefix(4))
        return ZStack {
            BrandColor.bgSecondary
            if four.isEmpty {
                Text("No preview")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                    ForEach(0..<4, id: \.self) { i in
                        ZStack {
                            BrandColor.bgPrimary
                            if i < four.count, let u = URL(string: four[i]) {
                                AsyncImage(url: u) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: { Color.clear }
                            }
                        }
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    private func emptyState(_ title: String, _ body: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(body)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 100)
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
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Derived values (mirror the web page.tsx helpers)

    private func displayName(_ me: ClientMe) -> String {
        if let first = me.profile.firstName?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
            return first
        }
        if let prefix = me.profile.email?.split(separator: "@").first, !prefix.isEmpty {
            return String(prefix)
        }
        return "You"
    }

    private func formattedHandle(_ me: ClientMe) -> String {
        let raw = me.profile.handle?.trimmingCharacters(in: .whitespaces)
            ?? me.profile.email?.split(separator: "@").first.map(String.init)
            ?? "you"
        return raw.hasPrefix("@") ? raw : "@\(raw)"
    }

    /// "Nov '25" — month + 2-digit year in UTC, like the web `formatMemberSince`.
    private func memberSince(_ me: ClientMe) -> String? {
        guard let date = Wire.date(me.user.createdAt) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM ''yy"
        return f.string(from: date)
    }

    // MARK: - Load

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let me = try await session.client.me.fetch()
            phase = .loaded(me)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }
}