// The client's "Payment methods" settings screen — a native port of web
// app/client/(gated)/settings/ClientPaymentMethodsSettings.tsx. Lists the cards
// saved for no-show / late-cancellation fees, adds one via the Stripe iOS SDK's
// PaymentSheet (over a server SetupIntent), and removes one.
//
// The whole card-on-file surface is dark behind the backend
// ENABLE_NO_SHOW_PROTECTION flag (the prod default is OFF), so every route 404s
// while it's off. This screen degrades that to a calm "not available yet" state
// rather than an error — it lights up automatically once the flag flips.
//
// Add-card flow (mirrors web): POST setup-intent → init the Stripe SDK with the
// server-vended publishable key → present PaymentSheet against the SetupIntent
// client secret → on completion POST the setupIntentId to persist the card →
// reload the authoritative list. TovisKit owns the networking
// (PaymentMethodsService); the Stripe UI lives here in the app target.
import SwiftUI
import UIKit
import StripePaymentSheet
import TovisKit

struct PaymentMethodsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ClientPaymentMethod])
        /// The backend flag is off (setup-intent / list route 404s).
        case unavailable
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// A transient action error, shown as a banner without blowing away the list.
    @State private var actionError: String?
    /// The card currently being removed (disables its Remove button).
    @State private var busyRemoveId: String?
    /// True while the SetupIntent is being created (before the sheet appears).
    @State private var isStartingAdd = false
    /// The card the user tapped Remove on, pending confirmation.
    @State private var pendingRemove: ClientPaymentMethod?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro

                if let actionError {
                    banner(actionError)
                }

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 40)
                case .unavailable:
                    unavailableState
                case let .failed(message):
                    errorState(message)
                case let .loaded(cards):
                    cardList(cards)
                    addCardButton
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Payment methods")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .confirmationDialog(
            "Remove this card?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemove
        ) { card in
            Button("Remove card", role: .destructive) { Task { await remove(card) } }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Sections

    private var intro: some View {
        Text("Saving a card lets a pro charge a no-show or late-cancellation fee according to their booking policy. Your full card number is never stored here — only a secure token and the last four digits.")
            .font(BrandFont.body(12))
            .foregroundStyle(BrandColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func cardList(_ cards: [ClientPaymentMethod]) -> some View {
        if cards.isEmpty {
            Text("No cards saved yet.")
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(spacing: 10) {
                ForEach(cards) { card in row(card) }
            }
        }
    }

    private func row(_ card: ClientPaymentMethod) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(Self.formatBrand(card.brand))
                            .font(BrandFont.body(15, .bold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("•••• \(card.last4 ?? "––––")")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                        if card.isDefault { defaultBadge }
                    }
                    if let expiry = Self.formatExpiry(card.expMonth, card.expYear) {
                        Text("exp \(expiry)")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                Spacer(minLength: 0)

                Button {
                    pendingRemove = card
                } label: {
                    Group {
                        if busyRemoveId == card.id {
                            ProgressView().tint(BrandColor.ember)
                        } else {
                            Text("Remove").font(BrandFont.body(13, .semibold))
                        }
                    }
                    .foregroundStyle(BrandColor.ember)
                    .padding(.vertical, 7).padding(.horizontal, 14)
                    .overlay(Capsule().stroke(BrandColor.ember.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(busyRemoveId == card.id)
            }
        }
    }

    private var defaultBadge: some View {
        Text("Default")
            .font(BrandFont.mono(9)).tracking(0.5)
            .foregroundStyle(BrandColor.emerald)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(BrandColor.emerald.opacity(0.14))
            .clipShape(Capsule())
    }

    private var addCardButton: some View {
        Button {
            Task { await startAddCard() }
        } label: {
            Group {
                if isStartingAdd {
                    HStack(spacing: 8) {
                        ProgressView().tint(BrandColor.onAccent)
                        Text("Starting…").font(BrandFont.body(15, .semibold))
                    }
                } else {
                    Text("Add a card").font(BrandFont.body(15, .semibold))
                }
            }
            .foregroundStyle(BrandColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isStartingAdd)
        .padding(.top, 4)
    }

    // MARK: - States

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "creditcard").font(.system(size: 26)).foregroundStyle(BrandColor.textMuted)
            Text("Not available yet")
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("Saved payment methods aren’t turned on for your account yet. Check back soon.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 32)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { phase = .loading; await load() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 48)
    }

    private func banner(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BrandColor.ember.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    private func load() async {
        do {
            let cards = try await session.client.paymentMethods.list()
            phase = .loaded(cards)
        } catch let e as APIError {
            if Self.isDarkFlag(e) {
                phase = .unavailable
            } else {
                phase = .failed(e.userMessage)
            }
        } catch {
            phase = .failed("Couldn’t load your saved cards.")
        }
    }

    @MainActor
    private func startAddCard() async {
        guard !isStartingAdd else { return }
        isStartingAdd = true
        actionError = nil
        defer { isStartingAdd = false }

        do {
            let intent = try await session.client.paymentMethods.createSetupIntent()
            guard let key = intent.publishableKey, !key.isEmpty else {
                actionError = "Card payments aren’t available right now."
                return
            }
            // Init the SDK with the server-vended key so it always matches the
            // backend Stripe mode (test vs live).
            STPAPIClient.shared.publishableKey = key

            var config = PaymentSheet.Configuration()
            // merchantDisplayName defaults to the app's display name — no hardcode.
            config.returnURL = "tovis://stripe-redirect"
            let sheet = PaymentSheet(setupIntentClientSecret: intent.clientSecret, configuration: config)

            guard let presenter = Self.topViewController() else {
                actionError = "Couldn’t open the card form."
                return
            }
            sheet.present(from: presenter) { result in
                Task { await handleSheetResult(result, setupIntentId: intent.setupIntentId) }
            }
        } catch let e as APIError {
            if Self.isDarkFlag(e) {
                phase = .unavailable
            } else {
                actionError = e.userMessage
            }
        } catch {
            actionError = "Couldn’t start saving your card."
        }
    }

    @MainActor
    private func handleSheetResult(_ result: PaymentSheetResult, setupIntentId: String) async {
        switch result {
        case .completed:
            // The SetupIntent succeeded on Stripe; persist + make it the default.
            do {
                _ = try await session.client.paymentMethods.confirmCard(setupIntentId: setupIntentId)
                await load() // reflect the server's authoritative list
            } catch let e as APIError {
                actionError = e.userMessage
            } catch {
                actionError = "Your card was saved but the list didn’t refresh — pull to try again."
            }
        case .canceled:
            break // user backed out
        case let .failed(error):
            actionError = error.localizedDescription
        }
    }

    private func remove(_ card: ClientPaymentMethod) async {
        guard busyRemoveId == nil else { return }
        busyRemoveId = card.id
        actionError = nil
        pendingRemove = nil
        do {
            try await session.client.paymentMethods.remove(id: card.id)
            await load() // authoritative (default may have been promoted)
        } catch let e as APIError {
            actionError = e.userMessage
        } catch {
            actionError = "Couldn’t remove that card."
        }
        busyRemoveId = nil
    }

    // MARK: - Helpers

    /// True when the backend card-on-file flag is off — every route 404s.
    private static func isDarkFlag(_ error: APIError) -> Bool {
        if case let .server(status, _, _) = error, status == 404 { return true }
        return false
    }

    /// The top-most presented view controller to hang the Stripe sheet off of.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: - Web-parity formatting (mirrors ClientPaymentMethodsSettings.tsx)

    /// "Card" when unknown, else the brand with a capitalized first letter
    /// (e.g. "visa" → "Visa") — matches the web `formatBrand`.
    static func formatBrand(_ brand: String?) -> String {
        guard let brand, !brand.isEmpty else { return "Card" }
        return brand.prefix(1).uppercased() + brand.dropFirst()
    }

    /// "MM/YY" or nil when the expiry is unknown — matches web `formatExpiry`.
    static func formatExpiry(_ month: Int?, _ year: Int?) -> String? {
        guard let month, let year, month > 0, year > 0 else { return nil }
        let mm = String(format: "%02d", month)
        let yy = String(format: "%02d", year % 100)
        return "\(mm)/\(yy)"
    }
}
