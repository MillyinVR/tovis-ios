// Pro data-migration wizard — the **services import** step (increment 3), the
// native counterpart of the web `/pro/migrate/services` flow
// (app/pro/migrate/services/MigrateServicesClient.tsx). Same three phases:
//   upload → map (match + tune raises) → done
// Pick a CSV with `.fileImporter`, parse it on-device (CsvParser + the web's
// column heuristic) into { name, price, durationMinutes } rows, POST to the
// existing /pro/migrate/services/preview route (the server runs the fuzzy match),
// let the pro fix mappings and tune the raise for any below-minimum price, then
// commit through /commit. Below-minimum prices are grandfathered and ramped up to
// the catalog minimum (ServicePriceRamp) — the same math the server persists.
// Commit is silent — the import-mode offering write never messages a client.
//
// Pushed from ProMigrateView's footer. Both routes 404 while ENABLE_PRO_MIGRATION
// is off, but the pro only reaches here from a loaded (flag-on) entry screen; a
// stray 404 still surfaces a friendly "not switched on" message.
import SwiftUI
import TovisKit
import UniformTypeIdentifiers

struct ProMigrateServicesView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case upload, map, done }

    private enum RowStatus { case ok, priceGrace, needsAttention }

    /// The mutable per-row view-model (mirrors the web `ServiceMapRow` state): a CSV
    /// row's source values, the catalog service it maps to, and its derived status.
    private struct ServiceRow: Identifiable {
        let rowId: String
        let sourceName: String
        let sourcePrice: Double?
        let sourceDurationMinutes: Double?
        var mappedServiceId: String?
        var salonPrice: Double?
        var salonDurationMinutes: Double?
        var status: RowStatus
        var id: String { rowId }
    }

    @State private var phase: Phase = .upload
    @State private var catalog: [ServiceCatalogOption] = []
    @State private var catalogById: [String: ServiceCatalogOption] = [:]
    @State private var rows: [ServiceRow] = []
    /// Per-row raise overrides, keyed by rowId (default = 10% every 10 weeks).
    @State private var rampConfigs: [String: ServiceRampConfig] = [:]
    @State private var result: ServiceImportCommitSummary?
    @State private var isPickingFile = false
    @State private var busy = false
    @State private var errorMessage: String?
    /// Captured once so the raise schedule dates are stable across redraws.
    @State private var today = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .upload:
                    uploadStep
                case .map:
                    mapStep
                case .done:
                    doneStep
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Import services")
        .navigationBarTitleDisplayMode(.large)
        .tint(BrandColor.accent)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: migrationSpreadsheetContentTypes,
            allowsMultipleSelection: true
        ) { result in handlePick(result) }
    }

    // MARK: - Upload

    private var uploadStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Bring your service menu over",
                subtitle: "Upload your services as CSV or Excel — several files at once are fine. We’ll match each one to the catalog, and you review the prices before anything is added."
            )
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    bullet("A header row, then one service per line — CSV or Excel")
                    bullet("Columns for the service name, price, and duration")
                    bullet("We match each name to the catalog — you can fix any that are off")
                    bullet("Prices under the platform minimum are grandfathered, then eased up over time")
                }
            }
            if let errorMessage { errorBanner(errorMessage) }
            Button { isPickingFile = true } label: { primaryLabel(busy ? "Reading…" : "Choose a file") }
                .buttonStyle(.plain)
                .disabled(busy)
        }
    }

    // MARK: - Map

    private var mapStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Match your menu",
                subtitle: "We matched each service to the catalog. Fix anything that’s off — every service needs a match before you import."
            )
            statPills
            VStack(spacing: 10) {
                ForEach(rows) { row in serviceRowCard(row) }
            }
            raiseSection
            if let errorMessage { errorBanner(errorMessage) }
            VStack(spacing: 10) {
                Button { Task { await runCommit() } } label: {
                    primaryLabel(busy ? "Adding…" : commitLabel)
                }
                .buttonStyle(.plain)
                .disabled(!canCommit || busy)
                .opacity(canCommit && !busy ? 1 : 0.5)
                secondaryButton("Choose a different file") { resetToUpload() }
            }
        }
    }

    private var counts: (willAdd: Int, raises: Int, needsAttention: Int) {
        var willAdd = 0, raises = 0, needsAttention = 0
        for row in rows {
            if row.status == .ok || row.status == .priceGrace { willAdd += 1 }
            if row.status == .priceGrace { raises += 1 }
            if row.status == .needsAttention { needsAttention += 1 }
        }
        return (willAdd, raises, needsAttention)
    }

    private var canCommit: Bool {
        let c = counts
        return c.needsAttention == 0 && c.willAdd > 0
    }

    private var commitLabel: String {
        let n = counts.willAdd
        return "Add \(n) service\(n == 1 ? "" : "s")"
    }

    private var statPills: some View {
        let c = counts
        return HStack(spacing: 8) {
            statPill("\(c.willAdd)", "to add", BrandColor.accent)
            statPill("🎉 \(c.raises)", "raises unlocked", BrandColor.iris)
            statPill("\(c.needsAttention)", "need a match", c.needsAttention > 0 ? BrandColor.gold : BrandColor.textMuted)
        }
    }

    private func serviceRowCard(_ row: ServiceRow) -> some View {
        let mapped = row.mappedServiceId.flatMap { catalogById[$0] }
        return BrandSurface(tint: row.status == .needsAttention ? BrandColor.gold.opacity(0.06) : BrandColor.bgSurface) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.sourceName)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(sourceLine(row))
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                    if let mapped {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(money(row.salonPrice ?? mapped.minPrice))
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(row.status == .priceGrace ? BrandColor.gold : BrandColor.textPrimary)
                            Text("min \(money(mapped.minPrice))")
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                }
                catalogMenu(row)
                statusChip(row)
            }
        }
    }

    private func catalogMenu(_ row: ServiceRow) -> some View {
        Menu {
            ForEach(catalogSections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.options) { option in
                        Button(option.name) { selectService(rowId: row.rowId, serviceId: option.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                Text(mappedLabel(row))
                    .font(BrandFont.body(13, .semibold))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(BrandColor.accent)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(BrandColor.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func statusChip(_ row: ServiceRow) -> some View {
        let style = statusStyle(row.status)
        return Text(style.text)
            .font(BrandFont.mono(11))
            .foregroundStyle(style.tint)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(style.tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func statusStyle(_ status: RowStatus) -> (text: String, tint: Color) {
        switch status {
        case .ok: return ("Ready to add", BrandColor.emerald)
        case .priceGrace: return ("Below minimum — raise planned", BrandColor.gold)
        case .needsAttention: return ("Pick a match to add", BrandColor.ember)
        }
    }

    // MARK: - Raise section

    private struct GraceRow: Identifiable {
        let rowId: String
        let serviceName: String
        let grandfathered: Int
        let minPrice: Int
        var id: String { rowId }
    }

    private var graceRows: [GraceRow] {
        rows.compactMap { row -> GraceRow? in
            guard row.status == .priceGrace,
                  let mapped = row.mappedServiceId.flatMap({ catalogById[$0] }),
                  let price = row.salonPrice else { return nil }
            let name = mapped.name
            return GraceRow(
                rowId: row.rowId,
                serviceName: name,
                grandfathered: Int(price.rounded()),
                minPrice: Int(mapped.minPrice.rounded())
            )
        }
    }

    @ViewBuilder
    private var raiseSection: some View {
        let grace = graceRows
        if !grace.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("PLAN YOUR RAISES")
                    .font(BrandFont.mono(11)).tracking(0.8)
                    .foregroundStyle(BrandColor.textMuted)
                Text("\(grace.count) service\(grace.count == 1 ? " is" : "s are") below the platform minimum. Existing clients keep their price and step up gently — new clients pay the minimum right away.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                ForEach(grace) { row in
                    RaiseConfigCard(
                        serviceName: row.serviceName,
                        grandfathered: row.grandfathered,
                        minPrice: row.minPrice,
                        today: today,
                        config: rampConfigs[row.rowId] ?? .default
                    ) { config in
                        rampConfigs[row.rowId] = config
                    }
                }
            }
        }
    }

    // MARK: - Done

    @ViewBuilder
    private var doneStep: some View {
        if let summary = result {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: summary.created > 0 ? "checkmark.circle.fill" : "info.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(summary.created > 0 ? BrandColor.emerald : BrandColor.textMuted)
                    Text(summary.created == 0 ? "Nothing added" : "\(summary.created) service\(summary.created == 1 ? "" : "s") added")
                        .font(BrandFont.display(22, .medium))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Your menu is live in your business profile. Nothing was sent to your clients.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                BrandSurface {
                    VStack(spacing: 10) {
                        doneStat("Added", summary.created, BrandColor.emerald)
                        doneStat("Skipped", summary.skipped, BrandColor.textMuted)
                        if summary.rampsCreated > 0 {
                            doneStat("🎉 Raises unlocked", summary.rampsCreated, BrandColor.iris)
                        }
                    }
                }
                VStack(spacing: 10) {
                    Button { dismiss() } label: { primaryLabel("Done") }
                        .buttonStyle(.plain)
                    secondaryButton("Import another file") { resetToUpload() }
                }
            }
        }
    }

    // MARK: - File pick + parse

    private func handlePick(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case let .failure(error):
            errorMessage = "Couldn’t open that file. \(error.localizedDescription)"
        case let .success(urls):
            guard !urls.isEmpty else { return }
            Task { await loadPicked(urls: urls) }
        }
    }

    /// Read + parse the picked files (CSV on-device; Excel via the server parse
    /// endpoint), then concatenate the menu rows. Columns are detected per file,
    /// so a multi-file pick works even when layouts differ (e.g. Vagaro's
    /// one-spreadsheet-per-stylist service exports).
    private func loadPicked(urls: [URL]) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let tables = try await SpreadsheetFileLoader.loadAll(urls: urls, using: session.client.proMigration)
            let menuRows = tables.flatMap { parseServiceMenuRows(headers: $0.headers, rows: $0.rows) }
            guard !menuRows.isEmpty else {
                errorMessage = "We couldn’t find any named services in that file. Check the header row and try again."
                return
            }
            busy = false // runPreview takes over the busy flag (it guards on it)
            await runPreview(menuRows)
        } catch SpreadsheetFileLoader.LoadError.emptyTable {
            errorMessage = "That file looks empty — it needs a header row and at least one service."
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error)
        } catch {
            errorMessage = "Couldn’t read that file. \(error.localizedDescription)"
        }
    }

    // MARK: - Network

    private func runPreview(_ menuRows: [ServiceMenuInputRow]) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let preview = try await session.client.proMigration.previewServiceImport(rows: menuRows)
            let byId = Dictionary(preview.catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            catalog = preview.catalog
            catalogById = byId
            rows = preview.rows.map { buildRow($0, byId: byId) }
            rampConfigs = [:]
            phase = .map
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error)
        } catch {
            errorMessage = "Couldn’t match your menu just now. Please try again."
        }
    }

    private func runCommit() async {
        guard !busy, canCommit else { return }
        let decisions = rows.compactMap { row -> ServiceImportDecision? in
            guard let serviceId = row.mappedServiceId,
                  row.status == .ok || row.status == .priceGrace else { return nil }
            let ramp = rampConfigs[row.rowId] ?? .default
            return ServiceImportDecision(
                serviceId: serviceId,
                offersInSalon: true,
                offersMobile: false,
                salonPrice: row.salonPrice,
                salonDurationMinutes: row.salonDurationMinutes,
                mobilePrice: nil,
                mobileDurationMinutes: nil,
                ramp: ramp
            )
        }
        guard !decisions.isEmpty else { return }

        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let response = try await session.client.proMigration.commitServiceImport(decisions: decisions)
            result = response.summary
            phase = .done
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error)
        } catch {
            errorMessage = "Couldn’t add your services. Please try again."
        }
    }

    private func migrationErrorMessage(_ error: APIError) -> String {
        if case .server(404, _, _) = error {
            return "Importing isn’t switched on for your account yet."
        }
        return error.userMessage
    }

    // MARK: - Row derivation (web `buildRow` / `handleSelectService` parity)

    private func buildRow(_ preview: ServicePreviewRow, byId: [String: ServiceCatalogOption]) -> ServiceRow {
        let mapped = preview.bestServiceId.flatMap { byId[$0] }
        let price = preview.sourcePrice ?? mapped?.minPrice
        let duration = preview.sourceDurationMinutes ?? mapped?.defaultDurationMinutes

        let status: RowStatus
        let mappedId: String?
        if let mapped, let serviceId = preview.bestServiceId {
            if let price, price < mapped.minPrice {
                status = .priceGrace
            } else {
                status = .ok
            }
            mappedId = serviceId
        } else {
            status = .needsAttention
            mappedId = nil
        }

        return ServiceRow(
            rowId: String(preview.index),
            sourceName: preview.sourceName,
            sourcePrice: preview.sourcePrice,
            sourceDurationMinutes: preview.sourceDurationMinutes,
            mappedServiceId: mappedId,
            salonPrice: price,
            salonDurationMinutes: duration,
            status: status
        )
    }

    private func selectService(rowId: String, serviceId: String) {
        guard let mapped = catalogById[serviceId] else { return }
        rows = rows.map { row in
            guard row.rowId == rowId else { return row }
            var updated = row
            let price = row.salonPrice ?? row.sourcePrice ?? mapped.minPrice
            let duration = row.salonDurationMinutes ?? row.sourceDurationMinutes ?? mapped.defaultDurationMinutes
            updated.mappedServiceId = serviceId
            updated.salonPrice = price
            updated.salonDurationMinutes = duration
            updated.status = price < mapped.minPrice ? .priceGrace : .ok
            return updated
        }
    }

    // MARK: - Catalog grouping

    private struct CatalogSection: Identifiable {
        let name: String
        let options: [ServiceCatalogOption]
        var id: String { name }
    }

    private var catalogSections: [CatalogSection] {
        let groups = Dictionary(grouping: catalog) { $0.categoryName ?? "Other" }
        return groups.keys.sorted().map { key in
            CatalogSection(name: key, options: groups[key]!.sorted { $0.name < $1.name })
        }
    }

    // MARK: - Helpers

    private func resetToUpload() {
        rows = []
        catalog = []
        catalogById = [:]
        rampConfigs = [:]
        result = nil
        errorMessage = nil
        phase = .upload
    }

    private func mappedLabel(_ row: ServiceRow) -> String {
        if let id = row.mappedServiceId, let name = catalogById[id]?.name { return name }
        return "Choose a match"
    }

    private func sourceLine(_ row: ServiceRow) -> String {
        var parts: [String] = []
        if let price = row.sourcePrice { parts.append(money(price)) }
        if let duration = row.sourceDurationMinutes { parts.append("\(Int(duration.rounded())) min") }
        return parts.isEmpty ? "No price in your file" : parts.joined(separator: " · ")
    }

    private func money(_ value: Double) -> String { "$\(Int(value.rounded()))" }

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("◆ Step: services")
                .font(BrandFont.mono(11)).tracking(0.6)
                .foregroundStyle(BrandColor.accent)
            Text(title)
                .font(BrandFont.display(24, .medium))
                .foregroundStyle(BrandColor.textPrimary)
            Text(subtitle)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private func primaryLabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(16, .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(BrandColor.onAccent)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(BrandColor.accent)
                .padding(.top, 2)
            Text(text)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statPill(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(BrandFont.display(20, .medium))
                .foregroundStyle(tint)
            Text(label)
                .font(BrandFont.mono(10))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func doneStat(_ label: String, _ value: Int, _ tint: Color) -> some View {
        HStack {
            Text(label)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
            Spacer()
            Text("\(value)")
                .font(BrandFont.body(16, .semibold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Raise configurator (one below-minimum service)

/// The price-grace editor for a single service — mirrors the web `RaiseConfigurator`
/// (RaisePlanSection.tsx). The pro tunes how fast the grandfathered price steps up
/// to the platform minimum (percentage vs dollars, and cadence), never gentler than
/// the 10%-every-10-weeks floor. Shows the resulting step-by-step schedule.
private struct RaiseConfigCard: View {
    let serviceName: String
    let grandfathered: Int
    let minPrice: Int
    let today: Date
    let onChange: (ServiceRampConfig) -> Void

    @State private var mode: ServiceRampStepMode
    @State private var stepValue: Double
    @State private var cadence: Double

    init(
        serviceName: String,
        grandfathered: Int,
        minPrice: Int,
        today: Date,
        config: ServiceRampConfig,
        onChange: @escaping (ServiceRampConfig) -> Void
    ) {
        self.serviceName = serviceName
        self.grandfathered = grandfathered
        self.minPrice = minPrice
        self.today = today
        self.onChange = onChange
        _mode = State(initialValue: config.stepMode)
        let floor = ServicePriceRamp.floorStepValue(mode: config.stepMode, currentPrice: grandfathered)
        _stepValue = State(initialValue: Double(max(floor, config.stepValue)))
        _cadence = State(initialValue: Double(ServicePriceRamp.clampCadenceWeeks(config.cadenceWeeks)))
    }

    private var stepLower: Int { ServicePriceRamp.floorStepValue(mode: mode, currentPrice: grandfathered) }
    private var stepUpper: Int {
        let computed = mode == .pct ? 50 : max(stepLower, minPrice - grandfathered)
        return max(stepLower + 1, computed)
    }
    private var stepStride: Double { mode == .pct ? 5 : 1 }

    private var config: ServiceRampConfig {
        ServiceRampConfig(
            stepMode: mode,
            stepValue: ServicePriceRamp.clampStepValue(mode: mode, value: Int(stepValue.rounded()), currentPrice: grandfathered),
            cadenceWeeks: ServicePriceRamp.clampCadenceWeeks(Int(cadence.rounded()))
        )
    }

    private var schedule: [ServicePriceRamp.RampStep] {
        let cfg = config
        return ServicePriceRamp.buildRampSchedule(
            grandfatheredPrice: grandfathered, minPrice: minPrice,
            mode: cfg.stepMode, stepValue: cfg.stepValue, cadenceWeeks: cfg.cadenceWeeks,
            start: today
        )
    }

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(serviceName)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("$\(grandfathered) → $\(minPrice)")
                        .font(BrandFont.mono(12))
                        .foregroundStyle(BrandColor.gold)
                }

                Picker("", selection: $mode) {
                    Text("Percent").tag(ServiceRampStepMode.pct)
                    Text("Dollars").tag(ServiceRampStepMode.usd)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, newMode in
                    stepValue = Double(ServicePriceRamp.floorStepValue(mode: newMode, currentPrice: grandfathered))
                    onChange(config)
                }

                sliderRow(
                    label: mode == .pct ? "Raise by \(Int(stepValue.rounded()))% each step" : "Raise by $\(Int(stepValue.rounded())) each step",
                    value: $stepValue,
                    range: Double(stepLower)...Double(stepUpper),
                    stride: stepStride
                ) { onChange(config) }

                sliderRow(
                    label: "Every \(Int(cadence.rounded())) weeks",
                    value: $cadence,
                    range: 2...10,
                    stride: 1
                ) { onChange(config) }

                metrics
                scheduleList
            }
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        stride: Double,
        onEdit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
            Slider(value: value, in: range, step: stride)
                .tint(BrandColor.accent)
                .onChange(of: value.wrappedValue) { _, _ in onEdit() }
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            metricRow("New clients pay", "$\(minPrice)", BrandColor.textPrimary)
            metricRow("Current clients start at", "$\(grandfathered)", BrandColor.gold)
            if let last = schedule.last {
                metricRow("Reaches $\(minPrice) by", last.date.formatted(.dateTime.month(.abbreviated).day().year()), BrandColor.emerald)
            }
        }
        .padding(.top, 2)
    }

    private func metricRow(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack {
            Text(label)
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
            Spacer()
            Text(value)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var scheduleList: some View {
        let steps = schedule
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps) { step in
                    HStack(spacing: 8) {
                        Text("Step \(step.index)")
                            .font(BrandFont.mono(10))
                            .foregroundStyle(BrandColor.textMuted)
                        Text(step.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                        Spacer()
                        Text("$\(step.from) → $\(step.to)")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}
