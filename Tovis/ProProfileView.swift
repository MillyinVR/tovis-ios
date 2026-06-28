// Public professional profile — loads GET /api/v1/professionals/{id} and renders
// header, stats, bio, offerings, portfolio, and reviews. Pushed from any pro
// name/avatar across the app.
import SwiftUI
import TovisKit

struct ProProfileView: View {
    @Environment(SessionModel.self) private var session

    let professionalId: String
    /// Optional name shown in the nav bar / loading state before the load lands.
    var fallbackName: String? = nil

    private enum Phase {
        case loading
        case loaded(ProProfile)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var isFavorited = false
    @State private var favoriteWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch phase {
                case .loading:
                    loadingState
                case let .failed(message):
                    errorState(message)
                case let .loaded(profile):
                    content(profile)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle(fallbackName ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task {
            if case .loading = phase { await load() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ profile: ProProfile) -> some View {
        headerCard(profile.header)
        statsRow(profile.stats)

        if let bio = profile.header.bio, !bio.isEmpty {
            Text(bio)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !profile.offerings.isEmpty {
            BrandSection(title: "Services") {
                VStack(spacing: 10) {
                    ForEach(profile.offerings) { OfferingRow(offering: $0) }
                }
            }
        }

        if !profile.portfolioTiles.isEmpty {
            BrandSection(title: "Portfolio") {
                PortfolioGrid(tiles: profile.portfolioTiles)
            }
        }

        if !profile.reviews.isEmpty {
            BrandSection(title: "Reviews", trailing: profile.stats.averageRatingLabel.map { "★ \($0)" }) {
                VStack(spacing: 10) {
                    ForEach(profile.reviews) { ReviewRow(review: $0) }
                }
            }
        }
    }

    private func headerCard(_ header: ProProfileHeader) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    BrandAvatar(name: header.displayName, avatarUrl: header.avatarUrl, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(header.displayName)
                            .font(BrandFont.display(20, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(header.professionLabel)
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textSecondary)
                        if let location = header.location {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    Spacer()
                    favoriteButton
                }

                if header.isPremium || header.isLicenseVerified || header.displayHandle != nil {
                    HStack(spacing: 8) {
                        if header.isLicenseVerified {
                            BrandPill(text: "✓ Licensed", tint: BrandColor.emerald)
                        }
                        if header.isPremium {
                            BrandPill(text: "Premium", tint: BrandColor.gold)
                        }
                        if let handle = header.displayHandle {
                            BrandPill(text: handle, tint: BrandColor.iris)
                        }
                    }
                }
            }
        }
    }

    private var favoriteButton: some View {
        Button {
            Task { await toggleFavorite() }
        } label: {
            Image(systemName: isFavorited ? "heart.fill" : "heart")
                .font(.system(size: 22))
                .foregroundStyle(isFavorited ? BrandColor.ember : BrandColor.textMuted)
        }
        .disabled(favoriteWorking)
    }

    private func toggleFavorite() async {
        guard !favoriteWorking else { return }
        favoriteWorking = true
        defer { favoriteWorking = false }

        let target = !isFavorited
        isFavorited = target  // optimistic
        do {
            let result = try await session.client.profiles.setFavorite(
                professionalId: professionalId, favorited: target
            )
            isFavorited = result.favorited
        } catch {
            isFavorited = !target  // revert on failure
        }
    }

    private func statsRow(_ stats: ProProfileStats) -> some View {
        HStack(spacing: 10) {
            if let rating = stats.averageRatingLabel {
                StatChip(value: "★ \(rating)", label: stats.reviewCountLabel)
            }
            StatChip(value: stats.completedBookingsLabel, label: "completed")
            StatChip(value: stats.favoritesLabel, label: "saves")
        }
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 80)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load() }
            } label: {
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
        .padding(.top, 70)
    }

    // MARK: - Load

    private func load() async {
        phase = .loading
        do {
            let profile = try await session.client.profiles.professional(id: professionalId)
            isFavorited = profile.isFavoritedByMe
            phase = .loaded(profile)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }
}

// MARK: - Pieces

private struct StatChip: View {
    let value: String
    let label: String

    var body: some View {
        BrandSurface {
            VStack(spacing: 2) {
                Text(value)
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                Text(label)
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OfferingRow: View {
    let offering: ProOffering

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(offering.name)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    if let price = offering.priceFromLabel {
                        Text(price)
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.accent)
                    }
                }
                if let description = offering.description, !description.isEmpty {
                    Text(description)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let duration = offering.durationMinutes {
                        BrandPill(text: "\(duration) min")
                    }
                    if offering.offersInSalon { BrandPill(text: "Salon") }
                    if offering.offersMobile { BrandPill(text: "Mobile") }
                }
            }
        }
    }
}

private struct PortfolioGrid: View {
    let tiles: [ProPortfolioTile]

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(tiles) { tile in
                ZStack(alignment: .bottomTrailing) {
                    if let url = URL(string: tile.displayUrl) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            BrandColor.bgSecondary
                        }
                    } else {
                        BrandColor.bgSecondary
                    }
                    if tile.isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

private struct ReviewRow: View {
    let review: ProReview

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(stars)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.gold)
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
                }
            }
        }
    }

    private var stars: String {
        let clamped = max(0, min(5, review.rating))
        return String(repeating: "★", count: clamped) + String(repeating: "☆", count: 5 - clamped)
    }
}