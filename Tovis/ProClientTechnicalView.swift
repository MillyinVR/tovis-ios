// Technical-record tab for the pro client chart — the founder-gated formula
// history + consent/patch-test records + photo-release status. Web parity: the
// `TechnicalRecordTab` on `/pro/clients/[id]`. Loaded lazily from
// GET /pro/clients/{id}/technical (mirrors the web page), so the server-decrypted
// encrypted free text only travels when this tab is open. Formula is author-only;
// consent is `full` for the authoring pro / `safety` for another pro's patch test
// (proof + notes redacted server-side). Write forms live in
// ProClientTechnicalEditSheets. Increment 2 of the pro private-client-view parity.
import SwiftUI
import TovisKit

struct ProClientTechnicalView: View {
    @Environment(SessionModel.self) private var session
    let clientId: String

    private enum Phase {
        case loading
        case loaded(ProClientTechnicalRecord)
        /// The route 404'd — flag off or not yet deployed. Fall back to a web pointer.
        case unavailable
        case failed(String)
    }
    @State private var phase: Phase = .loading

    enum Sheet: String, Identifiable {
        case addFormula, addConsent, editPhotoRelease
        var id: String { rawValue }
    }
    @State private var sheet: Sheet?

    private var record: ProClientTechnicalRecord? {
        if case let .loaded(rec) = phase { return rec }
        return nil
    }

