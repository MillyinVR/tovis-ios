// Pro Profile tab — the footer's slot-5 destination (web
// `/pro/profile/public-profile`), ported 1:1: approval notice, profile card
// (avatar · name · ✓ · subtitle·location · bio · Edit / Payment settings / View as
// client), the "Your link" vanity card (locked/reserve/live), a stats grid, quick
// actions (+ Add services / Messages / + Upload), and the portfolio · services ·
// reviews tab switch. Plus the native account controls (workspace switch, business
// links, theme, sign out) that the web reaches through its global nav.
import SwiftUI
import TovisKit

struct ProProfileTabView: View {
    @Environment(SessionModel.self) private var session
    @Environment(ThemeStore.self) private var theme

    /// The pro's brand name, used in the approval-notice copy.
    private let brandName = "Tovis"

    private enum Tab: String, CaseIterable, Identifiable {
        case portfolio, services, reviews
        var id: String { rawValue }
    }

    private enum Phase {
        case loading
        case loaded(ProMyProfile, ProProfile?, isApproved: Bool)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var tab: Tab = .portfolio
    @State private var editing = false
    @State private var showPayment = false
    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                            .padding(.top, 80)
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(mine, pub, isApproved):
                        content(mine: mine, pub: pub, isApproved: isApproved)
                    }

