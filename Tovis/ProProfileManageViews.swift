// Pro profile management — the edit sheet (PATCH /pro/profile) and the services
// manager (GET /pro/offerings + toggle active / edit price+duration / remove).
// Ports the web `/pro/profile/public-profile` edit affordances + the services
// manager section. Reached from `ProProfileTabView`.
import SwiftUI
import PhotosUI
import TovisKit

// MARK: - Edit profile

/// Native port of the web Edit profile modal (EditProfileButton.tsx), 1:1: handle
/// with a live availability check + suggestions, business name, name-display as 3
/// option cards with hints, profession type, location, avatar upload (on Save),
/// and bio. Avatar uploads to AVATAR_PUBLIC at save time, then PATCH /pro/profile.
struct ProEditProfileSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let profile: ProMyProfile
    /// Whether the handle is editable (web `canEditHandle` = the pro is approved).
    var canEditHandle: Bool = true
    /// Called with the saved profile so the tab can refresh in place.
    var onSaved: (ProMyProfile) -> Void

    @State private var businessName: String
    @State private var professionType: String
    @State private var handle: String
    @State private var bio: String
    @State private var location: String
    @State private var avatarUrl: String
    @State private var nameDisplay: String
    @State private var instagramHandle: String
    @State private var tiktokHandle: String
    @State private var websiteUrl: String

    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data?

    @State private var handleCheck: ProHandleAvailability?
    @State private var checkingHandle = false
    @State private var handleCheckTask: Task<Void, Never>?

    @State private var saving = false
    @State private var uploadingAvatar = false
    @State private var error: String?

    /// The three name-display options + their hints, verbatim from the web
    /// `NAME_DISPLAY_OPTIONS` (values are Prisma `ProNameDisplay`).
    private let nameDisplayOptions: [(value: String, label: String, hint: String)] = [
        ("BUSINESS_NAME", "Business", "Show your business name (your real name if none is set)."),
        ("REAL_NAME", "Real name", "Show your first and last name."),
        ("HANDLE", "Handle", "Show your @handle."),
    ]

    init(profile: ProMyProfile, canEditHandle: Bool = true, onSaved: @escaping (ProMyProfile) -> Void) {
        self.profile = profile
        self.canEditHandle = canEditHandle
        self.onSaved = onSaved
        _businessName = State(initialValue: profile.businessName ?? "")
        _professionType = State(initialValue: profile.professionType ?? "")
        _handle = State(initialValue: profile.handle ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _location = State(initialValue: profile.location ?? "")
        _avatarUrl = State(initialValue: profile.avatarUrl ?? "")
        _nameDisplay = State(initialValue: profile.nameDisplay ?? "BUSINESS_NAME")
        _instagramHandle = State(initialValue: profile.instagramHandle ?? "")
        _tiktokHandle = State(initialValue: profile.tiktokHandle ?? "")
        _websiteUrl = State(initialValue: profile.websiteUrl ?? "")
    }

    private var busy: Bool { saving || uploadingAvatar }

    /// Sanitized handle (lowercase, [a-z0-9-]) — mirrors the web `sanitizeHandleInput`.
    private var handlePreview: String {
        handle.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
    private var vanityPreview: String? {
        handlePreview.isEmpty ? nil : "\(handlePreview).tovis.me"
    }
    private var handleBlocked: Bool { handleCheck?.isBlocking ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    handleSection
                    field(title: "Business name", text: $businessName, placeholder: "e.g. Lumara Beauty")
                    nameDisplaySection
                    field(title: "Profession type", text: $professionType, placeholder: "e.g. MAKEUP_ARTIST", autocap: false)
                    field(title: "Location", text: $location, placeholder: "e.g. San Diego, CA")
                    socialSection
                    avatarSection
                    bioSection

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary).disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(statusText ?? "Save") { Task { await save() } }
                        .disabled(busy || handleBlocked)
                        .tint(BrandColor.accent)
                }
            }
            .onChange(of: handle) { scheduleHandleCheck() }
            .onChange(of: avatarItem) { Task { await loadAvatar() } }
            .onDisappear { handleCheckTask?.cancel() }
            .tint(BrandColor.accent)
        }
    }

    private var statusText: String? {
        uploadingAvatar ? "Uploading…" : (saving ? "Saving…" : nil)
    }

    // MARK: - Handle

    private var handleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Handle (vanity link)")
            TextField("e.g. tori", text: $handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(12)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(busy || !canEditHandle)

            vanityPreviewBox

            if canEditHandle, vanityPreview != nil {
                handleStatusLine
            }

            if canEditHandle, let suggestions = handleCheck?.suggestions, !suggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Try:").font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { handle = s }
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.vertical, 4).padding(.horizontal, 10)
                            .background(BrandColor.bgSecondary).clipShape(Capsule())
                            .disabled(busy)
                    }
                }
            }

            if canEditHandle, !profile.isPremium {
                Text("You can reserve a handle now. Your .tovis.me link activates after upgrading.")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
            }

            Text("Allowed: letters, numbers, hyphens. No spaces. Must start/end with a letter or number.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
        }
    }

    @ViewBuilder private var vanityPreviewBox: some View {
        Group {
            if canEditHandle {
                if let preview = vanityPreview {
                    (Text("Vanity link: ").foregroundStyle(BrandColor.textSecondary)
                        + Text(preview).foregroundStyle(BrandColor.textPrimary).bold()
                        + Text("  ")
                        + Text(profile.isPremium ? "Active" : "Reserved (Premium required)")
                            .foregroundStyle(profile.isPremium ? BrandColor.textPrimary : BrandColor.textSecondary).bold())
                } else {
                    Text("Pick a handle to preview your vanity link.").foregroundStyle(BrandColor.textSecondary)
                }
            } else {
                Text("Your public profile link unlocks after approval. You can finish the rest of your profile now.")
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
        .font(BrandFont.body(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BrandColor.bgSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var handleStatusLine: some View {
        if checkingHandle {
            Text("Checking…").font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
        } else if let check = handleCheck {
            Text("\(check.isPositive ? "✓ " : "• ")\(check.message)")
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(check.isPositive ? BrandColor.emerald : (check.status == "taken" ? BrandColor.ember : BrandColor.gold))
        }
    }

    private func scheduleHandleCheck() {
        error = nil
        handleCheckTask?.cancel()
        let candidate = handlePreview
        let initial = (profile.handle ?? "").lowercased()
        guard canEditHandle, !candidate.isEmpty, candidate != initial else {
            handleCheck = nil
            checkingHandle = false
            return
        }
        checkingHandle = true
        handleCheckTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let result = try? await session.client.proProfile.handleAvailable(candidate)
            if Task.isCancelled { return }
            await MainActor.run {
                if let result { handleCheck = result }
                checkingHandle = false
            }
        }
    }

    // MARK: - Name display

    private var nameDisplaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Display your name as")
            HStack(spacing: 6) {
                ForEach(nameDisplayOptions, id: \.value) { option in
                    let active = nameDisplay == option.value
                    Button(option.label) { nameDisplay = option.value }
                        .font(BrandFont.body(12, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(active ? BrandColor.accent : BrandColor.bgSecondary)
                        .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(busy)
                }
            }
            Text(nameDisplayOptions.first { $0.value == nameDisplay }?.hint ?? "")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - Social presence

    /// Public social links shown as chips on the profile (web PR #478). The
    /// server strips a leading "@" from handles and coerces the website to
    /// https://; leaving a field empty clears it.
    private var socialSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Social presence")
            field(title: "", text: $instagramHandle, placeholder: "Instagram handle (e.g. tori.hair)", autocap: false)
            field(title: "", text: $tiktokHandle, placeholder: "TikTok handle (e.g. tori.hair)", autocap: false)
            field(title: "", text: $websiteUrl, placeholder: "Website (e.g. tori.com)", autocap: false)
            Text("Shown as tappable chips on your public profile. Leave a field blank to remove its chip.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - Avatar + bio

    private var avatarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Avatar")
            HStack(spacing: 12) {
                avatarThumb
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    Text("Choose photo")
                        .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.accent)
                }
                .disabled(busy)
            }
            Text("Selecting a file does not upload yet. Upload happens when you click Save.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
            field(title: "", text: $avatarUrl, placeholder: "Avatar URL (fallback)", autocap: false)
        }
    }

    @ViewBuilder private var avatarThumb: some View {
        let trimmed = avatarUrl.trimmingCharacters(in: .whitespaces)
        ZStack {
            if let data = avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = URL(string: trimmed), !trimmed.isEmpty {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { BrandColor.bgSecondary }
            } else {
                BrandColor.bgSecondary
                Text("🙂").font(.system(size: 18))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1))
    }

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Bio")
            TextEditor(text: $bio)
                .frame(minHeight: 100)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
        }
    }

    private func loadAvatar() async {
        guard let item = avatarItem else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            avatarData = data
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String, autocap: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { fieldLabel(title) }
            TextField(placeholder, text: text)
                .textInputAutocapitalization(autocap ? .sentences : .never)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(12)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(busy)
        }
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(BrandFont.mono(10)).tracking(0.8)
            .foregroundStyle(BrandColor.textMuted)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }

        // Upload a freshly-picked avatar first (web uploads on Save), then PATCH.
        var nextAvatarUrl = avatarUrl.trimmingCharacters(in: .whitespaces)
        if let data = avatarData {
            uploadingAvatar = true
            do {
                nextAvatarUrl = try await session.client.proMedia.uploadAvatar(imageData: data)
            } catch let e as APIError {
                uploadingAvatar = false
                error = e.userMessage
                return
            } catch {
                uploadingAvatar = false
                self.error = "Couldn’t upload your avatar. Try again."
                return
            }
            uploadingAvatar = false
        }

        do {
            let saved = try await session.client.proProfile.updateProfileFull(
                businessName: businessName,
                professionType: professionType,
                location: location,
                bio: bio,
                avatarUrl: nextAvatarUrl,
                nameDisplay: nameDisplay,
                handle: canEditHandle ? handle : nil,
                instagramHandle: instagramHandle.trimmingCharacters(in: .whitespaces),
                tiktokHandle: tiktokHandle.trimmingCharacters(in: .whitespaces),
                websiteUrl: websiteUrl.trimmingCharacters(in: .whitespaces)
            )
            onSaved(saved)
            session.signalRefresh()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save your profile. Try again."
        }
    }
}

