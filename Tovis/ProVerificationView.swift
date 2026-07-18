// Pro license / document verification — the native counterpart to the web
// /pro/verification page (app/pro/verification/page.tsx + VerificationUploadClient
// + LicenseEditForm + DeleteDocButton). Loads GET /api/v1/pro/verification and
// lets the pro:
//   • see their verification status + whether the license is admin-verified,
//   • edit their license (state / number / expiry) — licensed professions only,
//   • upload a document photo for any of the profession's accepted methods,
//   • remove a still-pending document.
//
// Reached from the onboarding checklist's verification/license rows (and any
// future pro-settings entry point). Each doc row shows an inline photo preview,
// matching web: the private image sits behind an authenticated 302→signed
// redirect that AsyncImage can't fetch with a bearer token, so the row resolves
// the signed URL first (documentPreviewURL → APIClient.resolveRedirect reads the
// redirect's Location) and then loads it — see VerificationDocPreview.
import SwiftUI
import PhotosUI
import TovisKit

struct ProVerificationView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProVerification)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    // License edit form (licensed professions only).
    @State private var licenseState = ""
    @State private var licenseNumber = ""
    @State private var licenseExpiry = Date()
    @State private var hasExpiry = false
    @State private var savingLicense = false
    @State private var licenseSaved = false
    @State private var licenseError: String?

    // Upload.
    @State private var selectedMethodType: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var uploadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case let .failed(message):
                    errorState(message)
                case let .loaded(verification):
                    content(verification)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Verification")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: pickerItem) { Task { await handlePickedDoc() } }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ v: ProVerification) -> some View {
        intro
        statusCard(v)
        if v.isLicensed {
            licenseSection
        }
        uploadSection(v)
        documentsSection(v)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your verification")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("This controls marketplace visibility and who can book you. We keep everything private — only admins can view your documents.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private func statusCard(_ v: ProVerification) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Status")
                        .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
                        .foregroundStyle(BrandColor.textMuted)
                    Spacer()
                    statusBadge(v.status)
                }
                Text("License verified: ")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                + Text(v.licenseVerified ? "Yes" : "No")
                    .font(BrandFont.body(12, .heavy))
                    .foregroundStyle(v.licenseVerified ? BrandColor.emerald : BrandColor.textPrimary)
            }
        }
    }

    private func statusBadge(_ status: ProVerificationStatus) -> some View {
        Text(status.label)
            .font(BrandFont.body(12, .heavy))
            .foregroundStyle(statusTint(status))
            .padding(.vertical, 5).padding(.horizontal, 12)
            .background(statusTint(status).opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(statusTint(status).opacity(0.3), lineWidth: 1))
    }

    private func statusTint(_ status: ProVerificationStatus) -> Color {
        switch status {
        case .approved: return BrandColor.emerald
        case .pending, .pendingManualReview: return BrandColor.gold
        case .rejected, .needsInfo: return BrandColor.ember
        case .unknown: return BrandColor.textMuted
        }
    }

    // MARK: - License edit

    private var licenseSection: some View {
        BrandSection(title: "Your license") {
            BrandSurface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Keep your details current and upload a clear photo below. Both are required before an admin can approve you — and at renewal, update the date and re-upload.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)

                    VStack(alignment: .leading, spacing: 6) {
                        SignupFieldLabel("State")
                        Menu {
                            ForEach(usStates) { state in
                                Button(state.name) { licenseState = state.code; clearLicenseFlash() }
                            }
                        } label: {
                            HStack {
                                Text(stateName(licenseState) ?? "Select state…")
                                    .foregroundStyle(licenseState.isEmpty ? BrandColor.textMuted : BrandColor.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12)).foregroundStyle(BrandColor.textMuted)
                            }
                            .font(BrandFont.body(16))
                            .padding(.horizontal, 16).padding(.vertical, 15)
                            .background(BrandColor.bgSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SignupFieldLabel("License / registration number")
                        BrandField(placeholder: "e.g. COS123456", text: $licenseNumber, isSecure: false)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: licenseNumber) { clearLicenseFlash() }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $hasExpiry) {
                            SignupFieldLabel("Has an expiration date")
                        }
                        .tint(BrandColor.accent)
                        .onChange(of: hasExpiry) { clearLicenseFlash() }

                        if hasExpiry {
                            DatePicker(
                                "Expiration date",
                                selection: $licenseExpiry,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                            .tint(BrandColor.accent)
                            .foregroundStyle(BrandColor.textPrimary)
                            .onChange(of: licenseExpiry) { clearLicenseFlash() }
                        }
                    }

                    SignupPrimaryButton(
                        title: "Save license info",
                        isLoading: savingLicense,
                        isDisabled: licenseState.isEmpty || licenseNumber.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        Task { await saveLicense() }
                    }

                    if licenseSaved {
                        Text("Saved — sent to admin for re-review. Your access isn’t affected.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.emerald)
                    }
                    if let licenseError {
                        Text(licenseError)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.ember)
                    }
                }
            }
        }
    }

    // MARK: - Upload

    @ViewBuilder
    private func uploadSection(_ v: ProVerification) -> some View {
        if !v.methods.isEmpty {
            BrandSection(title: v.isLicensed ? "Upload a document" : "Your certifications") {
                BrandSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(v.methods) { method in
                            methodRow(method)
                        }

                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            HStack(spacing: 8) {
                                if uploading {
                                    ProgressView().tint(BrandColor.onAccent)
                                } else {
                                    Image(systemName: "arrow.up.doc")
                                }
                                Text(uploading ? "Uploading…" : "Upload photo")
                                    .font(BrandFont.body(15, .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(BrandColor.accent)
                            .foregroundStyle(BrandColor.onAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(uploading || effectiveMethodType(v) == nil)

                        if let uploadError {
                            Text(uploadError)
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.ember)
                        }
                    }
                }
            }
        }
    }

    private func methodRow(_ method: ProVerificationMethod) -> some View {
        let selected = selectedMethodType == method.type
        return Button {
            selectedMethodType = method.type
            uploadError = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? BrandColor.accent : BrandColor.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.title)
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(method.description)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected ? BrandColor.accent.opacity(0.1) : BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((selected ? BrandColor.accent : BrandColor.textMuted).opacity(selected ? 0.35 : 0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Documents

    @ViewBuilder
    private func documentsSection(_ v: ProVerification) -> some View {
        BrandSection(title: "Documents", trailing: "\(v.docs.count)") {
            if v.docs.isEmpty {
                Text("No documents uploaded yet.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(v.docs) { doc in
                        docRow(doc)
                    }
                }
            }
        }
    }

    private func docRow(_ doc: ProVerificationDoc) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.label ?? doc.typeLabel)
                            .font(BrandFont.body(13, .heavy))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("\(doc.typeLabel) · \(shortDate(doc.createdAt))")
                            .font(BrandFont.body(11))
                            .foregroundStyle(BrandColor.textMuted)
                        if let note = doc.adminNote, !note.isEmpty {
                            Text("Admin note: \(note)")
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textSecondary)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 8)
                    statusBadge(doc.status)
                }

                // Inline preview of the uploaded photo (matches web's thumbnail).
                VerificationDocPreview(docId: doc.id)

                if doc.status == .pending {
                    Button(role: .destructive) {
                        Task { await deleteDoc(doc.id) }
                    } label: {
                        Text("Remove")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.ember)
                    }
                    .buttonStyle(.plain)
                }
            }
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

    // MARK: - Helpers

    private func stateName(_ code: String) -> String? {
        usStates.first { $0.code == code }?.name
    }

    private func clearLicenseFlash() {
        licenseSaved = false
        licenseError = nil
    }

    /// The method to upload as: the explicit selection, else the first method.
    private func effectiveMethodType(_ v: ProVerification) -> ProVerificationMethod? {
        if let selectedMethodType, let hit = v.methods.first(where: { $0.type == selectedMethodType }) {
            return hit
        }
        return v.methods.first
    }

    // MARK: - Actions

    private func load() async {
        do {
            let v = try await session.client.proVerification.verification()
            applyLicense(v.license)
            if selectedMethodType == nil { selectedMethodType = v.methods.first?.type }
            phase = .loaded(v)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your verification.")
        }
    }

    private func applyLicense(_ license: ProVerificationLicense) {
        licenseState = license.state ?? ""
        licenseNumber = license.number ?? ""
        // Parse the stored calendar date in the device calendar so the (unpinned)
        // picker opens on the stored day — the inverse of the save below.
        if let expiry = license.expiry, let date = BoardEventDate.date(fromYmd: expiry) {
            licenseExpiry = date
            hasExpiry = true
        } else {
            hasExpiry = false
        }
    }

    private func saveLicense() async {
        guard !savingLicense else { return }
        savingLicense = true
        clearLicenseFlash()
        defer { savingLicense = false }
        do {
            try await session.client.proVerification.saveLicense(
                state: licenseState,
                number: licenseNumber.trimmingCharacters(in: .whitespaces).uppercased(),
                // Device calendar, matching the unpinned picker — a UTC formatter
                // here persisted the NEXT day for evening picks west of UTC.
                expiry: hasExpiry ? BoardEventDate.ymd(from: licenseExpiry) : ""
            )
            licenseSaved = true
            await load()
        } catch let error as APIError {
            licenseError = error.userMessage
        } catch {
            licenseError = "Couldn’t save your license info."
        }
    }

    private func handlePickedDoc() async {
        guard let item = pickerItem else { return }
        guard case let .loaded(v) = phase, let method = effectiveMethodType(v) else { return }
        uploadError = nil
        uploading = true
        defer { uploading = false; pickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                uploadError = "Couldn’t read that photo."
                return
            }
            try await session.client.proVerification.uploadDocument(
                type: method.type, title: method.title, imageData: data
            )
            await load()
        } catch let error as APIError {
            uploadError = error.userMessage
        } catch {
            uploadError = "Upload failed."
        }
    }

    private func deleteDoc(_ id: String) async {
        do {
            try await session.client.proVerification.deleteDocument(id: id)
            await load()
        } catch {
            // Surface nothing loud — a failed delete just leaves the row in place;
            // reload to reflect true state.
            await load()
        }
    }

    private func shortDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return "" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }
}