    private func reload() { Task { await load() } }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                    .padding(.vertical, 40)
            case .unavailable:
                webPointer
            case let .failed(message):
                failedState(message)
            case let .loaded(rec):
                loaded(rec)
            }
        }
        .task { if case .loading = phase { await load() } }
        .sheet(item: $sheet) { which in
            switch which {
            case .addFormula:
                ProAddFormulaSheet(clientId: clientId, onSaved: reload)
            case .addConsent:
                ProAddConsentSheet(clientId: clientId, onSaved: reload)
            case .editPhotoRelease:
                ProEditPhotoReleaseSheet(
                    clientId: clientId,
                    current: record?.photoReleaseStatus ?? "NOT_SET",
                    onSaved: reload
                )
            }
        }
    }

    // MARK: - Loaded content

    private func loaded(_ rec: ProClientTechnicalRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            photoReleaseSection(rec.photoReleaseStatus)
            formulaSection(rec.formula)
            consentSection(rec.consents)
        }
    }

    private func photoReleaseSection(_ status: String) -> some View {
        BrandSection(title: "Photo release") {
            BrandSurface {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        BrandPill(text: photoReleaseLabel(status), tint: photoReleaseTone(status))
                        Spacer()
                        Button { sheet = .editPhotoRelease } label: {
                            Text("Edit").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.accent)
                        }
                    }
                    Text("The client's standing release decision. Public sharing still requires the client to promote a photo via a review — this flag does not publish anything on its own.")
                        .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func formulaSection(_ formula: [ProFormulaEntry]) -> some View {
        BrandSection(title: "Formula history", trailing: formula.isEmpty ? nil : "\(formula.count)") {
            VStack(alignment: .leading, spacing: 10) {
                addButton("Add formula") { sheet = .addFormula }
                if formula.isEmpty {
                    emptyText("No formula entries yet.")
                } else {
                    ForEach(formula) { formulaCard($0) }
                }
            }
        }
    }

    private func formulaCard(_ f: ProFormulaEntry) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(f.serviceName ?? "Formula").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    if let when = f.when {
                        Text(Wire.dateOnly(when, timeZone: f.timeZone)).font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
                    }
                }
                if let specs = formulaSpecs(f) {
                    Text(specs).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
                if let notes = f.resultNotes, !notes.isEmpty {
                    Text(notes).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func consentSection(_ consents: [ProConsentRecord]) -> some View {
        BrandSection(title: "Consent & patch tests", trailing: consents.isEmpty ? nil : "\(consents.count)") {
            VStack(alignment: .leading, spacing: 10) {
                addButton("Add consent") { sheet = .addConsent }
                if consents.isEmpty {
                    emptyText("No consent or patch-test records yet.")
                } else {
                    ForEach(consents) { consentCard($0) }
                }
            }
        }
    }

    private func consentCard(_ c: ProConsentRecord) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(consentKindLabel(c.kind)).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    if let result = c.patchTestResult {
                        BrandPill(text: result.capitalized, tint: patchTone(result))
                    }
                }
                if c.scope == "safety", let by = c.byName {
                    Text("Patch test by \(by)").font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                }
                if let scope = c.serviceScope, !scope.isEmpty {
                    Text(scope).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
                if let validUntil = c.validUntil {
                    HStack(spacing: 6) {
                        Text("Valid until \(Wire.dateOnly(validUntil, timeZone: c.timeZone))")
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                        BrandPill(
                            text: isDateCurrent(validUntil) ? "Current" : "Expired",
                            tint: isDateCurrent(validUntil) ? BrandColor.emerald : BrandColor.ember
                        )
                    }
                }
                // Full scope only (the authoring pro): signed-artifact proof + notes.
                if c.scope == "full" {
                    if let proof = proofLine(c) {
                        Text(proof).font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
                    }
                    if let notes = c.notes, !notes.isEmpty {
                        Text(notes).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Fallback / empty states

    private var webPointer: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("Technical record").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Formulas and consent records are viewable on the web for now.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
        }
    }

    private func emptyText(_ message: String) -> some View {
        Text(message).font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
    }

    // MARK: - Formatting helpers

    private func formulaSpecs(_ f: ProFormulaEntry) -> String? {
        var parts: [String] = []
        if let b = f.brand, !b.isEmpty { parts.append(b) }
        if let d = f.developer, !d.isEmpty { parts.append(d) }
        if let r = f.ratio, !r.isEmpty { parts.append(r) }
        if let m = f.processingTimeMinutes { parts.append("\(m) min") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func proofLine(_ c: ProConsentRecord) -> String? {
        var parts: [String] = []
        if let method = c.proofMethod { parts.append(proofMethodLabel(method)) }
        if let signed = c.signedAt { parts.append("signed \(Wire.dateOnly(signed, timeZone: c.timeZone))") }
        if let ref = c.proofRef, !ref.isEmpty { parts.append(ref) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func isDateCurrent(_ iso: String) -> Bool {
        guard let date = Wire.date(iso) else { return false }
        return date > Date()
    }

    private func consentKindLabel(_ kind: String) -> String {
        switch kind {
        case "GENERAL_CONSENT": return "General consent"
        case "SERVICE_WAIVER": return "Service waiver"
        case "PATCH_TEST": return "Patch test"
        default: return kind.capitalized
        }
    }

    private func proofMethodLabel(_ method: String) -> String {
        switch method {
        case "IN_PERSON": return "In person"
        case "CLIENT_TOKEN": return "Client link"
        case "PAPER_ON_FILE": return "Paper on file"
        default: return method.capitalized
        }
    }

    private func patchTone(_ result: String) -> Color {
        switch result.uppercased() {
        case "PASS": return BrandColor.emerald
        case "FAIL": return BrandColor.ember
        default: return BrandColor.gold
        }
    }

    private func photoReleaseLabel(_ status: String) -> String {
        switch status.uppercased() {
        case "GRANTED": return "Granted"
        case "DECLINED": return "Declined"
        default: return "Not set"
        }
    }

    private func photoReleaseTone(_ status: String) -> Color {
        switch status.uppercased() {
        case "GRANTED": return BrandColor.emerald
        case "DECLINED": return BrandColor.ember
        default: return BrandColor.textMuted
        }
    }

    // MARK: - Load

    private func load() async {
        do {
            let rec = try await session.client.proClients.technicalRecord(clientId: clientId)
            phase = .loaded(rec)
        } catch let error as APIError {
            // 404 = the founder flag is off or the route isn't deployed yet; keep
            // the graceful "view on web" pointer rather than a hard error.
            if case let .server(status, _, _) = error, status == 404 {
                phase = .unavailable
            } else {
                phase = .failed(error.userMessage)
            }
        } catch {
            phase = .failed("Couldn’t load the technical record.")
        }
    }
}
