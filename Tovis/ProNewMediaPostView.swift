import PhotosUI
import SwiftUI
import TovisKit

/// The native "new post" authoring screen — the counterpart of the web
/// `/pro/media/new` page. A pro picks a photo from their library, captions it,
/// tags services, decides where it shows, and posts.
///
/// Two deliberate divergences from web, both narrower rather than wider:
///   - **No crop editor.** Web bakes a crop into the pixels to fit the Looks UI;
///     native keeps the original and sends a FOCAL POINT from the same face
///     detection the camera uses, so the feed's cover-crop centers on the subject.
///     Nothing is destroyed, and the pro doesn't have to think about it.
///   - **Photos only** (`PhotosPicker(matching: .images)`). Web also posts video;
///     that needs a poster frame and a progress-tracked multi-MB upload, and the
///     focal this screen exists to supply is face detection on a still.
///
/// Every rule lives on `NewMediaPostDraft` in TovisKit — this view owns pixels and
/// the async pick/upload, nothing else. That's what `swift test` can reach.
struct ProNewMediaPostView: View {
    /// Called after a successful post so the caller can refresh.
    var onPosted: () -> Void

    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// The taggable taxonomy, loaded on appear.
    ///
    /// Self-loading rather than injected: the media manager has it already, but the
    /// profile's "+ Upload" doesn't, and a screen that can only be opened by whoever
    /// happens to hold its data isn't reusable. `serviceOptions` rides the media
    /// list (there's no leaner endpoint that returns the SAME taxonomy `POST
    /// /pro/media` validates against), so this costs one GET on an explicit tap.
    @State private var serviceOptions: [ProMediaServiceTag] = []
    @State private var optionsLoaded = false
    @State private var optionsFailed = false

    @State private var draft = NewMediaPostDraft()
    @State private var pick: PhotosPickerItem?
    @State private var preview: UIImage?
    /// The encoded JPEG we actually upload, kept beside the draft's byte count.
    @State private var imageData: Data?
    /// The subject's normalized center, computed on pick. nil = no face found →
    /// the server centers the crop, exactly as it always has.
    @State private var focal: MediaFocalPoint?
    /// Stamps each pick so an out-of-order load can't overwrite a newer one.
    @State private var pickGeneration = 0
    @State private var posting = false
    @State private var errorMessage: String?

    private var blockingReasons: [String] {
        // Web's order: loading → load error → no services → none tagged. The first
        // two matter because an empty `serviceOptions` means something different in
        // each: while the GET is in flight or after it FAILED, "No services found.
        // Add at least one service" would accuse the pro of an empty catalog we
        // never actually read.
        guard optionsLoaded else { return ["Loading your services…"] }
        if optionsFailed { return ["Couldn’t load your services. Close and reopen to try again."] }
        return draft.blockingReasons(hasServiceOptions: !serviceOptions.isEmpty)
    }

