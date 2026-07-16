// ClaimView.swift
//
// Native counterpart of the web /claim/[token] page. Reached when a client taps a
// pro-sent claim link (`https://tovis.app/claim/<token>`) with the app installed —
// RootView presents this over whatever is showing (signed-out + cold-launch safe).
//
// Reads the booking context via ClaimService, then renders the same state machine
// the web page does (`ClaimScreenState`): a signed-out viewer routes into client
// signup in CLAIM mode (prefilled + intent=CLAIM_INVITE + inviteToken) so the
// backend adopts the pro's existing unclaimed profile, while an already-signed-in
// client claims in-app via ClaimService.acceptClaim — no signup detour.

import SwiftUI
import TovisKit

struct ClaimView: View {
    let token: String

    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case loaded(ClaimContextResponse)
        /// The token doesn't resolve / is malformed (route 404).
        case notFound
        case failed(String)
    }
    @State private var phase: Phase = .loading

    /// The server's answer to an accept attempt; nil until the viewer claims.
    /// Takes precedence over the loaded context when resolving what to render.
    @State private var outcome: ClaimAcceptOutcome?
    @State private var isClaiming = false
    /// Only for the genuinely exceptional (401 / transport / unknown code) —
    /// every documented failure is an `outcome`, not an error.
    @State private var claimError: String?

    /// Web resolves the viewer server-side from its cookie session; native
    /// already knows the same facts locally, so no wire field is needed.
    /// `.loading` counts as signed-out: the claim cover can open on a cold launch
    /// before bootstrap finishes, and offering signup is the safe default (the
    /// state re-resolves the moment bootstrap lands).
    private var viewer: ClaimViewer {
        switch session.state {
        case .loading, .signedOut: return .signedOut
        case .needsVerification: return .needsVerification
        case .signedIn: return session.activeRole == .pro ? .professional : .client
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                            .padding(.top, 70)
                    case let .loaded(context):
                        loadedContent(context)
                    case .notFound:
                        emptyState(
                            title: "Link not found",
                            message: "This claim link is no longer valid. If you think this is a mistake, ask your professional to resend it."
                        )
                    case let .failed(message):
                        emptyState(title: "Something went wrong", message: message)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
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
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(BrandColor.bgSurface, in: Circle())
                    .overlay(Circle().stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text(topBarTitle)
                .font(BrandFont.body(15))
                .fontWeight(.semibold)
                .foregroundStyle(BrandColor.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "Your booking" once a booking-bearing claim loads, else a generic title.
    private var topBarTitle: String {
        if case let .loaded(context) = phase, context.booking == nil {
            return "Claim your history"
        }
        return "Your booking"
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedContent(_ context: ClaimContextResponse) -> some View {
        claimHeaderCard(context)

        switch ClaimScreenState.resolve(
            contextState: context.state,
            viewer: viewer,
            outcome: outcome
        ) {
        case .signedOut:
            readyActions(context)

        case .readyToClaim:
            claimActions(context)

        case let .claimed(bookingId):
            claimedCard(bookingId: bookingId)

        case .needsVerification:
            statusCard(
                title: "Verify your account first",
                message: "Verify your account, then come right back here to finish the claim."
            ) {
                // Dismissing reveals PhoneVerificationView — RootView already
                // shows it for a `.needsVerification` session; this cover is
                // simply on top of it.
                secondaryButton("Verify and continue") { dismiss() }
                    .padding(.top, 6)
            }

        case .notAClient:
            statusCard(
                title: "This link must be claimed from a client account",
                message: "You’re signed in as a professional. Sign in with your client account to claim this history."
            )

        case .alreadyClaimed:
            statusCard(
                title: "This history is already claimed",
                message: "The client identity behind this link has already been claimed. If this is your account, sign in to continue."
            )

        case .revoked:
            statusCard(
                title: "This claim link is no longer available",
                message: "This link was turned off. Your booking history is still safe, but this link can’t be used anymore."
            )

        case .clientMismatch:
            statusCard(
                title: "You’re signed into a different client account",
                message: "This claim link belongs to a different client identity than the one you’re signed in as. Sign in with the right client account to finish claiming this history."
            )

        case .conflict:
            statusCard(
                title: "We couldn’t finish the claim",
                message: "Nothing was deleted. Please try again — if this keeps happening, contact support."
            ) {
                secondaryButton("Try again") { Task { await claim() } }
                    .padding(.top, 6)
            }

        case .notFound:
            emptyState(
                title: "Link not found",
                message: "This claim link is no longer valid. If you think this is a mistake, ask your professional to resend it."
            )
        }
    }

    /// Signed-in verified client: claim in-app, no signup detour.
    @ViewBuilder
    private func claimActions(_ context: ClaimContextResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This will attach this history to your client identity.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let claimError {
                Text(claimError)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await claim() }
            } label: {
                Group {
                    if isClaiming {
                        ProgressView().tint(BrandColor.onAccent)
                    } else {
                        Text("Claim this history")
                            .font(BrandFont.body(15))
                            .fontWeight(.semibold)
                            .foregroundStyle(BrandColor.onAccent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(BrandColor.accent))
            }
            .buttonStyle(.plain)
            .disabled(isClaiming)
        }
    }

    /// Post-claim success. Mirrors web's redirect target: the booking when the
    /// claim carried one, else the client home.
    @ViewBuilder
    private func claimedCard(bookingId: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard(
                title: "History claimed",
                message: "This history is now attached to your client identity."
            )

            if let bookingId {
                secondaryButton("Go to booking") {
                    session.handlePushDeepLink(href: "/client/bookings/\(bookingId)")
                    dismiss()
                }
            } else {
                secondaryButton("Go to your account") { dismiss() }
            }
        }
    }

    private func claimHeaderCard(_ context: ClaimContextResponse) -> some View {
        let booking = context.booking
        return VStack(alignment: .leading, spacing: 10) {
            Text(headerTitle(context))
                .font(BrandFont.display(22, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let invitedName = context.invitedName, !invitedName.isEmpty {
                Text(
                    booking != nil
                        ? "This booking was created for \(invitedName)."
                        : "This profile was created for \(invitedName)."
                )
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }

            // Appointment + location only exist for a booking-bearing claim.
            if let booking {
                if let when = formattedAppointment(booking.scheduledFor, timeZone: booking.timeZone) {
                    detailRow(label: "Booking", value: when)
                }
                if let location = booking.locationLabel, !location.isEmpty {
                    detailRow(label: "Location", value: location)
                }
            }

            if let email = context.invitedEmail, !email.isEmpty {
                Text("Email on file: \(email)")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
            if let phone = context.invitedPhone, !phone.isEmpty {
                Text("Phone on file: \(phone)")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(BrandColor.bgSurface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1))
    }

    /// Booking-bearing: "{service} with {pro}". Booking-less: a pro/brand-level
    /// claim header (mirrors the web /claim page).
    private func headerTitle(_ context: ClaimContextResponse) -> String {
        if let booking = context.booking {
            return "\(booking.serviceName ?? "Service") with \(booking.professionalName)"
        }
        if let pro = context.professionalName, !pro.isEmpty {
            return "Claim your history with \(pro)"
        }
        return "Claim your client history"
    }

    /// Ready-state lead copy (mirrors the web /claim page's three-way branch).
    /// Only a booking has something to "manage"; only a pro-attributed invite has
    /// a professional to "message" — a cold self-serve orphan (booking-less AND
    /// pro-less) has neither, so keep that copy about the history alone.
    private func readyLeadCopy(_ context: ClaimContextResponse) -> String {
        if context.booking != nil {
            return "Create a free account to manage this booking, message your professional, and keep your history together."
        }
        if let pro = context.professionalName, !pro.isEmpty {
            return "Create a free account to keep this history attached to your identity and message your professional."
        }
        return "Create a free account to attach this history to your identity and keep everything together."
    }

    @ViewBuilder
    private func readyActions(_ context: ClaimContextResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(readyLeadCopy(context))
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                ClientSignupView(claimContext: makeClaimContext(context))
            } label: {
                Text("Create client account to claim")
                    .font(BrandFont.body(15))
                    .fontWeight(.semibold)
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(BrandColor.accent))
            }
            .buttonStyle(.plain)

            secondaryButton("I already have an account") { dismiss() }
        }
    }

    // MARK: - Small building blocks

    /// The screen's non-primary button chrome, shared by every branch.
    private func secondaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(14))
                .fontWeight(.semibold)
                .foregroundStyle(BrandColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(BrandColor.bgSurface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
            Text(value)
                .font(BrandFont.body(13))
                .fontWeight(.semibold)
                .foregroundStyle(BrandColor.textPrimary)
        }
    }

    private func statusCard(
        title: String,
        message: String,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandFont.body(15))
                .fontWeight(.semibold)
                .foregroundStyle(BrandColor.textPrimary)
            Text(message)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // No padding wrapper here: a modifier applied to `EmptyView()` stops
            // being SwiftUI's zero-subview special case and would allocate the
            // VStack's spacing around a card that draws nothing. Callers that
            // pass actions add their own top padding.
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(BrandColor.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BrandColor.amber.opacity(0.30), lineWidth: 1))
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(BrandFont.display(18, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(message)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 12)
    }

    // MARK: - Data

    private func makeClaimContext(_ context: ClaimContextResponse) -> ClientSignupClaimContext {
        let parts = (context.invitedName ?? "")
            .split(separator: " ", maxSplits: 1)
            .map(String.init)
        return ClientSignupClaimContext(
            inviteToken: token,
            firstName: parts.first ?? "",
            lastName: parts.count > 1 ? parts[1] : "",
            email: context.invitedEmail ?? "",
            phone: context.invitedPhone ?? ""
        )
    }

    private func formattedAppointment(_ iso: String?, timeZone: String) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso)
            ?? {
                let fallback = ISO8601DateFormatter()
                fallback.formatOptions = [.withInternetDateTime]
                return fallback.date(from: iso)
            }()
        guard let date else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        return formatter.string(from: date)
    }

    private func load() async {
        do {
            if let context = try await session.client.claim.claimContext(token: token) {
                phase = .loaded(context)
            } else {
                phase = .notFound
            }
        } catch {
            phase = .failed("Please try again in a moment.")
        }
    }

    /// Accept the claim as the signed-in client. Every documented failure comes
    /// back as an `outcome` the screen renders as its own state; only the
    /// exceptional (401 / transport / an unknown code) surfaces as an error, and
    /// it keeps the button available so a retry is always possible.
    private func claim() async {
        guard !isClaiming else { return }
        isClaiming = true
        claimError = nil
        // Clear the previous answer so a retry that throws lands back on the
        // claim button (which renders `claimError`) rather than on a stale
        // conflict card that would swallow the message.
        outcome = nil
        defer { isClaiming = false }

        do {
            outcome = try await session.client.claim.acceptClaim(token: token)
        } catch let error as APIError {
            claimError = error.userMessage
        } catch {
            claimError = "Something went wrong. Please try again."
        }
    }
}
