// Editing the ASSET — caption, cover, before/after pairing, service tags — and
// the one irreversible action. Opened from a library tile's sheet.
//
// This used to be reachable only from "My media" (`ProMediaManagerView`), a
// second grid of the same photos whose only unique power was this editor. A pro
// who wanted to fix a caption on a public photo had to leave the library that
// shows the caption, find the photo again in a different grid, and edit it
// there. That screen is gone; this is what it was for.
//
// 🔴 No visibility control, on purpose. The old sheet drew two independent
// toggles (Looks / portfolio) that the server WELDS together, which was a lie
// the pro had to unlearn the first time they used it. Public-vs-private is the
// publish / make-private act in `ProPortfolioSheet`, and this sheet's save sends
// neither flag — so fixing a caption can never move a photo. Web's shared
// `ProMediaEditFields` renders exactly the same set for exactly this reason.
import SwiftUI
import TovisKit

struct ProMediaEditSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let tile: ProLibraryTile
    let serviceOptions: [ProLibraryServiceOption]
    var onSaved: () -> Void

    @State private var caption: String
    @State private var selectedServiceIds: [String]
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var viewingMedia: FullscreenMedia?

    // §18d — creator-page cover banner. Optimistic so the label flips instantly;
    // seeded from the tile's mark, which is server truth. Images only (a video
    // can't back a cover hero — the server 400s), so it's hidden for videos.
    @State private var isCover: Bool
    @State private var updatingCover = false

    // Before/after pairing. `beforeAssetId` is the chosen "before" (nil =
    // unpaired); `pairingTouched` gates whether we send it at all, so a normal
    // save never clobbers the server's default-on auto-pairing.
    @State private var beforeAssetId: String?
    @State private var pairingTouched = false
    @State private var beforeOptions: [ProMediaBeforeOption] = []
    @State private var beforeOptionsLoaded = false

    private let captionMax = 300

    init(
        tile: ProLibraryTile,
        serviceOptions: [ProLibraryServiceOption],
        onSaved: @escaping () -> Void
    ) {
        self.tile = tile
        self.serviceOptions = serviceOptions
        self.onSaved = onSaved
        _caption = State(initialValue: tile.caption ?? "")
        _selectedServiceIds = State(initialValue: tile.serviceIds)
        // 🔴 The STORED pairing, not `tile.before` — that one is nil whenever the
        // pair can't be drawn, which would show "None" over a real pairing.
        _beforeAssetId = State(initialValue: tile.beforeAssetId)
        _isCover = State(initialValue: tile.mark == .cover || tile.mark == .signatureCover)
    }

    private var canSave: Bool { !saving && !selectedServiceIds.isEmpty }

    private var tagOptions: [ProMediaServiceTag] {
        serviceOptions.map(\.asServiceTag)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    captionField
                    if !tile.isVideo { coverSection }
                    if !tile.isVideo { pairingSection }
                    servicesSection

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }

                    deleteButton
                }
                .padding(20)
            }
            .task { await loadBeforeOptions() }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Edit details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
            .mediaFullscreenCover($viewingMedia)
            .alert("Delete this photo?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { Task { await deleteMedia() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It leaves your library, your profile and anywhere a client saved it. This can’t be undone.")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var preview: some View {
        Button {
            // The pro's own library asset — save the original, or make a post
            // from it.
            //
            // No diptych here, on purpose: `ProMediaBeforeOption` carries only a
            // `thumbUrl`, which is fine for the pairing picker and the preview
            // slider but would export a visibly soft half. The session hub pairs
            // from two full-resolution assets and offers the diptych there.
            viewingMedia = FullscreenMedia.proOwned(
                id: tile.id,
                urlString: tile.src,
                isVideo: tile.isVideo
            )
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BrandColor.bgSecondary)
                if let url = URL(string: tile.src) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(BrandColor.accent)
                    }
                } else {
                    Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(BrandColor.textMuted)
                }
                if tile.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(BrandColor.textPrimary.opacity(0.9))
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var captionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Caption")
            TextEditor(text: $caption)
                .frame(minHeight: 90)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .onChange(of: caption) {
                    if caption.count > captionMax { caption = String(caption.prefix(captionMax)) }
                }
            Text("\(caption.count)/\(captionMax)")
                .font(BrandFont.mono(11))
                .foregroundStyle(BrandColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// §18d — set/clear this photo as the pro's public profile cover banner.
    /// The server gates it: images only, and consent-checked — an unpromoted
    /// private session photo 403s, surfaced inline. Optimistic label; the caller
    /// reloads so a previously-cover tile clears its chip.
    @ViewBuilder
    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Profile cover")
            Text(isCover
                 ? "This photo is the banner at the top of your public profile."
                 : "Feature this photo as the banner at the top of your public profile.")
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)

            Button {
                Task { await toggleCover() }
            } label: {
                HStack(spacing: 8) {
                    if updatingCover {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        Image(systemName: isCover ? "checkmark.seal.fill" : "photo.on.rectangle")
                    }
                    Text(isCover ? "Remove as cover" : "Set as cover")
                        .font(BrandFont.body(14, .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(isCover ? BrandColor.textPrimary : BrandColor.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke((isCover ? BrandColor.textMuted : BrandColor.accent).opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(saving || updatingCover)
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Service tags")
            // Shared with the new-post composer — one picker, one behavior.
            ProServiceTagPicker(
                options: tagOptions,
                selectedServiceIds: $selectedServiceIds,
                emptyMessage: "Attach at least 1 service before saving.",
                isDisabled: saving
            )
        }
    }

    // MARK: Before / after pairing (images only)

    /// Pair a "before" photo with this "after" so the public portfolio shows a
    /// comparison slider: a "None" chip plus the booking's candidate befores,
    /// lazily loaded. Only a touch flips `pairingTouched`, so leaving it alone
    /// preserves the server's auto-pairing.
    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Before / after")
            Text("Pair a “before” photo to show a comparison slider on your public portfolio.")
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)

            if !beforeOptionsLoaded {
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                    .frame(height: 72)
            } else if beforeOptions.isEmpty && beforeAssetId == nil {
                Text("No before photos from this booking to pair.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                // Live payoff: when a before is chosen and resolvable, preview the
                // resulting comparison slider right in the editor.
                if let before = selectedBeforeOption,
                   let beforeURL = URL(string: before.thumbUrl),
                   let afterURL = URL(string: tile.src) {
                    BeforeAfterCompareView(beforeURL: beforeURL, afterURL: afterURL, height: 200, cornerRadius: 12)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        noneChip
                        ForEach(beforeOptions) { beforeChip($0) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var noneChip: some View {
        let selected = beforeAssetId == nil
        return Button {
            beforeAssetId = nil
            pairingTouched = true
        } label: {
            Text("None")
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(selected ? BrandColor.onAccent : BrandColor.textSecondary)
                .frame(width: 64, height: 64)
                .background(selected ? BrandColor.accent : BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? BrandColor.accent : BrandColor.textMuted.opacity(0.2),
                                lineWidth: selected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityLabel("No before/after pairing")
    }

    private func beforeChip(_ option: ProMediaBeforeOption) -> some View {
        let selected = beforeAssetId == option.id
        return Button {
            beforeAssetId = option.id
            pairingTouched = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BrandColor.bgSecondary)
                if let url = URL(string: option.thumbUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(BrandColor.accent)
                    }
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(BrandColor.accent)
                        .padding(3)
                        .background(Circle().fill(BrandColor.bgPrimary.opacity(0.85)))
                        .padding(3)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? BrandColor.accent : BrandColor.textMuted.opacity(0.2),
                            lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityLabel(option.phase == .before ? "Before photo" : "Photo from this booking")
    }

    private var selectedBeforeOption: ProMediaBeforeOption? {
        guard let id = beforeAssetId else { return nil }
        return beforeOptions.first { $0.id == id }
    }

    private func loadBeforeOptions() async {
        guard !tile.isVideo, !beforeOptionsLoaded else { return }
        do {
            beforeOptions = try await session.client.proMedia.beforeOptions(mediaId: tile.id)
        } catch {
            // Non-fatal: a failed pairing lookup shouldn't block the rest of the
            // edit. Fall through to the "no befores" empty state.
        }
        beforeOptionsLoaded = true
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirmingDelete = true } label: {
            Text("Delete this photo")
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.ember)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    // MARK: Helpers

    private func fieldLabel(_ t: String) -> some View {
        Text(t)
            .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
            .foregroundStyle(BrandColor.textMuted)
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            // 🔴 No visibility flags. Omitting them leaves both stored flags
            // alone server-side; sending `false` would silently retract a public
            // photo the pro only meant to re-tag.
            try await session.client.proMedia.updateMedia(
                mediaId: tile.id,
                caption: caption.trimmedOrNil,
                serviceIds: selectedServiceIds,
                // Only send the pairing when the pro actually touched the picker,
                // so a normal save never clobbers server auto-pairing.
                pairing: pairingTouched ? .set(beforeAssetId) : .untouched
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save your changes. Try again."
        }
    }

    private func deleteMedia() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proMedia.deleteMedia(mediaId: tile.id)
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t delete this photo. Try again."
        }
    }

    /// Toggle this photo as the profile cover (§18d). Optimistic label flip on
    /// success; the caller reloads so any tile that was the cover clears its
    /// chip. The sheet stays open. A server refusal (403 consent gate / 400
    /// non-image) surfaces inline and the label doesn't flip.
    private func toggleCover() async {
        guard !updatingCover, !saving else { return }
        updatingCover = true
        error = nil
        defer { updatingCover = false }
        let next = !isCover
        do {
            if next {
                try await session.client.proMedia.setCover(mediaId: tile.id)
            } else {
                try await session.client.proMedia.removeCover(mediaId: tile.id)
            }
            isCover = next
            onSaved()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t update your cover photo. Try again."
        }
    }
}
