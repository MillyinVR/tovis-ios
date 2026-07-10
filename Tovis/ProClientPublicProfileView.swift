// The client's PUBLIC creator profile, shown from the pro client chart's
// "public profile" view toggle — the native counterpart of the web
// `/pro/clients/[id]?view=public` branch (which renders the exact same
// `loadPublicClientProfileByClientId` data through `PublicProfileView`). Loaded
// lazily from GET /pro/clients/{id}/public-profile. The pro views it read-only:
// avatar · @handle · bio · follower/following/looks counts · published-looks
// grid — no follow control (web passes `followMode="hidden"`). A null profile is
// the "no public profile yet" empty state; a 404 (route not deployed) falls back
// to a web pointer. Increment 3 of the pro private-client-view parity; the shared
// view also seeds the A2 `/u/[handle]` public-client viewer.
import SwiftUI
import TovisKit

struct ProClientPublicProfileView: View {
    @Environment(SessionModel.self) private var session
    let clientId: String

    private enum Phase {
        case loading
        case loaded(ProClientPublicProfile)
        /// The route answered but the client has no public profile / handle.
        case empty
        /// The route 404'd — not yet deployed. Fall back to a web pointer.
        case unavailable
        case failed(String)
    }
    @State private var phase: Phase = .loading
    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                    .padding(.vertical, 40)
            case let .loaded(profile):
                loaded(profile)
            case .empty:
                emptyState
            case .unavailable:
                webPointer
            case let .failed(message):
                failedState(message)
            }
        }
        .task { if case .loading = phase { await load() } }
        .mediaFullscreenCover($viewingMedia)
    }

    // MARK: - Loaded content

    private func loaded(_ profile: ProClientPublicProfile) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(profile)
            looksSection(profile.looks)
        }
    }

    private func header(_ profile: ProClientPublicProfile) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    BrandAvatar(name: profile.handle, avatarUrl: profile.avatarUrl, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName)
                            .font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text("Public creator profile")
                            .font(BrandFont.mono(9)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                }
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                }
                HStack(spacing: 10) {
                    statTile("\(profile.counts.followers)", "Followers")
                    statTile("\(profile.counts.following)", "Following")
                    statTile("\(profile.counts.looks)", "Looks")
                }
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
            Text(label.uppercased()).font(BrandFont.mono(8)).tracking(0.6).foregroundStyle(BrandColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(BrandColor.bgPrimary).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func looksSection(_ looks: [ProClientPublicLook]) -> some View {
        BrandSection(title: "Public looks", trailing: looks.isEmpty ? nil : "\(looks.count)") {
            if looks.isEmpty {
                Text("No public looks yet.").font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    ForEach(looks) { look in
                        Button {
                            guard let url = look.imageUrl else { return }
                            viewingMedia = FullscreenMedia.remote(id: look.id, urlString: url, isVideo: false)
                        } label: {
                            lookTile(look)
                        }
                        .buttonStyle(.plain)
                        .disabled(look.imageUrl == nil)
                    }
                }
            }
        }
    }

    private func lookTile(_ look: ProClientPublicLook) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                BrandColor.bgSecondary
                if let url = look.imageUrl, let parsed = URL(string: url) {
                    AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { ProgressView().tint(BrandColor.accent) }
                }
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.system(size: 8)).foregroundStyle(.white)
                    Text("\(look.saveCount)").font(BrandFont.mono(8)).foregroundStyle(.white)
                }
                .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.5)).clipShape(Capsule())
                .padding(6)
            }
            .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(look.name).font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.textSecondary).lineLimit(1)
        }
    }

    // MARK: - Fallback / empty states

    private var emptyState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("No public profile yet").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("This client hasn't made a public profile yet.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private var webPointer: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("Public profile").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("This client's public profile is viewable on the web for now.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: - Load

    private func load() async {
        do {
            if let profile = try await session.client.proClients.publicProfile(clientId: clientId) {
                phase = .loaded(profile)
            } else {
                // The route answered with `profile: null` — the client has no
                // public profile. Show the empty state, not an error.
                phase = .empty
            }
        } catch let error as APIError {
            // 404 = the route isn't deployed yet; keep the graceful "view on web"
            // pointer rather than a hard error.
            if case let .server(status, _, _) = error, status == 404 {
                phase = .unavailable
            } else {
                phase = .failed(error.userMessage)
            }
        } catch {
            phase = .failed("Couldn’t load this client’s public profile.")
        }
    }
}
