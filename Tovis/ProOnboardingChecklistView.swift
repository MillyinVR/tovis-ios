// Pro onboarding readiness checklist — the native counterpart to the web
// /pro/onboarding page (app/pro/onboarding/page.tsx) and the not-bookable banner
// (app/pro/ProReadinessBanner.tsx). Loads GET /api/v1/pro/readiness and, when the
// pro isn't bookable yet, lists each blocker with the same copy as web's
// PRO_BLOCKER_COPY — each linking straight to the native page that fixes it.
//
// Verification / license blockers link to the native verification screen
// (ProVerificationView); `.unknown` still renders as a non-navigating info row.
import SwiftUI
import TovisKit

// MARK: - Blocker → copy + native fix-it destination

/// The native page a blocker links to. `nil` (unknown blocker) renders as a
/// non-navigating info row.
private enum ProReadinessFix {
    case services
    case locations
    case workingHours
    case payment
    case verification
}

/// One row in the checklist: web-parity label + an SF Symbol + optional native
/// fix-it destination. `id` is the blocker's raw value so it stays stable/keyed.
private struct ProReadinessChecklistItem: Identifiable {
    let id: String
    let label: String
    let icon: String
    let fix: ProReadinessFix?
}

private func checklistItem(for blocker: ProReadinessBlocker) -> ProReadinessChecklistItem {
    // Labels are copied verbatim from web's PRO_BLOCKER_COPY so both platforms
    // read identically.
    switch blocker {
    case .noActiveOffering:
        return .init(id: blocker.rawValue, label: "Add at least one active service offering.", icon: "scissors", fix: .services)
    case .offeringMissingSalonPriceOrDuration:
        return .init(id: blocker.rawValue, label: "Add salon pricing and duration to salon services.", icon: "scissors", fix: .services)
    case .offeringMissingMobilePriceOrDuration:
        return .init(id: blocker.rawValue, label: "Add mobile pricing and duration to mobile services.", icon: "scissors", fix: .services)
    case .noBookableLocation:
        return .init(id: blocker.rawValue, label: "Add or publish at least one bookable location.", icon: "mappin.and.ellipse", fix: .locations)
    case .salonMissingAddress:
        return .init(id: blocker.rawValue, label: "Add a valid address to your salon or suite location.", icon: "mappin.and.ellipse", fix: .locations)
    case .mobileMissingBaseConfig:
        return .init(id: blocker.rawValue, label: "Add your mobile base postal code and service radius.", icon: "mappin.and.ellipse", fix: .locations)
    case .locationMissingTimezone:
        return .init(id: blocker.rawValue, label: "Add a valid timezone to every bookable location.", icon: "mappin.and.ellipse", fix: .locations)
    case .locationMissingGeo:
        return .init(id: blocker.rawValue, label: "Add a map location to every bookable location.", icon: "mappin.and.ellipse", fix: .locations)
    case .locationMissingWorkingHours:
        return .init(id: blocker.rawValue, label: "Add working hours for every bookable location.", icon: "clock", fix: .workingHours)
    case .stripeNotReady:
        return .init(id: blocker.rawValue, label: "Finish Stripe payout setup in your payment settings.", icon: "creditcard", fix: .payment)
    case .verificationNotApproved:
        return .init(id: blocker.rawValue, label: "Finish professional verification.", icon: "checkmark.seal", fix: .verification)
    case .verificationNotBroadlyDiscoverable:
        return .init(id: blocker.rawValue, label: "Finish verification so clients can discover you.", icon: "checkmark.seal", fix: .verification)
    case .licenseExpired:
        return .init(id: blocker.rawValue, label: "Your license has expired — renew it and update your license info.", icon: "checkmark.seal", fix: .verification)
    case .unknown:
        return .init(id: blocker.rawValue, label: "Finish an outstanding setup step.", icon: "exclamationmark.circle", fix: nil)
    }
}

// MARK: - Checklist screen

struct ProOnboardingChecklistView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProReadiness)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case let .failed(message):
                    errorState(message)
                case let .loaded(readiness):
                    content(readiness)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Finish setup")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ readiness: ProReadiness) -> some View {
        let items = readiness.blockers.map(checklistItem(for:))

        if items.isEmpty {
            readyState
        } else {
            header
            VStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index)
                }
            }
            Text("Once everything is done you’ll be bookable and this list clears itself.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
                .padding(.top, 2)
        }
    }

    private var header: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("You’re almost bookable")
                    .font(BrandFont.display(20, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Clients can’t book you until these setup items are done. Knock them out in any order — each one opens the right page.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private var readyState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(BrandColor.emerald)
                    Text("You’re all set")
                        .font(BrandFont.display(18, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
                Text("Your setup is complete — clients can book you.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ProReadinessChecklistItem, index: Int) -> some View {
        if item.fix != nil {
            NavigationLink {
                destination(item.fix!)
            } label: {
                rowCard(item, index: index, navigates: true)
            }
            .buttonStyle(.plain)
        } else {
            rowCard(item, index: index, navigates: false)
        }
    }

    private func rowCard(_ item: ProReadinessChecklistItem, index: Int, navigates: Bool) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(BrandFont.body(12, .heavy))
                    .foregroundStyle(BrandColor.amber)
                    .frame(width: 26, height: 26)
                    .background(BrandColor.amber.opacity(0.12), in: Circle())
                    .overlay(Circle().stroke(BrandColor.amber.opacity(0.35), lineWidth: 1))

                Image(systemName: item.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(width: 22)

                Text(item.label)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if navigates {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ fix: ProReadinessFix) -> some View {
        switch fix {
        case .services: ProOfferingsView()
        case .locations: ProLocationsView()
        case .workingHours: ProWorkingHoursView()
        case .payment: ProPaymentSettingsView()
        case .verification: ProVerificationView()
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
        .padding(.top, 60)
    }

    private func load() async {
        do {
            let readiness = try await session.client.proReadiness.readiness()
            phase = .loaded(readiness)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your setup checklist.")
        }
    }
}

// MARK: - Not-bookable banner

/// Compact readiness banner for the pro home — the native equivalent of web's
/// `ProReadinessBanner`. Loads its own readiness and renders nothing while
/// loading, on failure, or once the pro is bookable; otherwise a tappable card
/// that pushes the checklist. Place inside a `NavigationStack`.
struct ProReadinessBanner: View {
    @Environment(SessionModel.self) private var session

    @State private var readiness: ProReadiness?

    var body: some View {
        Group {
            if let readiness, !readiness.isReady, !readiness.blockers.isEmpty {
                NavigationLink {
                    ProOnboardingChecklistView()
                } label: {
                    card(blockerCount: readiness.blockers.count)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
        }
        .task { await load() }
        .onChange(of: session.refreshTick) { Task { await load() } }
    }

    private func card(blockerCount: Int) -> some View {
        BrandSurface(tint: BrandColor.amber.opacity(0.12)) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(BrandColor.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You’re not bookable yet")
                        .font(BrandFont.body(14, .heavy))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(blockerCount == 1
                         ? "1 setup item left — finish it so clients can book you."
                         : "\(blockerCount) setup items left — finish them so clients can book you.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer(minLength: 8)
                Text("Finish")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(BrandColor.accent, in: Capsule())
            }
        }
    }

    private func load() async {
        readiness = try? await session.client.proReadiness.readiness()
    }
}
