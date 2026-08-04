// "Attach later" — the picker that turns a practice shot into real media.
//
// A practice shot was taken with no booking and no service, on purpose. This is
// where those get chosen:
//
//   To a client — the shot joins one of that booking's session photos, private
//     to the pro and the client. ⚠️ The server's booking write boundary will not
//     take media on a COMPLETED or cancelled booking (closeout integrity), so
//     only bookings that can still accept it are offered, and the server's own
//     refusal is shown verbatim if one slips through.
//
//   As a look — the shot becomes public work under one or more services. Nothing
//     is published unless the pro asks: "Post it now" defaults OFF, and leaving
//     it off saves the look as a draft.
import SwiftUI
import TovisKit

struct ProPracticeAttachSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let shot: ProPracticeShot
    /// Called with a one-line result for the library's banner.
    let onAttached: (String) -> Void

    private enum Target: String, CaseIterable, Identifiable {
        case client = "To a client"
        case look = "As a look"
        var id: String { rawValue }
    }

    @State private var target: Target = .client

    // Client / booking side
    @State private var bookings: [ProBookingListItem] = []
    @State private var selectedBookingId: String?
    @State private var loadingBookings = true

    // Look side
    @State private var serviceOptions: [ProMediaServiceTag] = []
    @State private var selectedServiceIds: Set<String> = []
    @State private var publishNow = false
    @State private var loadingServices = true

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Attach", selection: $target) {
                        ForEach(Target.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(BrandColor.bgSurface)

                switch target {
                case .client: clientSection
                case .look: lookSection
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                    .listRowBackground(BrandColor.bgSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Attach this shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await attach() }
                    } label: {
                        if working { ProgressView().tint(BrandColor.accent) } else { Text("Attach") }
                    }
                    .tint(BrandColor.accent)
                    .disabled(working || !canAttach)
                }
            }
            .task { await loadOptions() }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Sections

    @ViewBuilder
    private var clientSection: some View {
        Section {
            if loadingBookings {
                HStack { ProgressView().tint(BrandColor.accent); Text("Loading appointments…") }
            } else if bookings.isEmpty {
                Text("No appointment can take a photo right now. A finished appointment is locked once it’s closed out, so this attaches to work that’s still open.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            } else {
                ForEach(bookings) { booking in
                    Button {
                        selectedBookingId = booking.id
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(booking.client.fullName)
                                    .font(BrandFont.body(15, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                Text("\(booking.serviceName) • \(booking.whenLabel)")
                                    .font(BrandFont.mono(11))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                            Spacer()
                            if selectedBookingId == booking.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(BrandColor.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Appointment")
        } footer: {
            Text("The photo becomes part of that appointment’s session media — private to you and the client.")
        }
        .listRowBackground(BrandColor.bgSurface)
    }

    @ViewBuilder
    private var lookSection: some View {
        Section {
            if loadingServices {
                HStack { ProgressView().tint(BrandColor.accent); Text("Loading services…") }
            } else if serviceOptions.isEmpty {
                Text("Add a service to your menu first — a look always links to something bookable.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            } else {
                ForEach(serviceOptions, id: \.serviceId) { option in
                    Button {
                        toggleService(option.serviceId)
                    } label: {
                        HStack {
                            Text(option.name)
                                .font(BrandFont.body(15))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            if selectedServiceIds.contains(option.serviceId) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(BrandColor.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Services")
        } footer: {
            Text("The first one you pick is what the look links to for booking.")
        }
        .listRowBackground(BrandColor.bgSurface)

        Section {
            Toggle("Post it now", isOn: $publishNow)
                .tint(BrandColor.accent)
        } footer: {
            // Off by default, and the copy says what off MEANS — a toggle whose
            // default silently published would be the wrong kind of surprise.
            Text(publishNow
                 ? "This goes out to the Looks feed and your portfolio."
                 : "Saved as a draft in your media — nothing is public until you post it.")
        }
        .listRowBackground(BrandColor.bgSurface)
    }

    // MARK: - State

    private var canAttach: Bool {
        switch target {
        case .client: return selectedBookingId != nil
        case .look: return !selectedServiceIds.isEmpty
        }
    }

    private func toggleService(_ id: String) {
        if selectedServiceIds.contains(id) {
            selectedServiceIds.remove(id)
        } else {
            selectedServiceIds.insert(id)
        }
    }

    // MARK: - Data

    private func loadOptions() async {
        async let bookingsTask = loadBookings()
        async let servicesTask = loadServices()
        _ = await (bookingsTask, servicesTask)
    }

    /// Only bookings that can still ACCEPT media. The write boundary refuses a
    /// completed or cancelled one, so offering those would be offering a
    /// guaranteed error.
    private func loadBookings() async {
        defer { loadingBookings = false }
        guard let response = try? await session.client.proBookings.list() else { return }
        bookings = (response.today + response.upcoming).filter { $0.finishedAt == nil }
    }

    private func loadServices() async {
        defer { loadingServices = false }
        guard let response = try? await session.client.proMedia.listManagedMedia() else { return }
        serviceOptions = response.serviceOptions
    }

    private func attach() async {
        guard !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }

        let attachTarget: ProPracticeAttachTarget
        switch target {
        case .client:
            guard let bookingId = selectedBookingId else { return }
            attachTarget = .booking(bookingId: bookingId)
        case .look:
            // Order matters: the FIRST pick is the primary (what the look books).
            let ids = serviceOptions
                .map(\.serviceId)
                .filter { selectedServiceIds.contains($0) }
            guard let primary = ids.first else { return }
            attachTarget = .look(serviceIds: ids, primaryServiceId: primary, publish: publishNow)
        }

        do {
            _ = try await session.client.proPractice.attach(shotId: shot.id, to: attachTarget)
            session.signalRefresh()   // the hub gallery / media manager picks it up
            onAttached(successMessage)
            dismiss()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t attach that shot."
        }
    }

    private var successMessage: String {
        switch target {
        case .client:
            return "Added to that appointment’s photos."
        case .look:
            return publishNow ? "Posted as a look." : "Saved as a draft look in your media."
        }
    }
}
