// Self-serve account deletion — the native twin of the web
// `/pro/account/delete` and `/client/settings` panels, required by App Store
// guideline 5.1.1(v).
//
// Role-agnostic, and rendered from BOTH workspace settings hubs. The wire is
// role-agnostic too (`/me/account-deletion`), so one screen is the whole
// feature — a pro-only screen would ship a compliance hole for anyone who only
// ever uses the client tab.
//
// The screen never deletes anything itself. It opens a grace window that a
// server-side sweep executes once the window closes, so a mis-tap stays
// recoverable right up to the scheduled date.
//
// Every piece of copy that describes POLICY — the window length, and every
// reason the account can't be deleted yet — comes from the server rather than
// being restated here. Two clients restating the same policy is how they end up
// promising different things.
import SwiftUI
import TovisKit

struct DeleteAccountView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var status: AccountDeletionStatus?
    @State private var confirming = false
    @State private var confirmEmail = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)

                case let .failed(message):
                    BrandSurface {
                        Text(message)
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.ember)
                    }

                case .loaded:
                    if let pending = status?.pendingRequest {
                        scheduledState(pending)
                    } else {
                        requestState
                    }
                }

                if let error {
                    Text(error)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                }
            }
            .padding(16)
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        Text("Permanently close your account and remove your personal information.")
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textSecondary)
    }

    // MARK: - Nothing scheduled yet

    @ViewBuilder
    private var requestState: some View {
        let blockers = status?.eligibility.blockers ?? []

        if !blockers.isEmpty {
            BrandSection(title: "Before you can delete") {
                BrandSurface(tint: BrandColor.ember.opacity(0.10)) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(blockers) { blocker in
                            // The server's own words. Rebuilding this copy from
                            // `code` would mean re-implementing the eligibility
                            // rules on the client.
                            Text(blocker.message)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        BrandSurface {
            Text(whatHappensCopy)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if confirming {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type your email address to confirm.")
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)

                TextField("you@example.com", text: $confirmEmail)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .font(BrandFont.body(15))
                    .padding(12)
                    .background(BrandColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1)
                    )

                destructiveButton(
                    title: busy ? "Scheduling…" : "Delete my account",
                    disabled: busy || confirmEmail.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    Task { await submit() }
                }

                Button("Cancel") {
                    confirming = false
                    confirmEmail = ""
                    error = nil
                }
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .disabled(busy)
            }
        } else {
            destructiveButton(
                title: "Delete account",
                disabled: !(status?.eligibility.eligible ?? false)
            ) {
                confirming = true
            }
        }
    }

    private var whatHappensCopy: String {
        let days = status?.gracePeriodDays ?? 14
        return """
        Your account closes after \(days) days. You can sign in and cancel any \
        time before then. Appointment and payment records are kept for \
        accounting and for the people you booked with, with your personal \
        details removed.
        """
    }

    // MARK: - Deletion scheduled

    private func scheduledState(_ pending: AccountDeletionRequestView) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandSurface(tint: BrandColor.ember.opacity(0.10)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DELETION SCHEDULED")
                        .font(BrandFont.mono(11))
                        .tracking(1.4)
                        .foregroundStyle(BrandColor.ember)

                    Text(
                        "Your account and personal information will be removed on "
                            + Wire.dateOnly(pending.scheduledFor)
                            + ". You can still change your mind until then."
                    )
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await cancelDeletion() }
            } label: {
                Text(busy ? "Cancelling…" : "Keep my account")
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.4), lineWidth: 1)
                    )
            }
            .disabled(busy)
        }
    }

    private func destructiveButton(
        title: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(16, .semibold))
                .foregroundStyle(BrandColor.ember)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
                )
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    // MARK: - Actions

    private func load() async {
        do {
            status = try await session.client.accountDeletion.status()
            phase = .loaded
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your account settings.")
        }
    }

    private func submit() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }

        do {
            _ = try await session.client.accountDeletion.requestDeletion(
                confirmEmail: confirmEmail.trimmingCharacters(in: .whitespaces)
            )
            confirming = false
            confirmEmail = ""
            await load()
        } catch let e as APIError {
            error = e.userMessage
            // A 409 means the obligations moved under us — an appointment was
            // booked between opening this screen and tapping Delete. Re-read so
            // the blocker list shows what actually needs settling.
            if case let .server(status, _, _) = e, status == 409 {
                await load()
            }
        } catch {
            self.error = "Couldn’t schedule the deletion. Try again."
        }
    }

    private func cancelDeletion() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }

        do {
            try await session.client.accountDeletion.cancel()
            await load()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t cancel the deletion. Try again."
        }
    }
}