    private var canPost: Bool { blockingReasons.isEmpty && !posting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    photoSection
                    captionSection
                    privacySection
                    if !draft.isPrivate { surfacesSection }
                    servicesSection
                    if draft.showsLooksSettings { looksSettingsSection }
                    if let errorMessage { errorBox(errorMessage) }
                    if !blockingReasons.isEmpty { blockingBox }
                    postButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(posting)
                }
            }
            .tint(BrandColor.accent)
        }
        .onChange(of: pick) { _, item in
            Task { await handlePick(item) }
        }
        .task { await loadServiceOptions() }
    }

    private func loadServiceOptions() async {
        guard !optionsLoaded else { return }
        do {
            serviceOptions = try await session.client.proMedia.listManagedMedia().serviceOptions
            optionsFailed = false
        } catch {
            optionsFailed = true
        }
        optionsLoaded = true
    }

    // MARK: - Photo

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Photo")
            PhotosPicker(selection: $pick, matching: .images) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BrandColor.bgSecondary)
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                    } else if case .loading = draft.image {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 28))
                                .foregroundStyle(BrandColor.textMuted)
                            Text("Choose a photo")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                }
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(posting)

            Text(focal == nil
                 ? "We keep your whole photo — no cropping."
                 : "We spotted your subject, so the Looks feed will frame them.")
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    // MARK: - Caption

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Caption")
            TextEditor(text: $draft.caption)
                .frame(minHeight: 90)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .disabled(posting)
                .onChange(of: draft.caption) { _, value in
                    if value.count > NewMediaPostDraft.captionMaxLength {
                        draft.caption = String(value.prefix(NewMediaPostDraft.captionMaxLength))
                    }
                }
            HStack {
                Spacer()
                // Verbatim: a LocalizedStringKey interpolation would render 300 as
                // "300" but a count of 1,024 as "1,024" — decide, don't let it drift.
                Text(verbatim: "\(draft.trimmedCaption.count)/\(NewMediaPostDraft.captionMaxLength)")
                    .font(BrandFont.mono(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Who can see this?")
            HStack(spacing: 8) {
                privacyPill("Public", isSelected: !draft.isPrivate) { draft.isPrivate = false }
                privacyPill("Private (only you)", isSelected: draft.isPrivate) { draft.isPrivate = true }
            }
            if draft.isPrivate {
                Text("Only you can see this. It won’t appear in the Looks feed or your public portfolio. You can make it public later from your media library.")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func privacyPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(isSelected ? BrandColor.onAccent : BrandColor.textSecondary)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(isSelected ? BrandColor.accent : BrandColor.bgSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(posting)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Surfaces

    private var surfacesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("Where it shows")
            Toggle(isOn: $draft.isEligibleForLooks) {
                toggleLabel("Show in Looks", "Appears in the public Looks discovery feed.")
            }
            .tint(BrandColor.accent)
            .disabled(posting)

            Toggle(isOn: $draft.isFeaturedInPortfolio) {
                toggleLabel("Show in Portfolio", "Shows on your public profile.")
            }
            .tint(BrandColor.accent)
            .disabled(posting)
        }
    }

    // MARK: - Services

    @ViewBuilder
    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Tag services (pick at least 1)")
            if !optionsLoaded {
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                    .padding(.vertical, 20)
            } else if optionsFailed {
                Text("Couldn’t load your services. Close and reopen to try again.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.ember)
            } else {
                ProServiceTagPicker(
                    options: serviceOptions,
                    selectedServiceIds: $draft.serviceIds,
                    emptyMessage: serviceOptions.isEmpty
                        ? "No services found. Add at least one service before posting."
                        : "Tag at least 1 service before posting.",
                    isDisabled: posting
                )
            }
        }
    }

    // MARK: - Looks settings

    private var looksSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if draft.serviceIds.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Primary service")
                    Picker("Primary service", selection: $draft.primaryServiceId) {
                        Text("Choose the primary service for Looks").tag(String?.none)
                        ForEach(selectedTags) { tag in
                            Text(tag.name).tag(String?.some(tag.serviceId))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(BrandColor.textPrimary)
                    .disabled(posting)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Looks visibility")
                Picker("Looks visibility", selection: $draft.lookVisibility) {
                    ForEach(LookVisibility.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(posting)
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Starting price (optional)")
                TextField("85.00", text: $draft.priceStartingAt)
                    .keyboardType(.decimalPad)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .background(BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(posting)
                    .onChange(of: draft.priceStartingAt) { _, value in
                        let normalized = NewMediaPostDraft.normalizePriceInput(value)
                        if normalized != value { draft.priceStartingAt = normalized }
                    }
                Text("This will publish to Looks now.")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private var selectedTags: [ProMediaServiceTag] {
        draft.serviceIds.compactMap { id in serviceOptions.first { $0.serviceId == id } }
    }

    // MARK: - Gate + submit

    private var blockingBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Before you can post:")
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
            ForEach(blockingReasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: "•").font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    Text(reason).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BrandColor.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
            )
    }

    private var postButton: some View {
        Button { Task { await post() } } label: {
            HStack(spacing: 8) {
                if posting { ProgressView().tint(BrandColor.onAccent) }
                Text(posting ? "Posting…" : "Post")
                    .font(BrandFont.body(15, .semibold))
            }
            .foregroundStyle(BrandColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canPost ? BrandColor.accent : BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canPost)
    }

    // MARK: - Actions

    private func handlePick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        // Reset the binding so re-picking the SAME photo re-fires onChange —
        // otherwise a retry after a failed read is a dead tap (the value didn't
        // change). Same reason `ShareLookView.handlePick` does it; the nil write
        // re-enters here and returns at the guard above.
        pick = nil

        // Two picks in flight can finish out of order (a big HEIC decode + the
        // face pass take a moment), and the loser would silently overwrite the
        // winner. Stamp each run and let only the newest commit — web guards the
        // same race with `prepareRequestIdRef`.
        pickGeneration &+= 1
        let generation = pickGeneration

        errorMessage = nil
        draft.image = .loading
        preview = nil
        focal = nil
        imageData = nil

        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data)
        else {
            if generation == pickGeneration { draft.image = .failed }
            return
        }

        // Re-encode rather than ship the original: a HEIC or a 12MP PNG is both
        // huge and not what the feed renders. Same 0.85 the share-look flow uses.
        let jpeg = image.jpegData(compressionQuality: 0.85) ?? data
        guard generation == pickGeneration else { return }
        preview = image
        imageData = jpeg
        draft.image = .ready(byteCount: jpeg.count)

        // The same on-device face detection the camera runs. No face (a nails or
        // hair-detail shot) → nil → the server centers, exactly like web's posts.
        let report = await PhotoQC.evaluate(jpeg, checkBlink: false)
        guard generation == pickGeneration else { return }
        focal = MediaFocalPoint(faceCenter: report.focalPoint)
    }

    private func post() async {
        guard canPost, let imageData else { return }
        posting = true
        errorMessage = nil
        defer { posting = false }

        do {
            _ = try await session.client.proMedia.createPost(
                draft: draft,
                imageData: imageData,
                focal: focal
            )
            onPosted()
            dismiss()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t post that. Try again."
        }
    }

    // MARK: - Chrome

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
            .foregroundStyle(BrandColor.textMuted)
    }

    private func toggleLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text(subtitle).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
        }
    }
}
