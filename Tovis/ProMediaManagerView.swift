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
//   - The before/after pairing picker is a separate increment; a core edit omits
//     `beforeAssetId`, so it never clobbers the server's auto-pairing.
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
        .sheet(item: $editing) { item in
            if case let .loaded(_, options) = phase {
                ProMediaEditSheet(item: item, serviceOptions: options) {
                    Task { await load() }
                }
            }
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
        Text("No media yet. Upload your work from a session, a review, or your portfolio and it will show up here.")
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
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
    @State private var selectedServiceIds: Set<String>
    @State private var serviceQuery = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var viewingMedia: FullscreenMedia?

    private let captionMax = 300

    init(item: ProManagedMediaItem, serviceOptions: [ProMediaServiceTag], onSaved: @escaping () -> Void) {
        self.item = item
        self.serviceOptions = serviceOptions
        self.onSaved = onSaved
        _caption = State(initialValue: item.caption ?? "")
        _isEligibleForLooks = State(initialValue: item.isEligibleForLooks)
        _isFeaturedInPortfolio = State(initialValue: item.isFeaturedInPortfolio)
        _selectedServiceIds = State(initialValue: Set(item.serviceIds))
    }

    /// Public when either surface is on — matches the server's
    /// `normalizeVisibilityFromFlags`, which always derives visibility.
    private enum Visibility: String, CaseIterable, Identifiable {
        case pub = "Public"
        case client = "Client + you"
        var id: String { rawValue }
    }

    private var computedVisibility: Visibility {
        (isEligibleForLooks || isFeaturedInPortfolio) ? .pub : .client
    }

    private var canSave: Bool { !saving && !selectedServiceIds.isEmpty }

    private var filteredOptions: [ProMediaServiceTag] {
        let q = serviceQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return serviceOptions }
        return serviceOptions.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    captionField
                    visibilitySection
                    servicesSection

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }

                    deleteButton
                }
                .padding(20)
            }
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

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Service tags")

            if !selectedServiceIds.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(selectedTags) { tag in
                        Button { selectedServiceIds.remove(tag.serviceId) } label: {
                            HStack(spacing: 5) {
                                Text(tag.name).font(BrandFont.body(12, .semibold))
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(BrandColor.onAccent)
                            .padding(.vertical, 6).padding(.horizontal, 11)
                            .background(BrandColor.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Attach at least 1 service before saving.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.ember)
            }

            TextField("Search services", text: $serviceQuery)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredOptions) { option in
                        optionRow(option)
                        if option.id != filteredOptions.last?.id {
                            Divider().overlay(BrandColor.textMuted.opacity(0.12))
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func optionRow(_ option: ProMediaServiceTag) -> some View {
        let selected = selectedServiceIds.contains(option.serviceId)
        return Button {
            if selected { selectedServiceIds.remove(option.serviceId) }
            else { selectedServiceIds.insert(option.serviceId) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? BrandColor.accent : BrandColor.textMuted)
                Text(option.name)
                    .font(BrandFont.body(14, selected ? .semibold : .regular))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var selectedTags: [ProMediaServiceTag] {
        serviceOptions.filter { selectedServiceIds.contains($0.serviceId) }
    }

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
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await session.client.proMedia.updateMedia(
                mediaId: item.id,
                caption: trimmed.isEmpty ? nil : trimmed,
                isEligibleForLooks: isEligibleForLooks,
                isFeaturedInPortfolio: isFeaturedInPortfolio,
                serviceIds: Array(selectedServiceIds)
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
}