// MARK: - Document preview

/// Inline thumbnail of one verification doc's private image, matching web's row
/// preview. The image sits in the private bucket behind an authenticated route
/// that 302-redirects to a short-lived signed URL — which `AsyncImage` can't
/// reach with a bearer — so this resolves the signed URL once on appear
/// (`documentPreviewURL`) and then loads it. Any failure degrades to a small
/// placeholder; the rest of the row keeps working.
private struct VerificationDocPreview: View {
    @Environment(SessionModel.self) private var session
    let docId: String

    @State private var url: URL?
    @State private var resolving = true
    @State private var failed = false

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder("photo")
                    case .empty:
                        loading
                    @unknown default:
                        BrandColor.bgSecondary
                    }
                }
            } else if resolving {
                loading
            } else {
                placeholder("eye.slash")
            }
        }
        .frame(width: 176, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
        .task { await resolve() }
        .accessibilityLabel("Uploaded document preview")
    }

    private var loading: some View {
        ZStack { BrandColor.bgSecondary; ProgressView().tint(BrandColor.accent) }
    }

    private func placeholder(_ systemName: String) -> some View {
        ZStack {
            BrandColor.bgSecondary
            Image(systemName: systemName)
                .font(.system(size: 20))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    private func resolve() async {
        guard url == nil, !failed else { return }
        resolving = true
        defer { resolving = false }
        do {
            url = try await session.client.proVerification.documentPreviewURL(id: docId)
        } catch {
            failed = true
        }
    }
}
