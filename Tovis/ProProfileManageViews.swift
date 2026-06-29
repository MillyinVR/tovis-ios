// Pro profile management — the edit sheet (PATCH /pro/profile) and the services
// manager (GET /pro/offerings + toggle active / edit price+duration / remove).
// Ports the web `/pro/profile/public-profile` edit affordances + the services
// manager section. Reached from `ProProfileTabView`.
import SwiftUI
import TovisKit

// MARK: - Edit profile

struct ProEditProfileSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let profile: ProMyProfile
    /// Called with the saved profile so the tab can refresh in place.
    var onSaved: (ProMyProfile) -> Void

    @State private var businessName: String
    @State private var handle: String
    @State private var bio: String
    @State private var location: String
    @State private var nameDisplay: String
    @State private var saving = false
    @State private var error: String?

    private let nameDisplayOptions: [(value: String, label: String)] = [
        ("BUSINESS_NAME", "Business name"),
        ("FIRST_LAST_NAME", "Your name"),
        ("BUSINESS_AND_NAME", "Business + name"),
    ]

    init(profile: ProMyProfile, onSaved: @escaping (ProMyProfile) -> Void) {
        self.profile = profile
        self.onSaved = onSaved
        _businessName = State(initialValue: profile.businessName ?? "")
        _handle = State(initialValue: profile.handle ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _location = State(initialValue: profile.location ?? "")
        _nameDisplay = State(initialValue: profile.nameDisplay ?? "BUSINESS_NAME")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(title: "Business name", text: $businessName, placeholder: "Studio name")
                    field(title: "Handle", text: $handle, placeholder: "your-handle", autocap: false)
                        .textInputAutocapitalization(.never)

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Display name as")
                        Picker("Display", selection: $nameDisplay) {
                            ForEach(nameDisplayOptions, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                    }

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

                    field(title: "Location", text: $location, placeholder: "City, State")

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
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String, autocap: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            TextField(placeholder, text: text)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(12)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        let bn: String? = businessName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : businessName
        let hd: String? = handle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : handle
        let bo: String? = bio.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bio
        let lo: String? = location.trimmingCharacters(in: .whitespaces).isEmpty ? nil : location
        do {
            let saved = try await session.client.proProfile.updateProfile(
                businessName: .some(bn),
                bio: .some(bo),
                location: .some(lo),
                handle: .some(hd),
                nameDisplay: nameDisplay
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
