// Native port of the web Settings → Public profile card
// (app/client/(gated)/settings/ClientPublicProfileSettings.tsx), backed by
// GET/PATCH /api/v1/client/profile via ClientPublicProfileService. Lets a client
// claim an @handle, write a public bio, and opt their profile public — the identity
// that powers the public /u/{handle} viewer. When the profile is public with a
// handle, a "View public profile" link pushes the existing PublicClientViewerView
// (no duplicate render — the same screen a follower would see).
import SwiftUI
import TovisKit

struct ClientPublicProfileEditView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    private static let bioMax = 280

    @State private var phase: Phase = .loading
    /// The last-saved profile, used for dirty-tracking + the "View profile" link.
    @State private var saved: ClientPublicProfileSettings?

    @State private var handle = ""
    @State private var isPublic = false
    @State private var bio = ""

    @State private var savingState = false
    @State private var banner: Banner?

    private struct Banner: Equatable {
        enum Kind { case success, error }
        let kind: Kind
        let text: String
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().tint(BrandColor.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                errorState(message)
            case .loaded:
                form
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Public profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                intro

                if let banner {
                    Text(banner.text)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(banner.kind == .success ? BrandColor.accent : BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background((banner.kind == .success ? BrandColor.accent : BrandColor.ember).opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                handleField
                bioField
                publicToggle

                SignupPrimaryButton(
                    title: "Save",
                    isLoading: savingState,
                    isDisabled: !dirty
                ) {
                    Task { await save() }
                }
            }
            .padding(20)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Public profile")
                        .font(BrandFont.display(18, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Claim a handle and make your looks shareable on your own public profile at /u/your-handle.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer(minLength: 0)
            }

            // Mirrors the web "View profile" pill: only when the SAVED state is public
            // with a handle (an unsaved edit shouldn't link to a stale/absent page).
            if let saved, saved.isPublicProfile, let savedHandle = saved.handle, !savedHandle.isEmpty {
                NavigationLink {
                    PublicClientViewerView(handle: savedHandle)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .semibold))
                        Text("View public profile")
                            .font(BrandFont.body(13, .semibold))
                    }
                    .foregroundStyle(BrandColor.accent)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(BrandColor.accent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(BrandColor.accent.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var handleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Handle")
            HStack(spacing: 4) {
                Text("@").font(BrandFont.body(16)).foregroundStyle(BrandColor.textMuted)
                TextField("", text: $handle, prompt: Text("your-handle").foregroundStyle(BrandColor.textMuted))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    .font(BrandFont.body(16))
                    .foregroundStyle(BrandColor.textPrimary)
                    .onChange(of: handle) { _, newValue in
                        let sanitized = HandleRules.sanitizeInput(newValue)
                        if sanitized != newValue { handle = sanitized }
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
            Text("\(HandleRules.min)–\(HandleRules.max) characters · letters, numbers, hyphens.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var bioField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Bio")
            TextEditor(text: $bio)
                .frame(minHeight: 92)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
                )
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .onChange(of: bio) { _, newValue in
                    if newValue.count > Self.bioMax { bio = String(newValue.prefix(Self.bioMax)) }
                }
            Text("\(bio.count)/\(Self.bioMax)")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var publicToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Make my profile public")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(canGoPublic
                        ? "Anyone with your handle can see your public looks."
                        : "Claim a handle first to go public.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $isPublic)
                    .labelsHidden()
                    .tint(BrandColor.accent)
                    // Matches web: only lock the toggle when there's no handle AND it's
                    // currently off (so a public profile can still be turned back off).
                    .disabled(!canGoPublic && !isPublic)
            }
            .padding(.top, 4)
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
        .padding(.top, 80)
        .padding(.horizontal, 24)
    }

    // MARK: - Derived state (mirrors the web card)

    private var canGoPublic: Bool {
        !handle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var dirty: Bool {
        guard let saved else { return false }
        return handle != (saved.handle ?? "")
            || isPublic != saved.isPublicProfile
            || bio != (saved.publicBio ?? "")
    }

    // MARK: - Load / save

    private func load() async {
        phase = .loading
        do {
            let profile = try await session.client.clientPublicProfile.profile()
            apply(profile)
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Failed to load your public profile.")
        }
    }

    private func apply(_ profile: ClientPublicProfileSettings) {
        saved = profile
        handle = profile.handle ?? ""
        isPublic = profile.isPublicProfile
        bio = profile.publicBio ?? ""
    }

    private func save() async {
        guard !savingState, dirty else { return }
        savingState = true
        banner = nil
        defer { savingState = false }

        do {
            let updated = try await session.client.clientPublicProfile.updateProfile(
                handle: handle,
                isPublicProfile: isPublic,
                publicBio: bio
            )
            apply(updated)
            banner = Banner(kind: .success, text: "Public profile updated.")
        } catch let error as APIError {
            banner = Banner(kind: .error, text: error.userMessage)
        } catch {
            banner = Banner(kind: .error, text: "Failed to save.")
        }
    }
}
