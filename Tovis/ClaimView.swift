// ClaimView.swift
//
// Native counterpart of the web /claim/[token] page. Reached when a client taps a
// pro-sent claim link (`https://tovis.app/claim/<token>`) with the app installed —
// RootView presents this over whatever is showing (signed-out + cold-launch safe).
//
// Reads the booking context via ClaimService, then routes into client signup in
// CLAIM mode (prefilled + intent=CLAIM_INVITE + inviteToken) so the backend adopts
// the pro's existing unclaimed profile and the history stays attached.

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

            Text("Your booking")
                .font(BrandFont.body(15))
                .fontWeight(.semibold)
                .foregroundStyle(BrandColor.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedContent(_ context: ClaimContextResponse) -> some View {
        bookingCard(context)

        switch context.state {
        case ClaimContextState.alreadyClaimed:
            statusCard(
                title: "This history is already claimed",
                message: "The client identity behind this link has already been claimed. If this is your account, sign in to continue."
            )
        case ClaimContextState.revoked:
            statusCard(
                title: "This claim link is no longer available",
                message: "This link was turned off. Your booking history is still safe, but this link can’t be used anymore."
            )
        default:
            readyActions(context)
        }
    }

    private func bookingCard(_ context: ClaimContextResponse) -> some View {
        let booking = context.booking
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(booking.serviceName ?? "Service") with \(booking.professionalName)")
                .font(BrandFont.display(22, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let invitedName = context.invitedName, !invitedName.isEmpty {
                Text("This booking was created for \(invitedName).")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }

            if let when = formattedAppointment(booking.scheduledFor, timeZone: booking.timeZone) {
                detailRow(label: "Booking", value: when)
            }
            if let location = booking.locationLabel, !location.isEmpty {
                detailRow(label: "Location", value: location)
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

    @ViewBuilder
    private func readyActions(_ context: ClaimContextResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a free account to manage this booking, message your professional, and keep your history together.")
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

            Button { dismiss() } label: {
                Text("I already have an account")
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
    }

    // MARK: - Small building blocks

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

    private func statusCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandFont.body(15))
                .fontWeight(.semibold)
                .foregroundStyle(BrandColor.textPrimary)
            Text(message)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
}
