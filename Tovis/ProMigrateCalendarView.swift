// Pro data-migration wizard — the **calendar import** step (increment 4), the
// native counterpart of the web `/pro/migrate/calendar` flow
// (app/pro/migrate/calendar/MigrateCalendarClient.tsx). Same three phases:
//   upload (.ics file OR read-only feed URL) → review → done
// Two ways in, converging on one preview/commit:
//   • pick an .ics with `.fileImporter` and read its raw text, OR
//   • paste a read-only "subscribe" feed URL → POST /calendar/fetch (the server
//     pulls the .ics, SSRF-guarded), then keep it synced afterwards if opted in.
// Either way the raw .ics text is shuttled to /calendar/preview (classify each
// event: booking / blocked time / client history / skipped) → the pro toggles
// off any row → /calendar/commit. The client never parses the .ics — the server
// does. Import is silent — nothing is sent to any client.
//
// Pushed from ProMigrateView's footer. All routes 404 while ENABLE_PRO_MIGRATION
// is off, but the pro only reaches here from a loaded (flag-on) entry screen; a
// stray 404 still surfaces a friendly "not switched on" message.
import SwiftUI
import TovisKit
import UniformTypeIdentifiers

struct ProMigrateCalendarView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case upload
        case review(ics: String, rows: [CalendarImportPreviewRow], syncUrl: String?)
        case done(CalendarImportCommitResponse, synced: Bool)
    }

    @State private var phase: Phase = .upload
    @State private var feedUrl = ""
    /// Keep a feed-URL source auto-syncing after import (only a URL can be synced;
    /// a file upload can't). Mirrors the web checkbox.
    @State private var keepSynced = true
    /// Event uids the pro is skipping — toggled in the review list, sent as
    /// `excludeUids` on commit (web parity). Starts empty; SKIP rows are hidden,
    /// not excluded (the server skips them regardless).
    @State private var excluded: Set<String> = []
    @State private var isPickingFile = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .upload:
                    uploadStep
                case let .review(ics, rows, syncUrl):
                    reviewStep(ics: ics, rows: rows, syncUrl: syncUrl)
                case let .done(result, synced):
                    doneStep(result, synced: synced)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Import calendar")
        .navigationBarTitleDisplayMode(.large)
        .tint(BrandColor.accent)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: Self.icsContentTypes,
            allowsMultipleSelection: false
        ) { result in handlePick(result) }
    }

    // MARK: - Upload

    private var uploadStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Bring your calendar over",
                subtitle: "Import your bookings from your current app. We’ll match each one to your menu, hold blocked time, and build client history — you review it all before anything goes live."
            )
            if let errorMessage { errorBanner(errorMessage) }

            // Path 1 — upload an .ics export.
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Upload an .ics export")
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Export your bookings from your current booking app as an .ics file, then upload it here.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    Button { isPickingFile = true } label: {
                        primaryLabel(busy ? "Reading…" : "Choose an .ics file")
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .opacity(busy ? 0.5 : 1)
                }
            }

            orDivider

            // Path 2 — paste a read-only feed URL.
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste a feed link")
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Most booking apps offer a read-only calendar “subscribe” link. Paste it here and we’ll pull it in — no file needed.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    TextField("https://…/calendar.ics", text: $feedUrl)
                        .textFieldStyle(.plain)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { Task { await fetchFeed() } }
                        .padding(.vertical, 11).padding(.horizontal, 12)
                        .background(BrandColor.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
                        )
                    Toggle(isOn: $keepSynced) {
                        Text("Keep this calendar synced — pull new bookings automatically while you finish moving over.")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    .tint(BrandColor.accent)
                    Button { Task { await fetchFeed() } } label: {
                        secondaryLabel(busy ? "Fetching…" : "Fetch calendar")
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || feedUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(busy || feedUrl.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
            }
        }
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(BrandColor.textMuted.opacity(0.15)).frame(height: 1)
            Text("OR")
                .font(BrandFont.mono(11)).tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            Rectangle().fill(BrandColor.textMuted.opacity(0.15)).frame(height: 1)
        }
    }

    // MARK: - Review

    private func reviewStep(ics: String, rows: [CalendarImportPreviewRow], syncUrl: String?) -> some View {
        // Only non-skipped rows are actionable; SKIP events are hidden (the server
        // skips them regardless). Stats recompute live as toggles change.
        let activeRows = rows.filter { $0.kind != .skip }
        let live = rows.filter { !excluded.contains($0.uid) }
        func count(_ kind: CalendarEventClassification) -> Int {
            live.filter { $0.kind == kind }.count
        }
        return VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Review before importing",
                subtitle: "Here’s what will happen. Turn off any row you don’t want to import."
            )
            reviewStats(bookings: count(.booking), blocks: count(.block), history: count(.history))
            VStack(spacing: 10) {
                ForEach(activeRows) { row in reviewRow(row) }
            }
            if let errorMessage { errorBanner(errorMessage) }
            VStack(spacing: 10) {
                Button { Task { await commit(ics: ics, syncUrl: syncUrl) } } label: {
                    primaryLabel(busy ? "Importing…" : "Import my calendar")
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
                secondaryButton("Start over") { resetToUpload() }
            }
        }
    }

    private func reviewStats(bookings: Int, blocks: Int, history: Int) -> some View {
        HStack(spacing: 8) {
            statPill("\(bookings)", "bookings", BrandColor.accent)
            statPill("\(blocks)", "time blocked", BrandColor.gold)
            statPill("\(history)", "history", BrandColor.textMuted)
        }
    }

    private func reviewRow(_ row: CalendarImportPreviewRow) -> some View {
        let included = !excluded.contains(row.uid)
        return BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Wire.dateTime(row.start, timeZone: nil))
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(row.title)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(row.reason)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                    classificationChip(row)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { included },
                    set: { on in
                        if on { excluded.remove(row.uid) } else { excluded.insert(row.uid) }
                    }
                ))
                .labelsHidden()
                .tint(BrandColor.accent)
            }
            .opacity(included ? 1 : 0.55)
        }
    }

    private func classificationChip(_ row: CalendarImportPreviewRow) -> some View {
        let style = chipStyle(row.kind)
        return Text(style.text)
            .font(BrandFont.mono(11))
            .foregroundStyle(style.tint)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(style.tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func chipStyle(_ kind: CalendarEventClassification?) -> (text: String, tint: Color) {
        switch kind {
        case .booking: return ("Booking", BrandColor.accent)
        case .block: return ("Time blocked", BrandColor.gold)
        case .history: return ("Client history", BrandColor.accent)
        case .skip, .none: return ("Skipped", BrandColor.textMuted)
        }
    }

    // MARK: - Done

    private func doneStep(_ result: CalendarImportCommitResponse, synced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(BrandColor.emerald)
                Text("Your calendar is imported")
                    .font(BrandFont.display(22, .medium))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Everything landed on your calendar. Nothing was sent to your clients — they stay quiet until you book them.")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            BrandSurface {
                VStack(spacing: 10) {
                    doneStat("Bookings", result.created.bookings, BrandColor.accent)
                    doneStat("Time blocked", result.created.blocks, BrandColor.gold)
                    doneStat("Client history", result.created.history, BrandColor.textPrimary)
                    if result.failed > 0 {
                        doneStat("Couldn’t import", result.failed, BrandColor.ember)
                    }
                }
            }
            if synced {
                Text("✓ Calendar kept in sync — we’ll pull new bookings automatically until you disconnect.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.accent)
            }
            VStack(spacing: 10) {
                Button { dismiss() } label: { primaryLabel("Done") }
                    .buttonStyle(.plain)
                secondaryButton("Import another calendar") { resetToUpload() }
            }
        }
    }

    // MARK: - File pick

    /// `.ics` files, plus plain-text fallbacks (some exports are typed generically).
    private static let icsContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text]
        if let ics = UTType(filenameExtension: "ics") { types.insert(ics, at: 0) }
        return types
    }()

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
                    errorMessage = "That file isn’t readable text. Export a plain .ics and try again."
                    return
                }
                // A file upload can't be kept in sync (no source URL).
                Task { await runPreview(ics: text, syncUrl: nil) }
            } catch {
                errorMessage = "Couldn’t read that file. \(error.localizedDescription)"
            }
        }
    }

    private func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Network

    private func fetchFeed() async {
        let url = feedUrl.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let response = try await session.client.proMigration.fetchCalendarFeed(url: url)
            await runPreview(ics: response.ics, syncUrl: url)
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error, fallback: "We couldn’t fetch that calendar URL.")
        } catch {
            errorMessage = "We couldn’t fetch that calendar URL."
        }
    }

    private func runPreview(ics: String, syncUrl: String?) async {
        guard !ics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "That calendar looks empty. Check the export and try again."
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let preview = try await session.client.proMigration.previewCalendarImport(ics: ics)
            guard !preview.rows.isEmpty else {
                errorMessage = "No bookings were found."
                return
            }
            excluded = []
            phase = .review(ics: ics, rows: preview.rows, syncUrl: syncUrl)
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error, fallback: "We couldn’t read that calendar.")
        } catch {
            errorMessage = "We couldn’t read that calendar."
        }
    }

    private func commit(ics: String, syncUrl: String?) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let result = try await session.client.proMigration.commitCalendarImport(
                ics: ics,
                excludeUids: Array(excluded).sorted()
            )
            // A feed-URL source the pro opted to keep synced → connect it now.
            var synced = false
            if let syncUrl, keepSynced {
                synced = (try? await session.client.proMigration.connectCalendarSubscription(url: syncUrl)) != nil
            }
            phase = .done(result, synced: synced)
        } catch let error as APIError {
            errorMessage = migrationErrorMessage(error, fallback: "Something went wrong importing your calendar.")
        } catch {
            errorMessage = "Something went wrong importing your calendar."
        }
    }

    private func migrationErrorMessage(_ error: APIError, fallback: String) -> String {
        if case .server(404, _, _) = error {
            return "Importing isn’t switched on for your account yet."
        }
        if case .server(_, let message?, _) = error, !message.isEmpty { return message }
        return fallback
    }

    // MARK: - Helpers

    private func resetToUpload() {
        excluded = []
        errorMessage = nil
        phase = .upload
    }

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("◆ Step: calendar")
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

    private func secondaryLabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(16, .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(BrandColor.textPrimary)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
            )
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
        }
        .buttonStyle(.plain)
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
