// Pro media manager — the native counterpart of the web `/pro/media` grid +
// `OwnerMediaMenu` editor (both RSC-only on web, so there's a dedicated native
// read API). Lists the pro's own media across all visibilities; tapping a tile
// opens the editor to change its caption, its Looks / portfolio visibility, and
// its service tags, or to delete it.
//
// Backed by GET /api/v1/pro/media (list + taggable service options) and
// PATCH / DELETE /api/v1/pro/media/{id}. Reached from the Profile tab's Business
// section. Web parity notes:
//   - The grid shows plain thumbnails (matching web `MediaTile`); the before/after
//     comparison slider lives only on the public-facing portfolio/reviews views.
//   - Visibility is DERIVED from the two flags (Looks / portfolio), never stored
//     independently — the server recomputes it and ignores any sent value.
//   - The editor's before/after pairing picker only sends `beforeAssetId` once the
//     pro touches it (`pairingTouched`); an untouched save omits it, so it never
//     clobbers the server's auto-pairing.
import SwiftUI
import TovisKit

struct ProMediaManagerView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ProManagedMediaItem], options: [ProMediaServiceTag])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var editing: ProManagedMediaItem?
    @State private var composing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Manage posts and choose where each appears — your public portfolio, the Looks feed, or just you and the client.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(items, options):
                    if items.isEmpty {
                        emptyState
                    } else {
                        grid(items, options: options)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("My media")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { composing = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New post")
            }
        }
        .sheet(item: $editing) { item in
            if case let .loaded(_, options) = phase {
                ProMediaEditSheet(item: item, serviceOptions: options) {
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $composing) {
            ProNewMediaPostView { Task { await load() } }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Grid

    private func grid(_ items: [ProManagedMediaItem], options: [ProMediaServiceTag]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 10
        ) {
            ForEach(items) { item in
                Button { editing = item } label: { tile(item) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func tile(_ item: ProManagedMediaItem) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BrandColor.bgSecondary)
            if let str = item.displayThumbUrl, let url = URL(string: str) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(BrandColor.accent)
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                if item.isFeaturedInPortfolio {
                    badge("★", tint: BrandColor.accent, fg: BrandColor.onAccent)
                }
                if item.isEligibleForLooks {
                    badge("Looks", tint: BrandColor.bgPrimary.opacity(0.72), fg: BrandColor.textPrimary)
                }
            }
            .padding(6)

            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Edit media")
    }

    private func badge(_ text: String, tint: Color, fg: Color) -> some View {
        Text(text)
            .font(BrandFont.mono(8))
            .foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(tint)
            .clipShape(Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            // Was "…it will show up here" — accurate while media could only arrive
            // from a session, a review or the web portfolio. The + makes this the
            // place posts START, so the copy points at it.
            Text("No media yet. Tap + to post your work, or add it from a session or a review.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)

            Button { composing = true } label: {
                Text("New post")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 11).padding(.horizontal, 20)
                    .background(BrandColor.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
        .padding(.top, 50)
    }

    private func load() async {
        do {
            let response = try await session.client.proMedia.listManagedMedia()
            phase = .loaded(response.items, options: response.serviceOptions)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your media.")
        }
    }
}

// MARK: - Edit sheet

/// The native counterpart of the web `OwnerMediaMenu` edit modal. Edits one
/// library asset: caption, a derived Public / Client-you visibility, the Looks &
/// portfolio flags, and the service tags (full-replacement set) — and can delete
/// it. `onSaved` reloads the grid so it reflects the server-recomputed visibility
/// and any auto-pairing.
struct ProMediaEditSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let item: ProManagedMediaItem
    let serviceOptions: [ProMediaServiceTag]
    var onSaved: () -> Void

    @State private var caption: String
    @State private var isEligibleForLooks: Bool
    @State private var isFeaturedInPortfolio: Bool
    @State private var selectedServiceIds: [String]
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var viewingMedia: FullscreenMedia?

    // §18d — creator-page cover banner. Optimistic so the label flips instantly;
    // seeded from the item's server-truth flag. Images only (a video can't back a
    // cover hero — the server 400s), so the section is hidden for videos.
    @State private var isCover: Bool
    @State private var updatingCover = false

    // Before/after pairing. `beforeAssetId` is the chosen "before" (nil = unpaired);
    // `pairingTouched` gates whether we send it at all, so a normal save never
    // clobbers the server's default-on auto-pairing (mirrors web `OwnerMediaMenu`).
    @State private var beforeAssetId: String?
    @State private var pairingTouched = false
    @State private var beforeOptions: [ProMediaBeforeOption] = []
    @State private var beforeOptionsLoaded = false

    private let captionMax = 300

    init(item: ProManagedMediaItem, serviceOptions: [ProMediaServiceTag], onSaved: @escaping () -> Void) {
        self.item = item
        self.serviceOptions = serviceOptions
        self.onSaved = onSaved
        _caption = State(initialValue: item.caption ?? "")
        _isEligibleForLooks = State(initialValue: item.isEligibleForLooks)
        _isFeaturedInPortfolio = State(initialValue: item.isFeaturedInPortfolio)
        _selectedServiceIds = State(initialValue: item.serviceIds)
        _beforeAssetId = State(initialValue: item.beforeAssetId)
        _isCover = State(initialValue: item.isCoverMedia)
    }

    /// Public when either surface is on — matches the server's
    /// `normalizeVisibilityFromFlags`, which always derives visibility.
    private enum Visibility: String, CaseIterable, Identifiable {
        case pub = "Public"
        case client = "Client + you"
        var id: String { rawValue }
    }

    private var computedVisibility: Visibility {
        // The rule lives on the TovisKit model (shared with the new-post composer
        // and covered by `swift test`); this view only maps it to its own labels.
        MediaPostVisibility.derived(
            isEligibleForLooks: isEligibleForLooks,
            isFeaturedInPortfolio: isFeaturedInPortfolio
        ) == .pub ? .pub : .client
    }

    private var canSave: Bool { !saving && !selectedServiceIds.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    captionField
                    visibilitySection
                    if !item.isVideo { coverSection }
                    if !item.isVideo { pairingSection }
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
            .navigationTitle("Edit media")
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
            .alert("Delete this media?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { Task { await deleteMedia() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can’t be undone.")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var preview: some View {
        Button {
            viewingMedia = FullscreenMedia.remote(id: item.id, urlString: item.displayUrl, isVideo: false)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BrandColor.bgSecondary)
                if let str = item.displayUrl, let url = URL(string: str) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(BrandColor.accent)
                    }
                } else {
                    Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(BrandColor.textMuted)
                }
                if item.isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9))
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

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("Where it shows")
            Picker("Visibility", selection: Binding(
                get: { computedVisibility },
                set: { setVisibility($0) }
            )) {
                ForEach(Visibility.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $isEligibleForLooks) {
                toggleLabel("Show in Looks feed", "Appears in the public Looks discovery feed.")
            }
            .tint(BrandColor.accent)

            Toggle(isOn: $isFeaturedInPortfolio) {
                toggleLabel("Feature in public portfolio", "Shows on your public profile.")
            }
            .tint(BrandColor.accent)

            Text("Turning either on makes this photo public; turning both off keeps it to you and the client.")
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    /// §18d — set/clear this photo as the pro's public profile cover banner.
    /// Mirrors the web `OwnerMediaMenu` "Set as cover" ↔ "Remove cover" action:
    /// images only, and the server gates it (a private/unpromoted session photo
    /// 403s, surfaced inline). Optimistic label; reloads the grid so a previously
    /// -cover tile clears.
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
                options: serviceOptions,
                selectedServiceIds: $selectedServiceIds,
                emptyMessage: "Attach at least 1 service before saving.",
                isDisabled: saving
            )
        }
    }

    // MARK: Before / after pairing (images only)

    /// Pair a "before" photo with this "after" so the public portfolio shows a
    /// comparison slider. Mirrors the web `OwnerMediaMenu` picker: a "None" chip +
    /// the booking's candidate befores, lazily loaded. Only a touch flips
    /// `pairingTouched`, so leaving it alone preserves server auto-pairing.
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
                   let afterStr = item.displayUrl,
                   let beforeURL = URL(string: before.thumbUrl),
                   let afterURL = URL(string: afterStr) {
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
        guard !item.isVideo, !beforeOptionsLoaded else { return }
        do {
            beforeOptions = try await session.client.proMedia.beforeOptions(mediaId: item.id)
        } catch {
            // Non-fatal: a failed pairing lookup shouldn't block the rest of the
            // edit. Fall through to the "no befores" empty state.
        }
        beforeOptionsLoaded = true
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirmingDelete = true } label: {
            Text("Delete media")
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

    private func setVisibility(_ v: Visibility) {
        switch v {
        case .pub:
            // Turning "Public" on with neither surface set defaults to the portfolio.
            if !(isEligibleForLooks || isFeaturedInPortfolio) { isFeaturedInPortfolio = true }
        case .client:
            isEligibleForLooks = false
            isFeaturedInPortfolio = false
        }
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t)
            .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
            .foregroundStyle(BrandColor.textMuted)
    }

    private func toggleLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text(subtitle).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proMedia.updateMedia(
                mediaId: item.id,
                caption: caption.trimmedOrNil,
                isEligibleForLooks: isEligibleForLooks,
                isFeaturedInPortfolio: isFeaturedInPortfolio,
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
            try await session.client.proMedia.deleteMedia(mediaId: item.id)
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t delete this media. Try again."
        }
    }

    /// Toggle this photo as the profile cover (§18d). Optimistic label flip on
    /// success; reloads the grid (mirrors web's `router.refresh()`) so any tile
    /// that was the cover clears. The sheet stays open. A server refusal (403
    /// consent gate / 400 non-image) surfaces inline and the label doesn't flip.
    private func toggleCover() async {
        guard !updatingCover, !saving else { return }
        updatingCover = true
        error = nil
        defer { updatingCover = false }
        let next = !isCover
        do {
            if next {
                try await session.client.proMedia.setCover(mediaId: item.id)
            } else {
                try await session.client.proMedia.removeCover(mediaId: item.id)
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