// MARK: - Services manager

struct ProOfferingsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded([ProOfferingAdmin]), failed(String) }
    @State private var phase: Phase = .loading
    @State private var editing: ProOfferingAdmin?
    @State private var busyId: String?
    @State private var showAdd = false
    /// Write failures. `phase.failed` only covers LOAD errors — a rejected
    /// PATCH/DELETE still has to reload (the server is the truth about the row),
    /// so without this the row just snaps back with no explanation.
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                addServiceCard

                if let actionError {
                    BrandErrorBanner(message: actionError)
                }

                Text("Your current offerings")
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Edit pricing, durations, add-ons, and your custom service image (only your menu).")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                case let .loaded(items):
                    if items.isEmpty {
                        Text("You haven't added any services yet.")
                            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 30)
                    } else {
                        ForEach(items) { row($0) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        // A successful save through either sheet clears a stale write error —
        // otherwise a banner from an earlier failed toggle sits there
        // contradicting the edit the pro just watched succeed.
        .sheet(item: $editing) { offering in
            ProEditOfferingSheet(offering: offering) { actionError = nil; Task { await load() } }
        }
        .sheet(isPresented: $showAdd) {
            ProAddServiceSheet { actionError = nil; Task { await load() } }
        }
        .tint(BrandColor.accent)
    }

    private var addServiceCard: some View {
        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a service")
                        .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Text("Choose from the library. Your pricing. Platform-consistent names.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
                Button { showAdd = true } label: {
                    Text("+ Add")
                        .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        .background(BrandColor.bgSecondary).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ o: ProOfferingAdmin) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(o.serviceName)
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if let cat = o.categoryName {
                            Text(cat.uppercased()).font(BrandFont.mono(10)).tracking(0.6)
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { o.isActive },
                        set: { newValue in Task { await toggle(o, active: newValue) } }
                    ))
                    .labelsHidden()
                    .tint(BrandColor.accent)
                    .disabled(busyId == o.id)
                }

                HStack(spacing: 8) {
                    if o.offersInSalon, let p = o.salonPriceStartingAt {
                        priceChip(icon: "building.2", price: p, minutes: o.salonDurationMinutes)
                    }
                    if o.offersMobile, let p = o.mobilePriceStartingAt {
                        priceChip(icon: "car", price: p, minutes: o.mobileDurationMinutes)
                    }
                }

                HStack(spacing: 18) {
                    Button { editing = o } label: {
                        Text("Edit").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.accent)
                    }
                    NavigationLink {
                        ProAddOnsView(offering: o)
                    } label: {
                        Text("Add-ons").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.accent)
                    }
                    Spacer()
                    Button(role: .destructive) { Task { await remove(o) } } label: {
                        Text("Remove").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.ember)
                    }
                    .disabled(busyId == o.id)
                }
            }
        }
        .opacity(o.isActive ? 1 : 0.55)   // inactive services read as dimmed
    }

    private func priceChip(icon: String, price: String, minutes: Int?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(Wire.money(price) ?? price).font(BrandFont.body(12, .semibold))
            if let minutes { Text("· \(minutes)m").font(BrandFont.body(11)) }
        }
        .foregroundStyle(BrandColor.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BrandColor.bgSecondary)
        .clipShape(Capsule())
    }

    private func load() async {
        do { phase = .loaded(try await session.client.proProfile.offerings()) }
        catch let e as APIError { phase = .failed(e.userMessage) }
        catch { phase = .failed("Couldn’t load your services.") }
    }

    private func toggle(_ o: ProOfferingAdmin, active: Bool) async {
        busyId = o.id
        actionError = nil
        defer { busyId = nil }
        do {
            _ = try await session.client.proProfile.updateOffering(id: o.id, isActive: active)
        } catch let e as APIError {
            actionError = e.userMessage
        } catch {
            actionError = active
                ? "Couldn’t turn that service on. Try again."
                : "Couldn’t turn that service off. Try again."
        }
        // Reload either way: the server is the truth about the row, so a failed
        // write must snap back. The banner is what makes the snap-back legible.
        await load()
    }

    private func remove(_ o: ProOfferingAdmin) async {
        busyId = o.id
        actionError = nil
        defer { busyId = nil }
        do {
            try await session.client.proProfile.deleteOffering(id: o.id)
        } catch let e as APIError {
            actionError = e.userMessage
        } catch {
            actionError = "Couldn’t remove that service. Try again."
        }
        await load()
    }
}

