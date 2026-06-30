// Aftercare authoring screen — native port of web
// `app/pro/bookings/[id]/aftercare` (`AftercareForm`). Write aftercare notes,
// recommend products (name + link + note), set a rebook recommendation, and
// either save a draft or finalize + send to the client. GET prefills from any
// existing summary; POST saves (sendToClient false = draft, true = send).
//
// Recommended products are external (name + link + note) — matching the web form,
// which always sends productId: null (there is no catalog picker on the web
// aftercare form). Smart reminders (rebook + product follow-up) are supported.
import SwiftUI
import TovisKit

struct ProAftercareAuthorView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let bookingId: String
    /// Called after a successful send so the caller (session hub) can refresh.
    var onSent: (() -> Void)?

    private enum RebookMode: String {
        case none = "NONE", booked = "BOOKED_NEXT_APPOINTMENT", window = "RECOMMENDED_WINDOW"
    }

    @State private var loading = true
    @State private var notes = ""
    @State private var products: [EditableProduct] = []
    @State private var rebookMode: RebookMode = .none
    @State private var windowStart = Date()
    @State private var windowEnd = Date()
    @State private var hasWindowStart = false
    @State private var hasWindowEnd = false
    @State private var version: Int?
    @State private var timeZone: String?
    @State private var isFinalized = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var message: String?

    // Rebook-slot context (the source booking's service + location), for the
    // "Next booking date" mode's open-slot picker.
    @State private var professionalId = ""
    @State private var rebookServiceId = ""
    @State private var rebookOfferingId = ""
    @State private var rebookLocationId = ""
    @State private var rebookLocationType = "SALON"
    @State private var rebookDurationMinutes = 60
    @State private var selectedSlot: String?   // chosen ISO start instant

    // Smart reminders (web "Smart reminders" section).
    @State private var createRebookReminder = false
    @State private var rebookReminderDaysBefore = 2
    @State private var createProductReminder = false
    @State private var productReminderDaysAfter = 7

    private struct EditableProduct: Identifiable {
        let id = UUID()
        var name = ""
        var url = ""
        var note = ""
    }

    var body: some View {
        ScrollView {
            if loading {
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    notesSection
                    rebookSection
                    productsSection
                    remindersSection
                    if let errorText {
                        Text(errorText).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                    if let message {
                        Text(message).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.emerald)
                    }
                    actions
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Aftercare")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .tint(BrandColor.accent)
        .task { await load() }
    }

    // MARK: - Sections

    private var notesSection: some View {
        BrandSection(title: "Aftercare notes") {
            BrandSurface {
                TextField(
                    "E.g. wash after 48 hours, use sulfate-free shampoo, avoid tight ponytails for 7 days…",
                    text: $notes, axis: .vertical,
                )
                .lineLimit(4...10)
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                .disabled(saving)
            }
        }
    }

    private var rebookSection: some View {
        BrandSection(title: "Rebook recommendation") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    modeChip("None", mode: .none)
                    modeChip("Next booking date", mode: .booked)
                    modeChip("Booking window", mode: .window)
                }
                if rebookMode == .booked { bookedModeBody }
                if rebookMode == .window {
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recommend a date range the client should book within.")
                                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                            dateRow("Window start", date: $windowStart, has: $hasWindowStart)
                            dateRow("Window end", date: $windowEnd, has: $hasWindowEnd)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bookedModeBody: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Propose an exact next appointment from your open times (same service + location as this booking).")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                if rebookOfferingId.isEmpty || professionalId.isEmpty {
                    Text("This booking has no service offering set, so an exact next appointment can’t be proposed. Use “Booking window” instead.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                } else {
                    ProOpenSlotPicker(
                        professionalId: professionalId,
                        serviceId: rebookServiceId,
                        offeringId: rebookOfferingId,
                        locationId: rebookLocationId,
                        locationType: rebookLocationType,
                        locationTimeZone: timeZone,
                        durationMinutes: rebookDurationMinutes,
                        selectedSlot: $selectedSlot,
                    )
                }
            }
        }
    }

    private func modeChip(_ label: String, mode: RebookMode) -> some View {
        let active = rebookMode == mode
        return Button { rebookMode = mode } label: {
            Text(label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(active ? BrandColor.accent : BrandColor.bgSecondary)
                .clipShape(Capsule())
        }
        .disabled(saving)
    }

    private func dateRow(_ label: String, date: Binding<Date>, has: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            Spacer()
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden().tint(BrandColor.accent)
                .onChange(of: date.wrappedValue) { has.wrappedValue = true }
        }
    }

    private var productsSection: some View {
        BrandSection(title: "Recommended products") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add products with links (Amazon storefront, pro shop, etc.). Links must be http/https.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                if products.isEmpty {
                    Text("No products added yet.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                } else {
                    ForEach(Array($products.enumerated()), id: \.element.id) { index, $product in
                        productRow(index: index, product: $product)
                    }
                }

                Button { products.append(EditableProduct()) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("Add product").font(BrandFont.body(14, .semibold))
                    }
                    .foregroundStyle(BrandColor.accent)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(BrandColor.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(saving)
            }
        }
    }

    /// Whether a rebook reminder can be set — only for an exact picked next
    /// appointment (web: `BOOKED_NEXT_APPOINTMENT && hasBookedDate`).
    private var rebookReminderAvailable: Bool {
        rebookMode == .booked && selectedSlot != nil
    }

    private var remindersSection: some View {
        BrandSection(title: "Smart reminders") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nudge Future You to check in at the right time.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                BrandSurface {
                    VStack(alignment: .leading, spacing: 14) {
                        // Rebook reminder — only for a single recommended date.
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $createRebookReminder) {
                                Text("Create a rebook reminder").font(BrandFont.body(13, .semibold))
                            }
                            .tint(BrandColor.accent)
                            .disabled(saving || !rebookReminderAvailable)
                            .opacity(rebookReminderAvailable ? 1 : 0.55)
                            if rebookReminderAvailable {
                                if createRebookReminder {
                                    daysStepper(value: $rebookReminderDaysBefore,
                                                options: [1, 2, 3, 7], suffix: "before the recommended date")
                                }
                            } else {
                                Text("Rebook reminders only apply to a single recommended date (Next booking date).")
                                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                            }
                        }

                        Divider().overlay(BrandColor.textMuted.opacity(0.15))

                        // Product follow-up.
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $createProductReminder) {
                                Text("Create a product follow-up").font(BrandFont.body(13, .semibold))
                            }
                            .tint(BrandColor.accent).disabled(saving)
                            if createProductReminder {
                                daysStepper(value: $productReminderDaysAfter,
                                            options: [3, 7, 14, 30], suffix: "after the booking")
                            }
                        }
                    }
                    .foregroundStyle(BrandColor.textPrimary)
                }

                Text("These go into your Reminders tab so Future You remembers to check in.")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func daysStepper(value: Binding<Int>, options: [Int], suffix: String) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(options, id: \.self) { day in
                    Button("\(day) day\(day == 1 ? "" : "s")") { value.wrappedValue = day }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(value.wrappedValue) day\(value.wrappedValue == 1 ? "" : "s")")
                        .font(BrandFont.body(12, .semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .foregroundStyle(BrandColor.accent)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(BrandColor.accent.opacity(0.12)).clipShape(Capsule())
            }
            .disabled(saving)
            Text(suffix).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
        }
    }

    private func productRow(index: Int, product: Binding<EditableProduct>) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Product \(index + 1)")
                        .font(BrandFont.mono(11)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                    Spacer()
                    Button { products.removeAll { $0.id == product.wrappedValue.id } } label: {
                        Text("Remove").font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.ember)
                    }
                    .disabled(saving)
                }
                field("e.g. Sulfate-free shampoo", text: product.name)
                field("https://amazon.com/…", text: product.url, keyboard: .URL)
                field("e.g. Use 2–3x/week to maintain shine", text: product.note)
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(keyboard == .URL ? .never : .sentences)
            .autocorrectionDisabled(keyboard == .URL)
            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(saving)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { Task { await save(sendToClient: false) } } label: {
                Text(saving ? "Saving…" : "Save draft").font(BrandFont.body(15, .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(BrandColor.bgSecondary).foregroundStyle(BrandColor.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(saving)

            Button { Task { await save(sendToClient: true) } } label: {
                Text(saving ? "Sending…" : "Send to client").font(BrandFont.body(15, .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(BrandColor.accent).foregroundStyle(BrandColor.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(saving)
        }
    }

    // MARK: - Logic

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // Aftercare summary (prefill) + the booking detail (rebook service +
            // location context) + the pro's id (availability is keyed by it).
            async let bookingTask = session.client.proBookings.aftercareDetail(bookingId: bookingId)
            async let detailTask = try? session.client.proBookings.detail(bookingId: bookingId)
            async let profileTask = try? session.client.proProfile.myProfile()
            let booking = try await bookingTask
            let detail = await detailTask
            professionalId = await profileTask?.id ?? ""

            timeZone = detail?.timeZone ?? booking.locationTimeZone
            if let detail {
                rebookServiceId = detail.baseItem?.serviceId ?? ""
                rebookOfferingId = detail.baseItem?.offeringId ?? ""
                rebookLocationId = detail.locationId ?? ""
                rebookLocationType = detail.locationType.uppercased() == "SALON" ? "SALON" : "MOBILE"
                rebookDurationMinutes = detail.totalDurationMinutes > 0 ? detail.totalDurationMinutes : 60
            }

            guard let summary = booking.aftercareSummary else { return }
            notes = summary.notes ?? ""
            version = summary.version
            isFinalized = summary.isFinalized
            products = summary.recommendedProducts.compactMap { product in
                // Only the external name+link products are editable here.
                guard product.productId == nil else { return nil }
                return EditableProduct(
                    name: product.externalName ?? "",
                    url: product.externalUrl ?? "",
                    note: product.note ?? "",
                )
            }
            if summary.rebookMode == RebookMode.booked.rawValue {
                rebookMode = .booked   // the slot picker prompts a fresh pick
            } else if summary.rebookMode == RebookMode.window.rawValue {
                rebookMode = .window
                if let start = summary.rebookWindowStart.flatMap(Wire.date) {
                    windowStart = start; hasWindowStart = true
                }
                if let end = summary.rebookWindowEnd.flatMap(Wire.date) {
                    windowEnd = end; hasWindowEnd = true
                }
            }
        } catch let error as APIError {
            errorText = error.userMessage
        } catch {
            errorText = "Couldn’t load aftercare."
        }
    }

    private func save(sendToClient: Bool) async {
        errorText = nil
        message = nil
        if let validation = validate(sendToClient: sendToClient) {
            errorText = validation
            return
        }

        saving = true
        defer { saving = false }

        let zone = TimeZone(identifier: timeZone ?? "") ?? .current
        let payloadProducts = sanitizedProducts(sendToClient: sendToClient)

        // The picked next appointment (BOOKED mode): its start is the canonical
        // rebookedFor; endsAt = start + the booking's duration.
        let bookedSlot: ProAftercareSaveRequest.RebookSlot? = {
            guard rebookMode == .booked, let start = selectedSlot, let startDate = Wire.date(start)
            else { return nil }
            let end = startDate.addingTimeInterval(TimeInterval(rebookDurationMinutes * 60))
            return .init(
                offeringId: rebookOfferingId, locationId: rebookLocationId,
                locationType: rebookLocationType, startsAt: start, endsAt: iso(end),
            )
        }()

        let request = ProAftercareSaveRequest(
            notes: String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)),
            recommendedProducts: payloadProducts,
            rebookMode: rebookMode.rawValue,
            rebookedFor: bookedSlot?.startsAt,
            rebookSlot: bookedSlot,
            rebookWindowStart: rebookMode == .window ? isoStartOfDay(windowStart, zone) : nil,
            rebookWindowEnd: rebookMode == .window ? isoEndOfDay(windowEnd, zone) : nil,
            // Rebook reminders only apply to a single picked next appointment.
            createRebookReminder: rebookReminderAvailable && createRebookReminder,
            rebookReminderDaysBefore: rebookReminderDaysBefore,
            createProductReminder: createProductReminder,
            productReminderDaysAfter: productReminderDaysAfter,
            sendToClient: sendToClient,
            timeZone: timeZone,
            version: version,
        )

        do {
            try await session.client.proBookings.saveAftercare(bookingId: bookingId, request: request)
            session.signalRefresh()
            if sendToClient {
                onSent?()
                dismiss()
            } else {
                message = "Draft saved."
                await load()
            }
        } catch let error as APIError {
            errorText = error.userMessage
        } catch {
            errorText = "Couldn’t save aftercare. Check your connection and try again."
        }
    }

    /// Mirror of the web `buildPayload` product filter: for send, keep anything
    /// with a name/url/note; for draft, keep only complete name + valid link.
    private func sanitizedProducts(sendToClient: Bool) -> [ProAftercareSaveRequest.Product] {
        products.compactMap { product in
            let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = product.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = product.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let keep = sendToClient
                ? (!name.isEmpty || !url.isEmpty || !note.isEmpty)
                : (!name.isEmpty && isValidHttpUrl(url))
            guard keep else { return nil }
            return ProAftercareSaveRequest.Product(
                productId: nil, externalName: name, externalUrl: url,
                note: note.isEmpty ? nil : note,
            )
        }
    }

    private func validate(sendToClient: Bool) -> String? {
        if rebookMode == .booked {
            if rebookOfferingId.isEmpty {
                return "This booking has no service offering set, so an exact next appointment can’t be proposed. Use “Booking window” instead."
            }
            guard let slot = selectedSlot, let date = Wire.date(slot), date > Date() else {
                return "Pick an available next-appointment time, or change rebook mode to “None”."
            }
        }
        if rebookMode == .window {
            guard hasWindowStart, hasWindowEnd else {
                return "Pick both a start and end date for the recommended booking window."
            }
            let cal = Calendar.current
            if cal.startOfDay(for: windowStart) <= cal.startOfDay(for: Date()) {
                return "Recommended booking window must start in the future."
            }
            if cal.startOfDay(for: windowEnd) <= cal.startOfDay(for: windowStart) {
                return "Window end must be after window start."
            }
        }
        if sendToClient {
            for product in products {
                let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = product.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let isBlank = name.isEmpty && url.isEmpty
                    && product.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isBlank { continue }
                if name.isEmpty || !isValidHttpUrl(url) {
                    return "Fix product links/names before continuing."
                }
            }
        }
        return nil
    }

    private func isValidHttpUrl(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return false }
        return true
    }

    private func isoStartOfDay(_ date: Date, _ zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return iso(cal.startOfDay(for: date))
    }

    private func isoEndOfDay(_ date: Date, _ zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? start
        return iso(end)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
