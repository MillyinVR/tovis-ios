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
                handle: canEditHandle ? handle : nil
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                case let .loaded(items):
                    if items.isEmpty {
                        Text("No services yet. Add services on the web to get started.")
                            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 50)
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
        .sheet(item: $editing) { offering in
            ProEditOfferingSheet(offering: offering) { Task { await load() } }
        }
        .tint(BrandColor.accent)
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

                Button { editing = o } label: {
                    Text("Edit pricing")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.accent)
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
        defer { busyId = nil }
        _ = try? await session.client.proProfile.updateOffering(id: o.id, isActive: active)
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
                salonPriceStartingAt: .some(salonOn ? emptyToNil(salonPrice) : nil),
                salonDurationMinutes: .some(salonOn ? Int(salonMinutes) : nil),
                mobilePriceStartingAt: .some(mobileOn ? emptyToNil(mobilePrice) : nil),
                mobileDurationMinutes: .some(mobileOn ? Int(mobileMinutes) : nil)
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

    private func emptyToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