// MARK: - Add a service (library picker)

/// Native port of the web Add-service overlay (ServicePicker.tsx), 1:1: category →
/// subcategory → service pickers (from GET /pro/services/catalog), an optional
/// service image upload, a description, and Salon/Mobile pricing → POST /pro/offerings.
struct ProAddServiceSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    var onSaved: () -> Void

    private enum Phase { case loading, ready, failed(String) }
    @State private var phase: Phase = .loading
    @State private var catalog: ProServiceCatalog?

    @State private var categoryId = ""
    @State private var subcategoryId = ""
    @State private var serviceId = ""

    @State private var description = ""
    @State private var offersInSalon = true
    @State private var offersMobile = false
    @State private var salonPrice = ""
    @State private var salonDuration = ""
    @State private var mobilePrice = ""
    @State private var mobileDuration = ""

    @State private var imageItem: PhotosPickerItem?
    @State private var imageData: Data?

    @State private var loading = false
    @State private var error: String?
    @State private var success: String?

    private var category: ProServiceCategory? { catalog?.categories.first { $0.id == categoryId } }
    private var subcategory: ProServiceSubcategory? { category?.children.first { $0.id == subcategoryId } }
    private var servicesForSelection: [ProCatalogService] {
        if let subcategory { return subcategory.services }
        if let category { return category.services + category.children.flatMap(\.services) }
        return []
    }
    private var selectedService: ProCatalogService? { servicesForSelection.first { $0.id == serviceId } }
    private var existingServiceIds: Set<String> { Set(catalog?.offerings.map(\.serviceId) ?? []) }
    private var alreadyAdded: Bool { selectedService.map { existingServiceIds.contains($0.id) } ?? false }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading: ProgressView().tint(BrandColor.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message): failed(message)
                case .ready: form
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Add a service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.tint(BrandColor.accent) } }
            .task { if case .loading = phase { await load() } }
            .onChange(of: imageItem) { Task { await loadImage() } }
            .tint(BrandColor.accent)
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pick from the library. Your pricing. Platform-consistent names.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                picker("Main category", selection: $categoryId, options: [("", "Select category")] + (catalog?.categories.map { ($0.id, $0.name) } ?? []))
                    .onChange(of: categoryId) { subcategoryId = ""; serviceId = ""; resetForService(nil) }

                picker("Subcategory", selection: $subcategoryId, options: [("", "All under this category")] + (category?.children.map { ($0.id, $0.name) } ?? []))
                    .disabled(category == nil)
                    .onChange(of: subcategoryId) { serviceId = ""; resetForService(nil) }

                picker("Service", selection: $serviceId, options: [("", "Select service")] + servicesForSelection.map { ($0.id, serviceLabel($0)) })
                    .disabled(category == nil)
                    .onChange(of: serviceId) { resetForService(servicesForSelection.first { $0.id == serviceId }) }

                if selectedService != nil {
                    serviceImageBlock
                    descriptionBlock
                    modeToggles
                    pricingBlock
                }

                if let error { Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember) }
                if let success { Text(success).font(BrandFont.body(13)).foregroundStyle(BrandColor.emerald) }

                Button { Task { await submit() } } label: {
                    Text(loading ? "Adding…" : (alreadyAdded ? "Already added" : "Add to my menu"))
                        .font(BrandFont.body(15, .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(BrandColor.accent).foregroundStyle(BrandColor.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(loading || selectedService == nil || alreadyAdded)
                .opacity(selectedService == nil || alreadyAdded ? 0.6 : 1)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
    }

    private var serviceImageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Service image (optional)")
            HStack(spacing: 12) {
                ZStack {
                    if let imageData, let img = UIImage(data: imageData) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else { BrandColor.bgSecondary; Image(systemName: "photo").foregroundStyle(BrandColor.textMuted) }
                }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                PhotosPicker(selection: $imageItem, matching: .images) {
                    Text("Choose image").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.accent)
                }
            }
            Text("This image only overrides how this service displays on your menu.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Description (optional)")
            TextEditor(text: $description)
                .frame(minHeight: 70).padding(8).scrollContentBackground(.hidden)
                .background(BrandColor.bgSecondary).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
        }
    }

    private var modeToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $offersInSalon) { Text("Offer in Salon").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary) }
                .tint(BrandColor.accent)
            Toggle(isOn: $offersMobile) { Text("Offer Mobile").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary) }
                .tint(BrandColor.accent)
            if let s = selectedService {
                Text("Min price: \(Wire.money(s.minPrice) ?? s.minPrice)")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private var pricingBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            if offersInSalon { pricingCard("Salon pricing", price: $salonPrice, duration: $salonDuration) }
            if offersMobile { pricingCard("Mobile pricing", price: $mobilePrice, duration: $mobileDuration) }
        }
    }

    private func pricingCard(_ title: String, price: Binding<String>, duration: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textPrimary)
            miniField("Starting at", text: price, placeholder: "e.g. 120", keyboard: .decimalPad)
            miniField("Duration (minutes)", text: duration, placeholder: "e.g. 90", keyboard: .numberPad)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgSecondary).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func miniField(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(BrandFont.mono(9)).tracking(0.5).foregroundStyle(BrandColor.textMuted)
            TextField(placeholder, text: text).keyboardType(keyboard)
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                .padding(10).background(BrandColor.bgPrimary).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func picker(_ label: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(label)
            Picker(label, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu).tint(BrandColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(BrandColor.bgSecondary).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textPrimary)
    }

    private func serviceLabel(_ s: ProCatalogService) -> String {
        var label = s.name
        if s.isAddOnEligible { label += s.addOnGroup.map { " (Add-on: \($0))" } ?? " (Add-on)" }
        if existingServiceIds.contains(s.id) { label += " (added)" }
        return label
    }

    private func resetForService(_ service: ProCatalogService?) {
        error = nil; success = nil; imageData = nil; imageItem = nil
        description = ""; offersInSalon = true; offersMobile = false
        guard let service else { salonPrice = ""; salonDuration = ""; mobilePrice = ""; mobileDuration = ""; return }
        let p = service.minPrice
        let d = String(service.defaultDurationMinutes)
        salonPrice = p; salonDuration = d; mobilePrice = p; mobileDuration = d
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }.font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
        }.padding(.horizontal, 40)
    }

    private func load() async {
        do { catalog = try await session.client.proProfile.servicesCatalog(); phase = .ready }
        catch let e as APIError { phase = .failed(e.userMessage) }
        catch { phase = .failed("Couldn’t load the service library.") }
    }

    private func loadImage() async {
        guard let imageItem else { return }
        if let data = try? await imageItem.loadTransferable(type: Data.self) { imageData = data }
    }

    private func submit() async {
        guard !loading, let service = selectedService else { return }
        if alreadyAdded { error = "You already added this service."; return }
        if !offersInSalon && !offersMobile { error = "Enable at least Salon or Mobile."; return }
        loading = true; error = nil; success = nil
        defer { loading = false }

        // Upload a chosen image first (web uploads before create), then create.
        var imageUrl: String?
        if let data = imageData {
            do { imageUrl = try await session.client.proMedia.uploadServiceImage(serviceId: service.id, imageData: data) }
            catch { self.error = "Image upload failed."; return }
        }

        do {
            _ = try await session.client.proProfile.createOffering(
                serviceId: service.id,
                description: description.trimmedOrNil,
                customImageUrl: imageUrl,
                offersInSalon: offersInSalon,
                offersMobile: offersMobile,
                salonPriceStartingAt: offersInSalon ? salonPrice.trimmedOrNil : nil,
                salonDurationMinutes: offersInSalon ? Int(salonDuration) : nil,
                mobilePriceStartingAt: offersMobile ? mobilePrice.trimmedOrNil : nil,
                mobileDurationMinutes: offersMobile ? Int(mobileDuration) : nil
            )
            success = "Service added to your menu."
            onSaved()
            try? await Task.sleep(nanoseconds: 400_000_000)
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Something went wrong while saving this service."
        }
    }
}

