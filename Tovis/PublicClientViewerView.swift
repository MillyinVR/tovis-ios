// The public creator profile as a standalone, handle-addressed screen — the
// native counterpart of the web `/u/[handle]` page. Reached by tapping a client
// author's @handle in the Looks feed (mirrors the web, where the handle links to
// `/u/{handle}`). Loads GET /api/v1/u/{handle} and renders the shared
// `PublicClientProfileContent` with an interactive follow control:
//
//   • owner viewing self        → `.own`    (no control; `viewer.isOwn`)
//   • signed-in client (other)  → `.client` (Follow toggle; POST /client/follow/{handle})
//   • pro / non-client viewer   → `.hidden` (no control — the server can't follow)
//
// A 404 (handle doesn't resolve or the client isn't public) is a plain
// "not found" empty state, not an error — the route is public-read and always
// deployed, so 404 never means "not available yet".
import SwiftUI
import TovisKit

struct PublicClientViewerView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let handle: String

    private enum Phase {
        case loading
        case loaded(ProClientPublicProfile)
        /// The handle doesn't resolve or the client isn't public.
        case notFound
        case failed(String)
    }
    @State private var phase: Phase = .loading

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                            .padding(.top, 70)
                    case let .loaded(profile):
                        PublicClientProfileContent(
                            profile: profile,
                            followMode: followMode(for: profile),
                            toggleFollow: {
                                try await session.client.publicClient.toggleFollow(handle: profile.handle)
                            }
                        )
                    case .notFound:
                        notFoundState
                    case let .failed(message):
                        failedState(message)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .background(BrandColor.bgPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(BrandColor.bgSurface, in: Circle())
                    .overlay(Circle().stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text(titleText)
                .font(BrandFont.display(18, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var titleText: String {
        if case let .loaded(profile) = phase { return profile.displayName }
        return "@\(handle)"
    }

    // MARK: - Empty / failed states

    private var notFoundState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("Profile not found").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("This creator doesn’t have a public profile.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
        }
        .padding(.top, 20)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: - Follow mode + load

    /// Mirrors the web `page.tsx` gate: only a signed-in CLIENT (who isn't the
    /// owner) can follow; a pro/admin viewer sees no control.
    private func followMode(for profile: ProClientPublicProfile) -> PublicProfileFollowMode {
        if profile.viewer.isOwn { return .own }
        if session.currentUser?.role == .client {
            return .client(initialFollowing: profile.viewer.following)
        }
        return .hidden
    }

    private func load() async {
        phase = .loading
        do {
            if let profile = try await session.client.publicClient.profile(handle: handle) {
                phase = .loaded(profile)
            } else {
                phase = .notFound
            }
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this profile.")
        }
    }
}
