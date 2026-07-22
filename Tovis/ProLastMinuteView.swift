// Pro Last Minute — the native counterpart of the web `/pro/last-minute`, backed
// by GET /api/v1/pro/last-minute/workspace (tovis-app PR #439). Shows the
// last-minute configuration — master state, priority offer, discount tiers,
// per-day availability, per-service rules and blocked dates — and lets the pro
// EDIT it: the status/tiers/days open the "Last-minute defaults" sheet
// (PATCH settings), each service opens its eligibility rule (PATCH rules), and
// blocked dates can be added/removed (POST/DELETE blocks). The write endpoints
// already exist server-side, so this is an iOS-only editor. Lives on the
// Overview home's Last Minute tab.
import SwiftUI
import TovisKit

struct ProLastMinuteView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProLastMinuteWorkspace)
        case failed(String)
    }

    /// Which editor sheet (if any) is presented.
    private enum EditSheet: Identifiable {
        case settings(ProLastMinuteWorkspace.Settings)
        case rule(offering: ProLastMinuteWorkspace.Offering, rule: ProLastMinuteWorkspace.ServiceRule?)
        case addBlock(timeZone: String?)
        case createOpening(offerings: [ProLastMinuteWorkspace.Offering], timeZone: String?)

        var id: String {
            switch self {
            case .settings: return "settings"
            case let .rule(offering, _): return "rule-\(offering.id)"
            case .addBlock: return "addBlock"
            case .createOpening: return "createOpening"
            }
        }
    }

    @State private var phase: Phase = .loading
    @State private var activeSheet: EditSheet?
    @State private var blockPendingDelete: ProLastMinuteWorkspace.Block?
    @State private var deleting = false

    // Openings load their own list (GET /pro/openings), kept separate from the
    // workspace so neither error hides the other.
    @State private var openings: [ProOpeningDto] = []
    @State private var openingsLoading = true
    @State private var openingsError: String?
    @State private var openingPendingCancel: ProOpeningDto?
    @State private var cancelingOpening = false

    private static let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 50)
                case let .failed(message):
                    errorState(message)
                case let .loaded(workspace):
                    content(workspace)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)   // clear the raised footer
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .refreshable { await reloadAll() }
        .task {
            if case .loading = phase { await load() }
            if openingsLoading { await loadOpenings() }
        }
        .onChange(of: session.refreshTick) { Task { await reloadAll() } }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case let .settings(settings):
                ProLastMinuteSettingsSheet(settings: settings) { Task { await load() } }
            case let .rule(offering, rule):
                ProLastMinuteServiceRuleSheet(offering: offering, rule: rule) { Task { await load() } }
            case let .addBlock(timeZone):
                ProLastMinuteAddBlockSheet(
                    timeZone: TimeZone(identifier: timeZone ?? "") ?? .current,
                    defaultStart: Date()
                ) { Task { await load() } }
            case let .createOpening(offerings, timeZone):
                ProOpeningCreateSheet(
                    offerings: offerings,
                    timeZone: TimeZone(identifier: timeZone ?? "") ?? .current
                ) { Task { await loadOpenings() } }
            }
        }
        .confirmationDialog(
            "Remove this blocked range?",
            isPresented: Binding(
                get: { blockPendingDelete != nil },
                set: { if !$0 { blockPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove block", role: .destructive) { performBlockDelete() }
            Button("Cancel", role: .cancel) { blockPendingDelete = nil }
        }
        .confirmationDialog(
            "Cancel this opening?",
            isPresented: Binding(
                get: { openingPendingCancel != nil },
                set: { if !$0 { openingPendingCancel = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel opening", role: .destructive) { performOpeningCancel() }
            Button("Keep it", role: .cancel) { openingPendingCancel = nil }
        }
    }

    @ViewBuilder
    private func content(_ workspace: ProLastMinuteWorkspace) -> some View {
        let s = workspace.settings

        openingsSection(workspace)

        statusCard(s)

        Button {
            activeSheet = .settings(s)
        } label: {
            BrandSection(title: "Discount tiers") {
                BrandSurface(tint: BrandColor.bgSecondary) {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Priority offer", s.priorityOfferEnabled ? "On · \(s.priorityOfferMinutes) min" : "Off")
                        row("Night-before send", LastMinuteAnchor.label(s.tier2NightBeforeMinutes))
                        row("Day-of send", LastMinuteAnchor.label(s.tier3DayOfMinutes))
                        if let min = Wire.money(s.minCollectedSubtotal) {
                            row("Min collected subtotal", min)
                        }
                        row("Visibility", LastMinuteVisibility.from(s.defaultVisibilityMode).label)
                        editHint
                    }
                }
            }
        }
        .buttonStyle(.plain)

        BrandSection(title: "Available days") {
            availabilityRow(s)
        }

        if !workspace.offerings.isEmpty {
            BrandSection(title: "Service rules") {
                VStack(spacing: 10) {
                    ForEach(workspace.offerings) { offering in
                        serviceRuleCard(
                            offering,
                            rule: s.serviceRules.first { $0.serviceId == offering.serviceId }
                        )
                    }
                }
            }
        }

        blocksSection(workspace)
    }

    // MARK: - Openings (create / list / cancel)

    @ViewBuilder
    private func openingsSection(_ workspace: ProLastMinuteWorkspace) -> some View {
        BrandSection(
            title: "Upcoming openings",
            trailing: openings.isEmpty ? nil : "\(openings.count)"
        ) {
            VStack(spacing: 10) {
                Button {
                    activeSheet = .createOpening(
                        offerings: workspace.offerings,
                        timeZone: workspace.timeZone
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Create opening")
                    }
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(workspace.offerings.isEmpty)

                if workspace.offerings.isEmpty {
                    Text("Add an active offering before opening a last-minute slot.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                openingsList
            }
        }
    }

    @ViewBuilder
    private var openingsList: some View {
        if openingsLoading {
            HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                .padding(.vertical, 16)
        } else if let openingsError {
            BrandSurface(tint: BrandColor.bgSecondary) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(openingsError)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    Button("Try again") { Task { await loadOpenings() } }
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
        } else if openings.isEmpty {
            BrandSurface(tint: BrandColor.bgSecondary) {
                Text("No openings in the next 48 hours. Open a slot and your waitlist gets notified first.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textMuted)
            }
        } else {
            ForEach(openings) { opening in
                openingCard(opening)
            }
        }
    }

    private func openingCard(_ opening: ProOpeningDto) -> some View {
        let status = opening.status.uppercased()
        let isActive = status == "ACTIVE"
        return BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(serviceSummary(opening))
                            .font(BrandFont.body(15, .bold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(Wire.dateTime(opening.startAt, timeZone: opening.timeZone))
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                        Text("\(opening.locationType.capitalized) · \(LastMinuteVisibility.from(opening.visibilityMode).label) · \(locationSummary(opening))")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        BrandPill(text: status, tint: isActive ? BrandColor.emerald : BrandColor.textMuted)
                        Text("\(opening.recipientCount) recipient\(opening.recipientCount == 1 ? "" : "s")")
                            .font(BrandFont.body(11))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }

                if let notice = opening.visibility.noticeText {
                    visibilityNotice(notice, isFault: opening.visibility.isFault)
                }

                if let note = opening.note, !note.isEmpty {
                    Text(note)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                if !opening.tierPlans.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(opening.tierPlans) { plan in
                            tierPlanRow(plan, timeZone: opening.timeZone)
                        }
                    }
                }

                if isActive {
                    Button {
                        openingPendingCancel = opening
                    } label: {
                        Text("Cancel opening")
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.ember)
                    }
                    .buttonStyle(.plain)
                    .disabled(cancelingOpening)
                }
            }
        }
    }

    /// tovis-app F16: the opening row is alive but no client can see its time.
    /// Amber is for something the pro has to fix; the accent is for the one
    /// state that resolves itself — a claim already in flight.
    private func visibilityNotice(_ text: String, isFault: Bool) -> some View {
        let tint = isFault ? BrandColor.amber : BrandColor.accent

        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: isFault ? "eye.slash.fill" : "clock.fill")
                .font(BrandFont.body(11, .semibold))
            Text(text)
                .font(BrandFont.body(12, .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(tint)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tierPlanRow(_ plan: ProOpeningDto.TierPlan, timeZone: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(LastMinuteTierKind.label(plan.tier))
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(Wire.dateTime(plan.scheduledFor, timeZone: timeZone))
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(describeOpeningTierPlan(plan))
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                if plan.processedAt != nil {
                    Text("Processed").font(BrandFont.body(10)).foregroundStyle(BrandColor.textMuted)
                } else if plan.cancelledAt != nil {
                    Text("Cancelled").font(BrandFont.body(10)).foregroundStyle(BrandColor.textMuted)
                }
                if let lastError = plan.lastError, !lastError.isEmpty {
                    Text(lastError).font(BrandFont.body(10)).foregroundStyle(BrandColor.ember)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Unique service names joined, else a generic label (web `serviceSummary`).
    private func serviceSummary(_ opening: ProOpeningDto) -> String {
        var seen = Set<String>()
        var names: [String] = []
        for row in opening.services {
            let name = row.service.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
        }
        return names.isEmpty ? "Services" : names.joined(separator: ", ")
    }

    /// Location name / address / falling back to the location type (web `locationSummary`).
    private func locationSummary(_ opening: ProOpeningDto) -> String {
        if let name = opening.location?.name, !name.isEmpty { return name }
        if let address = opening.location?.formattedAddress, !address.isEmpty { return address }
        return opening.locationType.capitalized
    }

    private func statusCard(_ s: ProLastMinuteWorkspace.Settings) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            HStack(spacing: 12) {
                Circle()
                    .fill(s.enabled ? BrandColor.emerald : BrandColor.textMuted.opacity(0.4))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last-minute openings")
                        .font(BrandFont.body(15, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(s.enabled ? "On — eligible openings are offered automatically." : "Off")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
                Button("Edit") { activeSheet = .settings(s) }
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.accent)
            }
        }
    }

    private func availabilityRow(_ s: ProLastMinuteWorkspace.Settings) -> some View {
        let disabled = [s.disableMon, s.disableTue, s.disableWed, s.disableThu, s.disableFri, s.disableSat, s.disableSun]
        return HStack(spacing: 6) {
            ForEach(Array(Self.dayLabels.enumerated()), id: \.offset) { idx, label in
                let on = !disabled[idx]
                Text(label.uppercased())
                    .font(BrandFont.mono(9))
                    .foregroundStyle(on ? BrandColor.onAccent : BrandColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(on ? BrandColor.accent : BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func serviceRuleCard(_ offering: ProLastMinuteWorkspace.Offering, rule: ProLastMinuteWorkspace.ServiceRule?) -> some View {
        let enabled = rule?.enabled ?? false
        return Button {
            activeSheet = .rule(offering: offering, rule: rule)
        } label: {
            BrandSurface(tint: BrandColor.bgSecondary) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(offering.name)
                            .font(BrandFont.body(14, .bold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if let min = Wire.money(rule?.minCollectedSubtotal) {
                            Text("Min subtotal \(min)")
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textMuted)
                        } else if let base = Wire.money(offering.basePrice) {
                            Text("Base \(base)")
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    Spacer()
                    BrandPill(text: enabled ? "Eligible" : "Off", tint: enabled ? BrandColor.emerald : BrandColor.textMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func blocksSection(_ workspace: ProLastMinuteWorkspace) -> some View {
        let blocks = workspace.settings.blocks
        BrandSection(title: "Blocked dates", trailing: blocks.isEmpty ? nil : "\(blocks.count)") {
            VStack(spacing: 10) {
                if blocks.isEmpty {
                    BrandSurface(tint: BrandColor.bgSecondary) {
                        Text("No blocks yet.")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                } else {
                    ForEach(blocks) { block in
                        BrandSurface(tint: BrandColor.bgSecondary) {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(Wire.dateTime(block.startAt, timeZone: workspace.timeZone)) → \(Wire.dateTime(block.endAt, timeZone: workspace.timeZone))")
                                        .font(BrandFont.body(13, .semibold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    if let reason = block.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(BrandFont.body(12))
                                            .foregroundStyle(BrandColor.textMuted)
                                    }
                                }
                                Spacer()
                                Button {
                                    blockPendingDelete = block
                                } label: {
                                    Text("Remove")
                                        .font(BrandFont.body(13, .semibold))
                                        .foregroundStyle(BrandColor.ember)
                                }
                                .disabled(deleting)
                            }
                        }
                    }
                }

                Button {
                    activeSheet = .addBlock(timeZone: workspace.timeZone)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add block")
                    }
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(BrandColor.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var editHint: some View {
        HStack(spacing: 4) {
            Text("Edit defaults")
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.accent)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BrandColor.accent)
        }
        .padding(.top, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
            Spacer()
            Text(value)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
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
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func reloadAll() async {
        await load()
        await loadOpenings()
    }

    private func load() async {
        do {
            let workspace = try await session.client.proSchedule.lastMinuteWorkspace()
            phase = .loaded(workspace)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your last-minute settings.")
        }
    }

    private func loadOpenings() async {
        openingsLoading = true
        openingsError = nil
        defer { openingsLoading = false }
        do {
            openings = try await session.client.proSchedule.listOpenings()
        } catch let error as APIError {
            openingsError = error.userMessage
            openings = []
        } catch {
            openingsError = "Couldn’t load your openings."
            openings = []
        }
    }

    private func performOpeningCancel() {
        guard let opening = openingPendingCancel else { return }
        openingPendingCancel = nil
        cancelingOpening = true
        Task {
            defer { cancelingOpening = false }
            do {
                try await session.client.proSchedule.cancelOpening(id: opening.id)
            } catch {
                // Fall through to reload; a still-active opening simply reappears.
            }
            await loadOpenings()
        }
    }

    private func performBlockDelete() {
        guard let block = blockPendingDelete else { return }
        blockPendingDelete = nil
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await session.client.proSchedule.deleteLastMinuteBlock(id: block.id)
                await load()
            } catch {
                // Reload to resync; a stale row simply reappears.
                await load()
            }
        }
    }
}
