// Native port of the web Settings → "Get better matches" card
// (app/client/(gated)/settings/ClientSelfProfileSettings.tsx), backed by
// GET/PATCH /api/v1/client/self-profile via ClientSelfProfileService. Lets a client
// describe their hair, skin, and category interests with tap-to-toggle chips — the
// explicit, user-entered signals that seed the personalized feed (spec §6.6). Every
// field is optional; tapping a selected chip clears it.
//
// Selections are a local draft; Save PATCHes the whole profile (each field sent as a
// value or an explicit null; interests as a full array) and re-seeds from the
// server's normalized response, exactly like the web card.
import SwiftUI
import TovisKit

struct ClientPersonalizationView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading

    /// Draft selections.
    @State private var fields: [SelfProfileFieldKey: String] = [:]
    @State private var interests: Set<String> = []
    /// Last-saved snapshot, for dirty-tracking.
    @State private var savedFields: [SelfProfileFieldKey: String] = [:]
    @State private var savedInterests: Set<String> = []

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
        .navigationTitle("Better matches")
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

                interestsSection

                ForEach(SelfProfileCatalog.questions) { question in
                    questionSection(question)
                }

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
        VStack(alignment: .leading, spacing: 6) {
            Text("Get better matches")
                .font(BrandFont.display(18, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Tell us about your hair, skin, and what you’re into — every field is optional, and everything here only comes from you. Tap a selected chip to clear it.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var interestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("What are you into?")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(SelfProfileCatalog.interestOptions) { option in
                    SelfProfileChip(
                        label: option.label,
                        selected: interests.contains(option.value)
                    ) { toggleInterest(option.value) }
                }
            }
        }
    }

    private func questionSection(_ question: SelfProfileQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(question.label)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(question.options) { option in
                    SelfProfileChip(
                        label: option.label,
                        selected: fields[question.key] == option.value
                    ) { toggleField(question.key, option.value) }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(BrandColor.textSecondary)
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

    // MARK: - Selection

    private func toggleField(_ key: SelfProfileFieldKey, _ value: String) {
        if fields[key] == value {
            fields[key] = nil
        } else {
            fields[key] = value
        }
        banner = nil
    }

    private func toggleInterest(_ value: String) {
        if interests.contains(value) {
            interests.remove(value)
        } else {
            interests.insert(value)
        }
        banner = nil
    }

    private var dirty: Bool {
        fields != savedFields || interests != savedInterests
    }

    /// Interests in catalog order (stable + matches the server's normalized output).
    private var interestsToSend: [String] {
        SelfProfileCatalog.interestOptions
            .map(\.value)
            .filter { interests.contains($0) }
    }

    // MARK: - Load / save

    private func load() async {
        phase = .loading
        do {
            let profile = try await session.client.clientSelfProfile.profile()
            apply(profile)
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Failed to load your preferences.")
        }
    }

    private func apply(_ profile: ClientSelfProfile?) {
        var nextFields: [SelfProfileFieldKey: String] = [:]
        if let profile {
            for key in SelfProfileFieldKey.allCases {
                if let value = profile.value(for: key) { nextFields[key] = value }
            }
        }
        let nextInterests = Set(profile?.interests ?? [])

        fields = nextFields
        interests = nextInterests
        savedFields = nextFields
        savedInterests = nextInterests
    }

    private func save() async {
        guard !savingState, dirty else { return }
        savingState = true
        banner = nil
        defer { savingState = false }

        do {
            let updated = try await session.client.clientSelfProfile.update(
                fields: fields,
                interests: interestsToSend
            )
            apply(updated)
            banner = Banner(kind: .success, text: "Preferences updated.")
        } catch let error as APIError {
            banner = Banner(kind: .error, text: error.userMessage)
        } catch {
            banner = Banner(kind: .error, text: "Failed to save.")
        }
    }
}

/// A tap-to-toggle chip for the self-profile selectors. Selected uses the accent-tinted
/// fill/border established by the signup mode pills (ProSignupView.modePill).
private struct SelfProfileChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(selected ? BrandColor.textPrimary : BrandColor.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(selected ? BrandColor.accent.opacity(0.14) : BrandColor.bgSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        selected ? BrandColor.accent.opacity(0.4) : BrandColor.textMuted.opacity(0.18),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
