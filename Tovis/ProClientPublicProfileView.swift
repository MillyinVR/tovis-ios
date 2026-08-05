// The client's PUBLIC creator profile, shown from the pro client chart's
// "public profile" view toggle — the native counterpart of the web
// `/pro/clients/[id]?view=public` branch (which renders the exact same
// `loadPublicClientProfileByClientId` data through `PublicProfileView`). Loaded
// lazily from GET /pro/clients/{id}/public-profile. The pro views it read-only:
// avatar · @handle · bio · follower/following/looks counts · published-looks
// grid — no follow control (web passes `followMode="hidden"`).
//
// A null profile is the "no public profile yet" empty state.
//
// 🔴 A 404 used to be read as "the route isn't deployed yet" and answered with
// "This client's public profile is viewable on the web for now." Both halves
// were wrong. The route HAS been deployed since #825, so a 404 never meant
// that — it meant the server REFUSED, because the route was gated on the full
// chart assert. So the pro most likely to open this screen (one past their
// 30-day chart window) was told the feature didn't exist, about a page they
// could load in Safari signed out. The gate is the CONTACT tier now, so the
// refusal only reaches a pro with no relationship at all — and the copy says
// what actually happened instead of pointing at the web.
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
        /// The server refused: this pro has no relationship with this client, so
        /// it will not confirm the client id exists. Reachable only from a stale
        /// deep-link, since the chart this screen lives in refuses first.
        case refused
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
            case .refused:
                refusedState
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

    /// Deliberately says nothing about whether this client exists or has a
    /// profile — the server refused precisely so it wouldn't confirm either.
    private var refusedState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not available").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("You don't have access to this client.")
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
            // 404 = the server refused to confirm this client exists (no
            // relationship). Not an error the pro can retry their way out of, so
            // it gets its own honest state rather than "Try again".
            if case let .server(status, _, _) = error, status == 404 {
                phase = .refused
            } else {
                phase = .failed(error.userMessage)
            }
        } catch {
            phase = .failed("Couldn’t load this client’s public profile.")
        }
    }
}
