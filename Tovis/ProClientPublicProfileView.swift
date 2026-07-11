// The client's PUBLIC creator profile, shown from the pro client chart's
// "public profile" view toggle — the native counterpart of the web
// `/pro/clients/[id]?view=public` branch (which renders the exact same
// `loadPublicClientProfileByClientId` data through `PublicProfileView`). Loaded
// lazily from GET /pro/clients/{id}/public-profile. The pro views it read-only:
// avatar · @handle · bio · follower/following/looks counts · published-looks
// grid — no follow control (web passes `followMode="hidden"`). A null profile is
// the "no public profile yet" empty state; a 404 (route not deployed) falls back
// to a web pointer.
//
// The profile render itself lives in the shared `PublicClientProfileContent`
// (mode `.hidden` here), which the standalone `/u/{handle}` viewer
// (`PublicClientViewerView`) reuses with an interactive follow control — the
// native mirror of the web's shared `PublicProfileView`.
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

    var body: some View {
        Group {
            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                    .padding(.vertical, 40)
            case let .loaded(profile):
                PublicClientProfileContent(profile: profile, followMode: .hidden)
            case .empty:
                emptyState
            case .unavailable:
                webPointer
            case let .failed(message):
                failedState(message)
            }
        }
        .task { if case .loading = phase { await load() } }
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
