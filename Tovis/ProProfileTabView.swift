// Pro Profile tab — the footer's slot-5 destination (web
// `/pro/profile/public-profile`). Shows the pro's own profile as clients see it
// (header + stats + services + portfolio + reviews), with an **Edit profile**
// sheet (PATCH /pro/profile), a **Manage services** screen (offerings CRUD), and
// the account controls: **switch to the client workspace** (re-mints the JWT
// acting role server-side), theme, and sign out.
import SwiftUI
import TovisKit

struct ProProfileTabView: View {
    @Environment(SessionModel.self) private var session
    @Environment(ThemeStore.self) private var theme

    private enum Phase {
        case loading
        case loaded(ProMyProfile, ProProfile?)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var editing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                            .padding(.top, 80)
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(mine, pub):
                        content(mine: mine, pub: pub)
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
                if case let .loaded(mine, _) = phase {
                    ProEditProfileSheet(profile: mine) { saved in
                        if case let .loaded(_, pub) = phase { phase = .loaded(saved, pub) }
                    }
                }
            }
            .tint(BrandColor.accent)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(mine: ProMyProfile, pub: ProProfile?) -> some View {
        header(mine: mine, pub: pub)

        if let stats = pub?.stats { statsRow(stats) }

        Button { editing = true } label: {
            Label("Edit profile", systemImage: "pencil")
                .font(BrandFont.body(16, .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(BrandColor.textPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1)
                )
        }

        servicesSection(pub: pub)

        if let tiles = pub?.portfolioTiles, !tiles.isEmpty {
            portfolioSection(tiles)
        }

        if let reviews = pub?.reviews, !reviews.isEmpty {
            reviewsSection(reviews)
        }
    }

    private func header(mine: ProMyProfile, pub: ProProfile?) -> some View {
        let name = pub?.header.displayName ?? mine.businessName ?? "Your studio"
        return BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    avatar(url: mine.avatarUrl, name: name)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(BrandFont.display(22, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if let label = pub?.header.professionLabel {
                            Text(label)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                        if let handle = mine.handle {
                            Text("@\(handle)")
                                .font(BrandFont.mono(12))
                                .foregroundStyle(BrandColor.accent)
                        }
                    }
                    Spacer()
                }

                if let bio = mine.bio, !bio.isEmpty {
                    Text(bio)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                HStack(spacing: 8) {
                    if let location = mine.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    if mine.isPremium { BrandPill(text: "Premium", tint: BrandColor.gold) }
                    if pub?.header.isLicenseVerified == true {
                        BrandPill(text: "Verified", tint: BrandColor.emerald)
                    }
                }
            }
        }
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

    private func statsRow(_ stats: ProProfileStats) -> some View {
        HStack(spacing: 10) {
            statTile(stats.completedBookingsLabel, "Bookings")
            statTile(stats.reviewCountLabel, "Reviews")
            if let rating = stats.averageRatingLabel {
                statTile(rating, "Rating")
            } else {
                statTile(stats.favoritesLabel, "Favorites")
            }
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

    private func servicesSection(pub: ProProfile?) -> some View {
        BrandSection(title: "Services") {
            VStack(spacing: 10) {
                if let offerings = pub?.offerings, !offerings.isEmpty {
                    ForEach(offerings.prefix(3)) { o in
                        BrandSurface {
                            HStack {
                                Text(o.name)
                                    .font(BrandFont.body(14, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                Spacer()
                                if let price = o.priceFromLabel {
                                    Text(price)
                                        .font(BrandFont.body(13))
                                        .foregroundStyle(BrandColor.textSecondary)
                                }
                            }
                        }
                    }
                }
                NavigationLink {
                    ProOfferingsView()
                } label: {
                    HStack {
                        Text("Manage services")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func portfolioSection(_ tiles: [ProPortfolioTile]) -> some View {
        BrandSection(title: "Portfolio") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tiles.prefix(12)) { tile in
                        ZStack {
                            BrandColor.bgSecondary
                            if let u = URL(string: tile.displayUrl) {
                                AsyncImage(url: u) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    ProgressView().tint(BrandColor.accent)
                                }
                            }
                            if tile.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .frame(width: 110, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private func reviewsSection(_ reviews: [ProReview]) -> some View {
        BrandSection(title: "Reviews") {
            VStack(spacing: 10) {
                ForEach(reviews.prefix(3)) { review in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                ForEach(0..<5, id: \.self) { i in
                                    Image(systemName: i < review.rating ? "star.fill" : "star")
                                        .font(.system(size: 11))
                                        .foregroundStyle(BrandColor.gold)
                                }
                                Spacer()
                                Text(review.clientName)
                                    .font(BrandFont.body(12))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                            if let headline = review.headline, !headline.isEmpty {
                                Text(headline)
                                    .font(BrandFont.body(14, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                            }
                            if let body = review.body, !body.isEmpty {
                                Text(body)
                                    .font(BrandFont.body(13))
                                    .foregroundStyle(BrandColor.textSecondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }
        }
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
            // Public preview is best-effort — a pending pro 404s it; show the rest.
            let pub = try? await session.client.profiles.professional(id: mine.id)
            phase = .loaded(mine, pub)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your profile.")
        }
    }
}
