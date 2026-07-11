// Native "Share your look" flow — the counterpart to the web share-your-look sheet
// (app/client/(gated)/looks/share/[bookingId]/ShareLookSheet.tsx). Presented from a
// completed appointment's aftercare section. Publishes a public look (before/after
// photos + name + caption + visibility) tagged to the visit's pro.
//
// The web *prefill* screen is RSC-only (loadShareLookPage.ts, no JSON GET), so iOS
// synthesizes it: the header (service name / pro / visit date) comes from the
// booking detail we already hold, and the before/after reuse candidates come from
// `reviews.reviewMediaOptions` — the pro's session photos, the same seam the review
// flow uses and a superset of the web prefill's single before/after. Fresh photos
// upload via `shareLook.uploadPhoto`; publishing goes through `shareLook.shareLook`.
import SwiftUI
import PhotosUI
import UIKit
import TovisKit

struct ShareLookView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let booking: ClientBooking
    /// Called after a successful publish so the host (booking detail → Me tab) can
    /// refresh — the new look then appears in the "Your looks" grid.
    var onPublished: () async -> Void = {}

    private static let nameMax = 80
    private static let captionMax = 300

    /// One before/after photo choice: a reused visit photo, a fresh upload, or empty.
    private struct LookSlot {
        var source: LookPhotoSource?
        var remotePreviewUrl: String?
        var localPreview: UIImage?
        var uploading = false
        var failed = false
        var isFilled: Bool { source != nil }
    }

    @State private var mediaOptions: [ReviewMediaOption] = []
    @State private var didLoad = false
    @State private var didPrefill = false

    @State private var after = LookSlot()
    @State private var before = LookSlot()
    @State private var afterPick: PhotosPickerItem?
    @State private var beforePick: PhotosPickerItem?

    @State private var name: String
    @State private var caption = ""
    @State private var isPublic = true

    @State private var submitting = false
    @State private var formError: String?

    init(booking: ClientBooking, onPublished: @escaping () async -> Void = {}) {
        self.booking = booking
        self.onPublished = onPublished
        // Seed the look name from the service, mirroring the web `suggestedName`.
        _name = State(initialValue: booking.display.baseName)
    }

    private var canShare: Bool {
        after.isFilled
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !after.uploading && !before.uploading
            && !submitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let formError { errorBanner(formError) }

                    slotSection(
                        title: "After photo",
                        subtitle: "The finished look — this is what people see.",
                        phase: .after, slot: after, pick: $afterPick, required: true)

                    slotSection(
                        title: "Before photo",
                        subtitle: "Optional — show the transformation.",
                        phase: .before, slot: before, pick: $beforePick, required: false)

                    nameField
                    captionField
                    visibilitySection

                    SignupPrimaryButton(
                        title: isPublic ? "Share look" : "Save to my profile",
                        isLoading: submitting,
                        isDisabled: !canShare
                    ) {
                        Task { await publish() }
                    }

                    footnote
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Share your look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                        .disabled(submitting)
                }
            }
            .task { await loadOptions() }
            .onChange(of: afterPick) { _, new in Task { await handlePick(new, phase: .after) } }
            .onChange(of: beforePick) { _, new in Task { await handlePick(new, phase: .before) } }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Header

    private var header: some View {
        let proName = booking.professional?.displayName ?? "your pro"
        let dateLabel = Wire.dateOnly(booking.scheduledFor, timeZone: booking.timeZone)
        return HStack(spacing: 12) {
            BrandAvatar(name: proName, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("With \(proName)")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                if !dateLabel.isEmpty {
                    Text(dateLabel)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BrandColor.ember.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Photo slots

    @ViewBuilder
    private func slotSection(
        title: String, subtitle: String, phase: MediaPhase,
        slot: LookSlot, pick: Binding<PhotosPickerItem?>, required: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SignupFieldLabel(title)
                if required {
                    Text("Required")
                        .font(BrandFont.body(11, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
            Text(subtitle)
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)

            slotPreview(slot, phase: phase)

            if !mediaOptions.isEmpty {
                Text("From this appointment")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mediaOptions) { option in
                            candidateThumb(option, phase: phase, slot: slot)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            PhotosPicker(selection: pick, matching: .images) {
                Label(
                    slot.isFilled ? "Upload a different photo" : "Upload a new photo",
                    systemImage: "photo.badge.plus"
                )
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(slot.uploading || submitting ? BrandColor.textMuted : BrandColor.accent)
            }
            .disabled(slot.uploading || submitting)
        }
    }

    @ViewBuilder
    private func slotPreview(_ slot: LookSlot, phase: MediaPhase) -> some View {
        if slot.uploading {
            previewBox { ProgressView().tint(BrandColor.textMuted) }
        } else if let image = slot.localPreview {
            filledPreview(Image(uiImage: image).resizable().scaledToFill(), phase: phase)
        } else if let urlString = slot.remotePreviewUrl, let url = URL(string: urlString) {
            filledPreview(
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(BrandColor.textMuted)
                },
                phase: phase)
        } else {
            previewBox {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 26))
                        .foregroundStyle(BrandColor.textMuted)
                    Text("No photo yet")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
            if slot.failed {
                Text("That upload didn’t go through. Try again.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.ember)
            }
        }
    }

    private func filledPreview<V: View>(_ image: V, phase: MediaPhase) -> some View {
        ZStack(alignment: .topTrailing) {
            image
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { clearSlot(phase) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding(8)
            }
            .buttonStyle(.plain)
            .disabled(submitting)
        }
    }

    private func previewBox<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ZStack { content() }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5]))
            )
    }

    private func candidateThumb(_ option: ReviewMediaOption, phase: MediaPhase, slot: LookSlot) -> some View {
        let selected = slot.source == .reuse(mediaAssetId: option.id)
        return Button { selectReuse(option, phase: phase) } label: {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: option.displayThumbUrl)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(BrandColor.textMuted)
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? BrandColor.accent : .clear, lineWidth: 2)
                )
                if option.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 72, height: 72)
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(BrandColor.onAccent, BrandColor.accent)
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    // MARK: - Text + visibility

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Look name")
            TextField(
                "", text: $name,
                prompt: Text("e.g. Glazed donut blonde").foregroundStyle(BrandColor.textMuted)
            )
            .font(BrandFont.body(16))
            .foregroundStyle(BrandColor.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
            .onChange(of: name) { _, newValue in
                formError = nil
                if newValue.count > Self.nameMax { name = String(newValue.prefix(Self.nameMax)) }
            }
        }
    }

    private var captionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Caption (optional)")
            TextField(
                "", text: $caption,
                prompt: Text("Add a note about your look…").foregroundStyle(BrandColor.textMuted),
                axis: .vertical
            )
            .lineLimit(3...6)
            .font(BrandFont.body(16))
            .foregroundStyle(BrandColor.textPrimary)
            .frame(minHeight: 80, alignment: .topLeading)
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
            .onChange(of: caption) { _, newValue in
                formError = nil
                if newValue.count > Self.captionMax { caption = String(newValue.prefix(Self.captionMax)) }
            }
        }
    }

    private var visibilitySection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Show on your public feed")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(isPublic
                     ? "Your look appears in discovery and on your public profile."
                     : "Saved to your profile only — not shown in discovery.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isPublic)
                .labelsHidden()
                .tint(BrandColor.accent)
                .disabled(submitting)
        }
    }

    private var footnote: some View {
        Text("Your pro is tagged on this look. Sharing publishes these photos to your profile.")
            .font(BrandFont.body(11))
            .foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    /// Load the pro's session photos the client can turn into a look — once. A
    /// failure just leaves the reuse strip empty; fresh uploads still work.
    private func loadOptions() async {
        guard !didLoad else { return }
        didLoad = true
        mediaOptions =
            (try? await session.client.reviews.reviewMediaOptions(bookingId: booking.id)) ?? []
        prefillFromOptions()
    }

    /// Auto-select the newest AFTER photo for the after slot and the newest BEFORE
    /// for the before slot — mirrors the web prefill (`loadPrefillPhoto`, newest
    /// PRO_CLIENT photo per phase; the options arrive phase-sorted, newest-first).
    private func prefillFromOptions() {
        guard !didPrefill else { return }
        didPrefill = true
        if !after.isFilled, let opt = mediaOptions.first(where: { $0.phase == .after }) {
            after = LookSlot(source: .reuse(mediaAssetId: opt.id), remotePreviewUrl: opt.displayThumbUrl)
        }
        if !before.isFilled, let opt = mediaOptions.first(where: { $0.phase == .before }) {
            before = LookSlot(source: .reuse(mediaAssetId: opt.id), remotePreviewUrl: opt.displayThumbUrl)
        }
    }

    private func setSlot(_ phase: MediaPhase, _ mutate: (inout LookSlot) -> Void) {
        switch phase {
        case .after: mutate(&after)
        case .before: mutate(&before)
        case .other: break
        }
    }

    private func selectReuse(_ option: ReviewMediaOption, phase: MediaPhase) {
        formError = nil
        setSlot(phase) {
            $0.source = .reuse(mediaAssetId: option.id)
            $0.remotePreviewUrl = option.displayThumbUrl
            $0.localPreview = nil
            $0.uploading = false
            $0.failed = false
        }
    }

    private func clearSlot(_ phase: MediaPhase) {
        formError = nil
        setSlot(phase) { $0 = LookSlot() }
    }

    /// Compress the pick and upload it immediately (upload-on-pick) so publishing
    /// only references the returned upload-session id. Mirrors the review flow.
    private func handlePick(_ item: PhotosPickerItem?, phase: MediaPhase) async {
        guard let item else { return }
        // Reset the binding so re-picking the same asset re-triggers onChange.
        switch phase {
        case .after: afterPick = nil
        case .before: beforePick = nil
        case .other: break
        }
        formError = nil

        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data)
        else {
            setSlot(phase) { $0.failed = true }
            return
        }
        let jpeg = image.jpegData(compressionQuality: 0.85) ?? data
        setSlot(phase) {
            $0.localPreview = image
            $0.remotePreviewUrl = nil
            $0.source = nil
            $0.uploading = true
            $0.failed = false
        }
        do {
            let sessionId = try await session.client.shareLook.uploadPhoto(
                bookingId: booking.id, phase: phase, imageData: jpeg)
            setSlot(phase) {
                $0.source = .upload(sessionId: sessionId)
                $0.uploading = false
            }
        } catch {
            setSlot(phase) {
                $0.uploading = false
                $0.failed = true
                $0.localPreview = nil
            }
        }
    }

    private func publish() async {
        guard let afterSource = after.source else {
            formError = "Add an after photo to share your look."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            formError = "Give your look a name."
            return
        }
        guard !after.uploading, !before.uploading else {
            formError = "Hang on — your photo is still uploading."
            return
        }
        guard !submitting else { return }
        submitting = true
        formError = nil
        defer { submitting = false }
        do {
            _ = try await session.client.shareLook.shareLook(
                bookingId: booking.id,
                name: trimmedName,
                caption: caption,
                isPublic: isPublic,
                after: afterSource,
                before: before.source)
            await onPublished()
            dismiss()
        } catch let error as APIError {
            formError = error.userMessage
        } catch {
            formError = "Couldn’t share your look. Please try again."
        }
    }
}