// MARK: - Add-ons manager

/// Per-offering add-ons manager (web OfferingManager add-ons editor). Lists the
/// attached add-ons + the eligible library; toggling attaches/detaches, then Save
/// replaces the whole set (PUT /pro/offerings/{id}/add-ons).
struct ProAddOnsView: View {
    @Environment(SessionModel.self) private var session
    let offering: ProOfferingAdmin

    private enum Phase { case loading, ready, failed(String) }
    @State private var phase: Phase = .loading
    @State private var eligible: [ProAddOnEligible] = []
    @State private var attached: Set<String> = []   // addOnServiceIds currently attached
    /// The server's row for each attached service, kept whole so a save can echo
    /// it back untouched. One row per service: the DB's unique index is
    /// `(offeringId, addOnServiceId)`, so a service cannot be attached twice.
    @State private var attachedRows: [String: ProAddOnAttached] = [:]
    @State private var saving = false
    @State private var banner: String?
    /// Write failures. `phase.failed` only covers LOAD errors — a rejected PUT
    /// still has to reload (the server is the truth about the set), so without
    /// this the toggles just snap back with no explanation.
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let actionError {
                    BrandErrorBanner(message: actionError)
                }
                switch phase {
                case .loading: HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message): Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).frame(maxWidth: .infinity).padding(.top, 60)
                case .ready:
                    Text("Attach add-on services clients can tack onto \(offering.serviceName).")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                    if eligible.isEmpty {
                        Text("No add-on-eligible services available.")
                            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 40)
                    } else {
                        ForEach(eligible) { row($0) }
                    }
                    if let banner { Text(banner).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.emerald) }
                    Button { Task { await save() } } label: {
                        Text(saving ? "Saving…" : "Save add-ons")
                            .font(BrandFont.body(15, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(BrandColor.accent).foregroundStyle(BrandColor.onAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(saving)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Add-ons")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    private func row(_ s: ProAddOnEligible) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    HStack(spacing: 6) {
                        if let group = s.group {
                            Text(group.uppercased()).font(BrandFont.mono(9)).tracking(0.5).foregroundStyle(BrandColor.textMuted)
                        }
                        Text("\(Wire.money(s.minPrice) ?? s.minPrice) · \(s.defaultDurationMinutes)m")
                            .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { attached.contains(s.id) },
                    // Both banners describe the last save of a selection the pro
                    // has now changed, so editing clears them together.
                    set: { on in
                        if on { attached.insert(s.id) } else { attached.remove(s.id) }
                        banner = nil
                        actionError = nil
                    }
                ))
                .labelsHidden().tint(BrandColor.accent)
            }
        }
    }

    private func load() async {
        do {
            let result = try await session.client.proProfile.addOns(offeringId: offering.id)
            eligible = result.eligible
            // `uniquingKeysWith` only so malformed server data degrades instead of
            // trapping — the unique index above means a collision cannot happen.
            attachedRows = Dictionary(
                result.attached.map { ($0.addOnServiceId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            attached = Set(result.attached.map(\.addOnServiceId))
            phase = .ready
        } catch let e as APIError { phase = .failed(e.userMessage) }
        catch { phase = .failed("Couldn’t load add-ons.") }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        actionError = nil
        defer { saving = false }

        // This screen owns MEMBERSHIP only, and the route replaces the whole set,
        // so an already-attached row goes back exactly as the server sent it —
        // anything not echoed is reset to a route default. `isRecommended` is the
        // field that matters in practice: web sets it from a per-add-on pill and
        // clients see it as a "Recommended" badge AND as their default selection,
        // so re-saving here used to quietly un-recommend every add-on. Web
        // hardcodes null for the three overrides today, so echoing them is
        // currently a no-op that stops being one the moment anything sets them.
        // New rows sort after the existing ones rather than renumbering the
        // pro's chosen order (web preserves sortOrder the same way).
        let items = ProAddOnInput.replacementSet(
            eligibleOrder: eligible.map(\.id),
            attached: attached,
            existing: attachedRows
        )

        do {
            try await session.client.proProfile.saveAddOns(offeringId: offering.id, items: items)
            banner = "Add-ons saved."
        } catch let e as APIError {
            banner = nil
            actionError = e.userMessage
        } catch {
            banner = nil
            actionError = "Couldn’t save your add-ons. Try again."
        }
        // Reload either way: the server is the truth about the set, so a rejected
        // save has to snap the toggles back. The banner is what makes it legible.
        await load()
    }
}

// MARK: - Edit offering pricing

struct ProEditOfferingSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let offering: ProOfferingAdmin
    var onSaved: () -> Void

    @State private var salonOn: Bool
    @State private var salonPrice: String
    @State private var salonMinutes: String
    @State private var mobileOn: Bool
    @State private var mobilePrice: String
    @State private var mobileMinutes: String
    @State private var rebookInterval: String
    @State private var saving = false
    @State private var error: String?

    init(offering: ProOfferingAdmin, onSaved: @escaping () -> Void) {
        self.offering = offering
        self.onSaved = onSaved
        _salonOn = State(initialValue: offering.offersInSalon)
        _salonPrice = State(initialValue: offering.salonPriceStartingAt ?? "")
        _salonMinutes = State(initialValue: offering.salonDurationMinutes.map(String.init) ?? "")
        _mobileOn = State(initialValue: offering.offersMobile)
        _mobilePrice = State(initialValue: offering.mobilePriceStartingAt ?? "")
        _mobileMinutes = State(initialValue: offering.mobileDurationMinutes.map(String.init) ?? "")
        _rebookInterval = State(initialValue: offering.rebookIntervalDays.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(offering.serviceName)
                        .font(BrandFont.display(20, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)

                    locationBlock(title: "In salon", on: $salonOn, price: $salonPrice, minutes: $salonMinutes, icon: "building.2")
                    locationBlock(title: "Mobile", on: $mobileOn, price: $mobilePrice, minutes: $mobileMinutes, icon: "car")

                    rebookIntervalBlock

                    if let minPrice = Wire.money(offering.minPrice) {
                        Text("Minimum price for this service is \(minPrice).")
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    }
                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Edit pricing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving).tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private var rebookIntervalBlock: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Label("Rebook interval", systemImage: "calendar.badge.clock")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)

                labeledField("Days", text: $rebookInterval, placeholder: "e.g. 42", keyboard: .numberPad)

                Text("Auto-suggests a rebook window at session wrap-up (service date + this many days). Leave blank to keep it off.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func locationBlock(title: String, on: Binding<Bool>, price: Binding<String>, minutes: Binding<String>, icon: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: on) {
                    Label(title, systemImage: icon)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
                .tint(BrandColor.accent)

                if on.wrappedValue {
                    HStack(spacing: 10) {
                        labeledField("Price", text: price, placeholder: "0.00", keyboard: .decimalPad)
                        labeledField("Minutes", text: minutes, placeholder: "60", keyboard: .numberPad)
                    }
                }
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(BrandColor.textMuted)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(10)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        if !salonOn && !mobileOn {
            error = "Enable at least one of in-salon or mobile."
            return
        }
        do {
            _ = try await session.client.proProfile.updateOffering(
                id: offering.id,
                offersInSalon: salonOn,
                offersMobile: mobileOn,
                salonPriceStartingAt: .some(salonOn ? salonPrice.trimmedOrNil : nil),
                salonDurationMinutes: .some(salonOn ? Int(salonMinutes) : nil),
                mobilePriceStartingAt: .some(mobileOn ? mobilePrice.trimmedOrNil : nil),
                mobileDurationMinutes: .some(mobileOn ? Int(mobileMinutes) : nil),
                rebookIntervalDays: .some(rebookInterval.trimmedOrNil.flatMap(Int.init))
            )
            onSaved()
            session.signalRefresh()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save. Try again."
        }
    }
}
