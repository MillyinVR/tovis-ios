// Pro data-migration wizard — the **clients import** step (increment 2), the
// native counterpart of the web `/pro/migrate/clients` flow
// (app/pro/migrate/clients/MigrateClientsClient.tsx). Same four phases:
//   upload → map columns → preview the dedupe → commit
// Pick a CSV with `.fileImporter`, parse it on-device (CsvParser, PapaParse
// parity), auto-guess the column mapping, POST to the existing
// /pro/migrate/clients/preview + /commit routes, and only import the rows the pro
// keeps. Import is silent — upsertProClient never messages a client.
//
// Pushed from ProMigrateView's footer. Both routes 404 while ENABLE_PRO_MIGRATION
// is off, but the pro only reaches here from a loaded (flag-on) entry screen; a
// stray 404 still surfaces a friendly "not switched on" message.
import SwiftUI
import TovisKit
import UniformTypeIdentifiers

struct ProMigrateClientsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case upload
        case mapping(headers: [String], rows: [[String: String]])
        case preview(rows: [[String: String]], mapping: ClientImportMapping, preview: ClientImportPreviewResponse)
        case done(ClientImportCommitSummary)
    }

    @State private var step: Step = .upload
    @State private var isPickingFile = false
    /// The mapping-step selection (logical field → chosen CSV header).
    @State private var mappingSelection: [ClientImportField: String] = [:]
    /// Row indices the pro is skipping — seeded with the non-importable rows, then
    /// toggled by the preview list. Sent as `excludeIndices` on commit (web parity).
    @State private var excluded: Set<Int> = []
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .upload:
                    uploadStep
                case let .mapping(headers, rows):
                    mappingStep(headers: headers, rows: rows)
                case let .preview(rows, mapping, preview):
                    previewStep(rows: rows, mapping: mapping, preview: preview)
                case let .done(summary):
                    doneStep(summary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Import clients")
        .navigationBarTitleDisplayMode(.large)
        .tint(BrandColor.accent)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in handlePick(result) }
    }

    // MARK: - Upload

    private var uploadStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Bring your client list over",
                subtitle: "Upload a CSV of your contacts. You’ll map the columns, preview the matches, and only import what you choose."
            )
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    bullet("A header row, then one client per line")
                    bullet("First and last name are required")
                    bullet("Email or phone lets us de-duplicate against your book")
                    bullet("Importing never messages your clients — they stay quiet until you book them")
                }
            }
            if let errorMessage { errorBanner(errorMessage) }
            Button { isPickingFile = true } label: { primaryLabel("Choose a CSV file") }
                .buttonStyle(.plain)
        }
    }

    // MARK: - Map columns

    private func mappingStep(headers: [String], rows: [[String: String]]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Match your columns",
                subtitle: "We guessed from your headers — fix anything that’s off. \(rowCountLabel(rows.count)) found."
            )
            VStack(spacing: 10) {
                ForEach(ClientImportField.allCases, id: \.self) { field in
                    mappingRow(field: field, headers: headers)
                }
            }
            if let errorMessage { errorBanner(errorMessage) }
            VStack(spacing: 10) {
                Button { Task { await runPreview(rows: rows) } } label: {
                    primaryLabel(busy ? "Checking…" : "Preview import")
                }
                .buttonStyle(.plain)
                .disabled(!mappingValid || busy)
                .opacity(mappingValid && !busy ? 1 : 0.5)
                secondaryButton("Choose a different file") { resetToUpload() }
            }
        }
    }

    private var mappingValid: Bool { ClientImportMapping(selection: mappingSelection) != nil }

    private func mappingRow(field: ClientImportField, headers: [String]) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(field.label)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if field.isRequired {
                            Text("required")
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.accent)
                        }
                    }
                    Text(mappingSelection[field] ?? "Not mapped")
                        .font(BrandFont.body(13))
                        .foregroundStyle(mappingSelection[field] != nil ? BrandColor.textSecondary : BrandColor.textMuted)
                }
                Spacer()
                Menu {
                    if !field.isRequired {
                        Button("Don’t import") { mappingSelection[field] = nil }
                    }
                    // Index-keyed so duplicate header names don't collide.
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Button(header) { mappingSelection[field] = header }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Change")
                            .font(BrandFont.body(13, .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(BrandColor.accent)
                }
            }
        }
    }

    // MARK: - Preview

    private func previewStep(
        rows: [[String: String]],
        mapping: ClientImportMapping,
        preview: ClientImportPreviewResponse
    ) -> some View {
        let included = preview.rows.filter { $0.importable && !excluded.contains($0.index) }.count
        return VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Review before importing",
                subtitle: "Toggle off anyone you’d rather skip. Rows missing a name or contact can’t be imported."
            )
            previewStats(preview.summary, included: included)
            VStack(spacing: 10) {
                ForEach(preview.rows) { row in previewRow(row) }
            }
            if let errorMessage { errorBanner(errorMessage) }
            VStack(spacing: 10) {
                Button { Task { await runCommit(rows: rows, mapping: mapping) } } label: {
                    primaryLabel(busy ? "Importing…" : "Import \(clientCountLabel(included))")
                }
                .buttonStyle(.plain)
                .disabled(included == 0 || busy)
                .opacity(included > 0 && !busy ? 1 : 0.5)
                secondaryButton("Start over") { resetToUpload() }
            }
        }
    }

    private func previewStats(_ summary: ClientImportPreviewSummary, included: Int) -> some View {
        HStack(spacing: 8) {
            statPill("\(included)", "to import", BrandColor.accent)
            statPill("\(summary.existing)", "already in book", BrandColor.iris)
            statPill("\(summary.needsAttention)", "need info", BrandColor.gold)
        }
    }

    private func previewRow(_ row: ClientImportPreviewRow) -> some View {
        let importable = row.importable
        let isIncluded = importable && !excluded.contains(row.index)
        return BrandSurface(tint: importable ? BrandColor.bgSurface : BrandColor.ember.opacity(0.06)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.displayName)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(row.contactLine ?? "No contact info")
                        .font(BrandFont.body(13))
                        .foregroundStyle(row.contactLine == nil ? BrandColor.textMuted : BrandColor.textSecondary)
                    matchChip(row)
                }
                Spacer()
                if importable {
                    Toggle("", isOn: Binding(
                        get: { isIncluded },
                        set: { on in
                            if on { excluded.remove(row.index) } else { excluded.insert(row.index) }
                        }
                    ))
                    .labelsHidden()
                    .tint(BrandColor.accent)
                } else {
                    Text("Can’t import")
                        .font(BrandFont.mono(11))
                        .foregroundStyle(BrandColor.ember)
                }
            }
        }
    }

    private func matchChip(_ row: ClientImportPreviewRow) -> some View {
        let style = matchChipStyle(row)
        return Text(style.text)
            .font(BrandFont.mono(11))
            .foregroundStyle(style.tint)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(style.tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func matchChipStyle(_ row: ClientImportPreviewRow) -> (text: String, tint: Color) {
        switch row.kind {
        case .existing: return ("Already in your book", BrandColor.accent)
        case .new: return ("New client", BrandColor.textMuted)
        case .missingInfo, .none: return (issueLabel(row.issues), BrandColor.gold)
        }
    }

    private func issueLabel(_ issues: [String]) -> String {
        if issues.contains("MISSING_NAME") { return "Needs a name" }
        if issues.contains("MISSING_CONTACT") { return "Needs email or phone" }
        if issues.contains("INVALID_EMAIL") || issues.contains("INVALID_PHONE") { return "Check contact info" }
        return "Needs info"
    }

    // MARK: - Done

    private func doneStep(_ summary: ClientImportCommitSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: summary.imported > 0 ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(summary.imported > 0 ? BrandColor.emerald : BrandColor.textMuted)
                Text(doneHeadline(summary))
                    .font(BrandFont.display(22, .medium))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Your clients are in your book. They stay quiet until you book them — nothing was sent.")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            BrandSurface {
                VStack(spacing: 10) {
                    doneStat("Imported", summary.imported, BrandColor.emerald)
                    doneStat("Skipped", summary.skipped, BrandColor.textMuted)
                    if summary.failed > 0 {
                        doneStat("Couldn’t import", summary.failed, BrandColor.ember)
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

    private func doneHeadline(_ s: ClientImportCommitSummary) -> String {
        s.imported == 0 ? "Nothing imported" : "\(clientCountLabel(s.imported)) imported"
    }

    // MARK: - File pick + parse

    private func handlePick(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case let .failure(error):
            errorMessage = "Couldn’t open that file. \(error.localizedDescription)"
        case let .success(urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = decodeText(data) else {
                    errorMessage = "That file isn’t readable text. Export a plain CSV and try again."
                    return
                }
                let table = CsvParser.parse(text)
                guard !table.isEmpty else {
                    errorMessage = "That CSV looks empty — it needs a header row and at least one client."
                    return
                }
                mappingSelection = guessClientImportMapping(headers: table.headers)
                excluded = []
                step = .mapping(headers: table.headers, rows: table.rows)
            } catch {
                errorMessage = "Couldn’t read that file. \(error.localizedDescription)"
            }
        }
    }

    private func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Network

    private func runPreview(rows: [[String: String]]) async {
        guard let mapping = ClientImportMapping(selection: mappingSelection), !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let preview = try await session.client.proMigration.previewClientImport(rows: rows, mapping: mapping)
            // Seed excluded with the non-importable rows (web parity).
            excluded = Set(preview.rows.filter { !$0.importable }.map(\.index))
            step = .preview(rows: rows, mapping: mapping, preview: preview)
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error)
        } catch {
            errorMessage = "Couldn’t check your list just now. Please try again."
        }
    }

    private func runCommit(rows: [[String: String]], mapping: ClientImportMapping) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let result = try await session.client.proMigration.commitClientImport(
                rows: rows,
                mapping: mapping,
                excludeIndices: Array(excluded).sorted()
            )
            step = .done(result.summary)
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error)
        } catch {
            errorMessage = "Couldn’t finish importing. Please try again."
        }
    }

    private func migrationErrorMessage(_ error: APIError) -> String {
        if case .server(404, _, _) = error {
            return "Importing isn’t switched on for your account yet."
        }
        return error.userMessage
    }

    // MARK: - Helpers

    private func resetToUpload() {
        excluded = []
        mappingSelection = [:]
        errorMessage = nil
        step = .upload
    }

    private func rowCountLabel(_ n: Int) -> String { "\(n) row\(n == 1 ? "" : "s")" }
    private func clientCountLabel(_ n: Int) -> String { "\(n) client\(n == 1 ? "" : "s")" }

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("◆ Step: clients")
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
