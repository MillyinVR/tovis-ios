// Native "Submit a viral look" — the counterpart to the web SubmitViralLookForm
// (app/client/(gated)/_components/SubmitViralLookForm.tsx), which web renders as
// the third cell of the Viral Looks band. POSTs to /api/v1/viral-service-requests
// via ViralRequestsService; the created row comes back as REQUESTED and shows up
// in the band's "Your request" pipeline on the next home refresh.
//
// Deliberate deviation from web: web keeps the form inline in the band and shows
// an in-place "Submitted — our team is reviewing it now." notice. On iOS the band
// is the LAST section of a long home ScrollView that reloads itself every 30s
// (HomeView.poll), so an inline two-field form would put a keyboard over a list
// that moves underneath it. The band therefore carries a CTA card that presents
// this sheet, and the success confirmation is the band itself — dismissing lands
// on the freshly-loaded "Your request · Submitted" pipeline, a stronger receipt
// than a text notice. Same reasoning shape as the step-4 report confirmation.
import PhotosUI
import SwiftUI
import TovisKit
import UniformTypeIdentifiers

struct SubmitViralLookView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful submit so the host can refresh home — the band's
    /// pending pipeline is where the person sees what they just submitted.
    let onSubmitted: () async -> Void

    @State private var draft = ViralLookDraft()
    @State private var submitting = false
    @State private var errorText: String?

    @State private var pick: PhotosPickerItem?
    @State private var attachment: ViralLookAttachment?
    /// A still for the picked photo; nil for a video, which shows a chip instead.
    @State private var attachmentPreview: UIImage?
    @State private var loadingAttachment = false
    /// Set once the look exists. A failed upload must not submit it a second
    /// time for an admin to moderate twice, so the retry resumes from here —
    /// the same resume the web form does with its refs.
    @State private var submittedRequestId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro

                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(BrandColor.ember.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Web's field order: the link first, then the name.
                    sourceUrlField
                    nameField
                    attachmentField

                    // Web parity, and the only honest option here: web's button is
                    // disabled *only* while submitting — a blank name is refused on
                    // press with copy, not by greying out. SignupPrimaryButton has
                    // no visual disabled state (it renders full-accent either way),
                    // so gating on `canSubmit` would show a live-looking button that
                    // silently does nothing.
                    SignupPrimaryButton(
                        title: submittedRequestId == nil ? "Submit for review" : "Attach",
                        isLoading: submitting
                    ) {
                        Task { await submit() }
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Submit a viral look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                        .disabled(submitting)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotted a new one?".uppercased())
                .font(BrandFont.mono(10)).tracking(1.6)
                .foregroundStyle(BrandColor.textMuted)
            Text("Paste the link and name it. Our team vets it and shares it with pros before it goes live.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var sourceUrlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SignupFieldLabel("Link")
                Text("optional")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
            TextField(
                "",
                text: $draft.sourceUrl,
                prompt: Text("Paste TikTok / Instagram / Pinterest link…")
                    .foregroundStyle(BrandColor.textMuted)
            )
            .font(BrandFont.body(16))
            .foregroundStyle(BrandColor.textPrimary)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            // Locked once the look is submitted: the button is then retrying the
            // file, and an edit here would never be saved.
            .disabled(submitting || submittedRequestId != nil)
            .modifier(ViralFieldChrome())
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Name this look")
            TextField(
                "",
                text: $draft.name,
                prompt: Text("Glazed donut bob").foregroundStyle(BrandColor.textMuted)
            )
            .font(BrandFont.body(16))
            .foregroundStyle(BrandColor.textPrimary)
            .disabled(submitting || submittedRequestId != nil)
            .modifier(ViralFieldChrome())
            // Web gets this cap free from the input's maxLength={160}; SwiftUI has
            // no equivalent, so clamp as typed rather than let the server 400.
            .onChange(of: draft.name) { _, newValue in
                let clamped = ViralLookDraft.clampedName(newValue)
                if clamped != newValue { draft.name = clamped }
            }
            Text("Pros search by name — “Cherry cola balayage” beats “brown hair”.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    /// Web's "Add a photo or video" cell, and the same promise under it.
    ///
    /// 🔴 The copy has to be true: what is attached goes to the review queue and
    /// nowhere else. Only an admin sets the picture a look is published under, so
    /// this must never read like "your photo will appear on the look".
    private var attachmentField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SignupFieldLabel("Photo or video")
                Text("optional")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }

            if let attachment {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(BrandColor.bgPrimary)
                        if let attachmentPreview {
                            Image(uiImage: attachmentPreview)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "video.fill")
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.isVideo ? "Video attached" : "Photo attached")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Only our team sees this while they review it.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }

                    Spacer(minLength: 0)

                    Button("Remove") {
                        self.attachment = nil
                        attachmentPreview = nil
                    }
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .disabled(submitting)
                }
                .padding(10)
                .modifier(ViralFieldChrome())
            } else {
                PhotosPicker(
                    selection: $pick,
                    matching: .any(of: [.images, .videos])
                ) {
                    HStack(spacing: 8) {
                        if loadingAttachment {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text(loadingAttachment ? "Loading…" : "Add a photo or video")
                            .font(BrandFont.body(15, .semibold))
                    }
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                BrandColor.textMuted.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                    )
                }
                .disabled(submitting)
            }
        }
        .onChange(of: pick) { _, item in
            Task { await handlePick(item) }
        }
    }

    /// The route has no idempotency key and no rate limit (verified by driving it),
    /// so a double-tap would create a second request an admin has to moderate
    /// twice. `submitting` is the only thing preventing that — guard on it here as
    /// well as disabling the button, since the button is not the only way in.
    private func submit() async {
        guard !submitting else { return }
        // Web's own pre-flight refusal, same copy — the name is the one field the
        // server requires, and saying so beats a round trip to read it back.
        // Skipped once the look exists: the button is then only retrying the file.
        guard submittedRequestId != nil || draft.canSubmit else {
            errorText = "Name the look so pros know what to match."
            return
        }
        submitting = true
        errorText = nil
        defer { submitting = false }

        do {
            if submittedRequestId == nil {
                guard let created = try await session.client.viralRequests.submit(draft: draft)
                else { return }
                submittedRequestId = created.id
            }

            if let attachment, let requestId = submittedRequestId {
                try await session.client.viralRequests.attach(
                    requestId: requestId,
                    attachment: attachment)
            }

            submittedRequestId = nil
            await onSubmitted()
            dismiss()
        } catch let error as APIError {
            errorText = failureText(serverMessage: clientFacingMessage(error))
        } catch {
            errorText = failureText(serverMessage: nil)
        }
    }

    /// Copy for a failed attempt.
    ///
    /// It has to say which half survived: once the look is submitted, a bare
    /// "try again" reads as "nothing was saved" — and a second tap would submit
    /// it twice.
    private func failureText(serverMessage: String?) -> String {
        let submitted = submittedRequestId != nil
        let base =
            serverMessage
            ?? (submitted
                ? "Couldn’t attach your file. Try again."
                : "Couldn’t submit your look. Try again.")

        return submitted
            ? "\(base) Your look is submitted — tap Attach to try the file again."
            : base
    }

    /// The server's own copy only for what a person can act on.
    ///
    /// Its 4xx messages are already user-facing ("sourceUrl must be a valid
    /// URL.", "File too large (max 30MB)"), so showing them beats inventing a
    /// second vocabulary. A 5xx body is written for whoever is on call — the
    /// signing route's 500s name storage hosts and provider detail — and must
    /// never reach a client. Same rule as the web form's `failureMessage`.
    private func clientFacingMessage(_ error: APIError) -> String? {
        switch error {
        case let .server(status, _, _), let .serverDetails(status, _, _, _):
            return status >= 500 ? nil : error.userMessage
        case .invalidResponse, .unauthorized, .decoding, .transport:
            return error.userMessage
        }
    }

    private func handlePick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        // Reset the binding so re-picking the SAME item re-fires onChange —
        // otherwise a retry after a failed read is a dead tap. Same reason
        // ProNewMediaPostView.handlePick does it; the nil write returns above.
        pick = nil

        loadingAttachment = true
        errorText = nil
        defer { loadingAttachment = false }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorText = "Couldn’t read that file. Try another one."
            return
        }

        let type = item.supportedContentTypes.first { $0.preferredMIMEType != nil }
        let isVideo = type?.conforms(to: .movie) ?? false

        let picked: ViralLookAttachment
        if isVideo {
            picked = ViralLookAttachment(
                data: data,
                contentType: type?.preferredMIMEType ?? "video/quicktime",
                fileExtension: type?.preferredFilenameExtension ?? "mov")
            attachmentPreview = nil
        } else {
            // Re-encode rather than ship the original: a HEIC or a 12MP PNG is
            // both huge and not what a reviewer needs. Same 0.85 the share-look
            // and new-post flows use.
            guard let image = UIImage(data: data) else {
                errorText = "Couldn’t read that photo. Try another one."
                return
            }
            let jpeg = image.jpegData(compressionQuality: 0.85) ?? data
            picked = ViralLookAttachment(
                data: jpeg,
                contentType: "image/jpeg",
                fileExtension: "jpg")
            attachmentPreview = image
        }

        // The signing route's own cap. Checked here so the person learns before
        // the upload rather than from a 400 after it.
        guard !picked.isOverCap else {
            attachmentPreview = nil
            errorText =
                "That file is over \(ViralLookAttachment.maxLabel). Try a shorter clip."
            return
        }

        attachment = picked
    }
}

/// The shared text-field chrome for this form (surface fill + hairline border),
/// matching the CreateBoardView fields.
private struct ViralFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
    }
}