                    accountSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)   // clear the raised footer
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .onChange(of: session.refreshTick) { Task { await load() } }
            .sheet(isPresented: $editing) {
                if case let .loaded(mine, _, isApproved) = phase {
                    ProEditProfileSheet(profile: mine, canEditHandle: isApproved) { saved in
                        if case let .loaded(_, pub, ok) = phase { phase = .loaded(saved, pub, isApproved: ok) }
                    }
                }
            }
            .sheet(isPresented: $showPayment) { ProPaymentSettingsView() }
            .tint(BrandColor.accent)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(mine: ProMyProfile, pub: ProProfile?, isApproved: Bool) -> some View {
        if !isApproved { approvalNotice }

        profileCard(mine: mine, pub: pub, isApproved: isApproved)
        yourLinkCard(mine: mine, isApproved: isApproved)
        if let stats = pub?.stats { statsGrid(stats) }
        quickActions

        tabBar
        switch tab {
        case .portfolio: portfolioTab(pub)
        case .services: servicesTab(pub)
        case .reviews: reviewsTab(pub)
        }
    }

    private var approvalNotice: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your profile is under review")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Your public profile is not live yet. While review is pending, you are not searchable, not publicly bookable, and clients cannot view your public profile yet.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                Text("You can keep setting up your services, portfolio, and payment details here while \(brandName) reviews your account.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private func profileCard(mine: ProMyProfile, pub: ProProfile?, isApproved: Bool) -> some View {
        let name = pub?.header.displayName ?? mine.businessName ?? "Your business name"
        let subtitle = pub?.header.professionLabel ?? "Beauty professional"
        let location = mine.location ?? pub?.header.location
        return BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    avatar(url: mine.avatarUrl, name: name)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(name)
                                .font(BrandFont.display(22, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            if isApproved {
                                Text("✓").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.emerald)
                            }
                        }
                        Text(location.map { "\(subtitle) · \($0)" } ?? subtitle)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textMuted)
                        if let handle = mine.handle {
                            Text("@\(handle)")
                                .font(BrandFont.mono(12))
                                .foregroundStyle(BrandColor.accent)
                        }
                    }
                    Spacer()
                }

                if let bio = mine.bio, !bio.isEmpty {
                    Text("“\(bio)”")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                } else {
                    Text("Add a short bio so clients know what you specialize in.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textMuted)
                }

                HStack(spacing: 8) {
                    pillButton("Edit") { editing = true }
                    pillButton("Payment settings") { showPayment = true }
                    if isApproved {
                        NavigationLink {
                            ProProfileView(professionalId: mine.id, fallbackName: name)
                        } label: {
                            Text("View as client ›")
                                .font(BrandFont.body(12, .semibold))
                                .foregroundStyle(BrandColor.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(BrandColor.bgSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func avatar(url: String?, name: String) -> some View {
        if let url, let u = URL(string: url) {
            AsyncImage(url: u) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                BrandAvatar(name: name, size: 60)
            }
            .frame(width: 60, height: 60)
            .clipShape(Circle())
        } else {
            BrandAvatar(name: name, size: 60)
        }
    }

    // MARK: - Your link (vanity)

    @ViewBuilder
    private func yourLinkCard(mine: ProMyProfile, isApproved: Bool) -> some View {
        let host = mine.handle.map { "\($0).tovis.me" }
        let urlString = mine.handle.map { "https://\($0).tovis.me" }
        BrandSection(title: "Your link") {
            BrandSurface {
                if !isApproved {
                    Text("Your .tovis.me link unlocks once your account is verified. You can finish the rest of your profile in the meantime.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                } else if mine.isPremium, let host, let urlString, let url = URL(string: urlString) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(host).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            BrandPill(text: "Live", tint: BrandColor.emerald)
                        }
                        HStack(spacing: 8) {
                            Button { UIPasteboard.general.string = urlString } label: { linkPill("Copy") }
                                .buttonStyle(.plain)
                            Link(destination: url) { linkPill("Open ↗") }
                            ShareLink(item: url) { linkPill("Share") }
                        }
                    }
                } else if let host {
                    VStack(alignment: .leading, spacing: 10) {
                        (Text("You've reserved ").foregroundStyle(BrandColor.textSecondary)
                            + Text(host).foregroundStyle(BrandColor.textPrimary).bold()
                            + Text(". It goes live the moment you upgrade.").foregroundStyle(BrandColor.textSecondary))
                            .font(BrandFont.body(12))
                        upgradeButton
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Claim a custom link like you.tovis.me. Pick a handle with Edit profile above, then upgrade to make it live.")
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                        upgradeButton
                    }
                }
            }
        }
    }

    private var upgradeButton: some View {
        Text("Upgrade to activate ›")
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(BrandColor.onAccent)
            .padding(.vertical, 9).padding(.horizontal, 14)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func linkPill(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(BrandColor.textPrimary)
            .padding(.vertical, 8).padding(.horizontal, 14)
            .background(BrandColor.bgSecondary)
            .clipShape(Capsule())
    }

    // MARK: - Stats

    private func statsGrid(_ stats: ProProfileStats) -> some View {
        // Web shows rating · reviews · favorites · looks · followers. The native
        // public-profile read carries rating/reviews/favorites; looks & followers
        // aren't in that projection, so they're omitted until exposed.
        HStack(spacing: 10) {
            statTile(stats.averageRatingLabel ?? "–", "Rating")
            statTile(stats.reviewCountLabel, "Reviews")
            statTile(stats.favoritesLabel, "Favs")
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                Text(label.uppercased())
                    .font(BrandFont.mono(9)).tracking(0.7)
                    .foregroundStyle(BrandColor.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickAction("+ Add services", tone: BrandColor.accent) { tab = .services }
            quickAction("+ Upload", tone: nil) { tab = .portfolio }
        }
    }

    private func quickAction(_ title: String, tone: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) { quickActionLabel(title, tone: tone) }.buttonStyle(.plain)
    }

    private func quickActionLabel(_ title: String, tone: Color? = nil) -> some View {
        Text(title)
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(tone ?? BrandColor.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 18) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue)
                            .font(BrandFont.body(14, tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? BrandColor.textPrimary : BrandColor.textMuted)
                        Rectangle()
                            .fill(tab == t ? BrandColor.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func portfolioTab(_ pub: ProProfile?) -> some View {
        let tiles = pub?.portfolioTiles ?? []
        if tiles.isEmpty {
            emptyTab("No portfolio assets yet. Upload your best work to start building your client-facing profile.")
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(tiles.prefix(60)) { tile in
                    if let before = tile.before, let beforeStr = before.displayUrl,
                       let beforeURL = URL(string: beforeStr), let afterURL = URL(string: tile.displayUrl) {
                        // Paired before/after → the comparison slider fills the cell.
                        BeforeAfterCompareView(beforeURL: beforeURL, afterURL: afterURL, height: 120, cornerRadius: 12)
                    } else {
                        Button {
                            viewingMedia = FullscreenMedia.remote(id: tile.id, urlString: tile.src, isVideo: tile.isVideo)
                        } label: {
                            ZStack {
                                BrandColor.bgSecondary
                                if let u = URL(string: tile.displayUrl) {
                                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { ProgressView().tint(BrandColor.accent) }
                                }
                                if tile.isVideo {
                                    Image(systemName: "play.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.9))
                                }
                            }
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .mediaFullscreenCover($viewingMedia)
        }
    }

    @ViewBuilder
    private func servicesTab(_ pub: ProProfile?) -> some View {
        VStack(spacing: 10) {
            if let offerings = pub?.offerings, !offerings.isEmpty {
                ForEach(offerings.prefix(4)) { o in
                    BrandSurface {
                        HStack {
                            Text(o.name).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            if let price = o.priceFromLabel {
                                Text(price).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                            }
                        }
                    }
                }
            }
            NavigationLink { ProOfferingsView() } label: {
                HStack {
                    Text("Manage services").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.accent)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BrandColor.textMuted)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func reviewsTab(_ pub: ProProfile?) -> some View {
        let reviews = pub?.reviews ?? []
        if reviews.isEmpty {
            emptyTab("No reviews yet.")
        } else {
            VStack(spacing: 10) {
                ForEach(reviews.prefix(20)) { review in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                ForEach(0..<5, id: \.self) { i in
                                    Image(systemName: i < review.rating ? "star.fill" : "star")
                                        .font(.system(size: 11)).foregroundStyle(BrandColor.gold)
                                }
                                Spacer()
                                Text(review.clientName).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                            }
                            if let headline = review.headline, !headline.isEmpty {
                                Text(headline).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                            }
                            if let body = review.body, !body.isEmpty {
                                Text(body).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary).lineLimit(4)
                            }
                        }
                    }
                }
            }
        }
    }

    private func emptyTab(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            .padding(.vertical, 30)
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandSection(title: "Workspace") {
                Button {
                    Task { await session.switchWorkspace(to: .client) }
                } label: {
                    BrandSurface {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2")
                                .font(.system(size: 18))
                                .foregroundStyle(BrandColor.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Switch to client")
                                    .font(BrandFont.body(15, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                Text("Browse & book as a client")
                                    .font(BrandFont.body(12))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                            Spacer()
                            if session.isWorking {
                                ProgressView().tint(BrandColor.accent)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(session.isWorking)
            }

            if let message = session.errorMessage {
                Text(message).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            }

            BrandSection(title: "Business") {
                VStack(spacing: 10) {
                    businessLink(icon: "person.2.fill", title: "Clients") { ProClientsView() }
                    businessLink(icon: "person.crop.circle.badge.clock", title: "Waitlist") { ProWaitlistView() }
                    businessLink(icon: "checklist", title: "Reminders") { ProRemindersView() }
                    businessLink(icon: "clock", title: "Working hours") { ProWorkingHoursView() }
                    businessLink(icon: "bell.badge", title: "Appointment reminders") { ProReminderSettingsView() }
                    businessLink(icon: "clock.badge.exclamationmark", title: "No-show fees") { ProNoShowSettingsView() }
                }
            }

            BrandSection(title: "Growth") {
                VStack(spacing: 10) {
                    businessLink(icon: "chart.line.uptrend.xyaxis", title: "Your Looks performance") { ProLooksPerformanceView() }
                    businessLink(icon: "gift", title: "Referral activity") { ProReferralActivityView() }
                    businessLink(icon: "star.circle", title: "Membership") { ProMembershipView() }
                }
            }

            BrandSection(title: "Appearance") {
                BrandSurface {
                    Picker("Theme", selection: Binding(
                        get: { theme.preference },
                        set: { theme.preference = $0 }
                    )) {
                        ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Button(role: .destructive) {
                Task { await session.logout() }
            } label: {
                Text("Sign out")
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.ember)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
                    )
            }
        }
    }

    private func businessLink<Destination: View>(
        icon: String, title: String, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            BrandSurface {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(BrandColor.accent)
                        .frame(width: 28)
                    Text(title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
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
        .padding(.top, 50)
    }

    // MARK: - Load

    private func load() async {
        do {
            let mine = try await session.client.proProfile.myProfile()
            // The public preview doubles as the approval signal: a 404 means the
            // pro isn't publicly approved yet (→ "under review"); any other error
            // leaves us optimistic so a transient failure doesn't mis-flag review.
            var pub: ProProfile?
            var isApproved = true
            do {
                pub = try await session.client.profiles.professional(id: mine.id)
            } catch let APIError.server(status, _, _) where status == 404 {
                pub = nil
                isApproved = false
            } catch {
                pub = nil
            }
            phase = .loaded(mine, pub, isApproved: isApproved)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your profile.")
        }
    }
}
