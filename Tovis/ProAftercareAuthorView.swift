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
    // Default to a valid, non-degenerate window (tomorrow → tomorrow + span) so
    // a fresh "Booking window" isn't an inverted/zero-width range. Prefill from a
    // backend suggestion or a saved summary overrides these on load.
    @State private var windowStart = ProAftercareAuthorView.defaultWindowStart()
    @State private var windowEnd = ProAftercareAuthorView.defaultWindowEnd()
    @State private var hasWindowStart = false
    @State private var hasWindowEnd = false
    @State private var version: Int?
    @State private var timeZone: String?
    // Before/after image candidates for the featured-pair picker (loaded from
    // GET .../media) + the pro's current selection. A `nil` selection means the
    // client sees the earliest of each phase (the server's default primary).
    @State private var mediaItems: [ProBookingMediaItem] = []
    @State private var featuredBeforeId: String?
    @State private var featuredAfterId: String?
    @State private var viewingMedia: FullscreenMedia?
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
                    photosSection
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
        .mediaFullscreenCover($viewingMedia)
    }

    // Before/after IMAGE candidates offered by the featured-pair picker, each
    // phase earliest-first (shared partition logic with the web picker).
    private var featuredCandidates:
        (before: [ProBookingMediaItem], after: [ProBookingMediaItem])
    {
        AftercareFeaturedPair.candidates(mediaItems)
    }

    // MARK: - Sections

    // The visual record + the featured-pair picker — mirroring the web aftercare
    // page's "Photos" card. The pro taps "Feature" on a before and an after photo
    // to set the pair the client sees first (every other photo shows as a
    // thumbnail); leaving both unset features the earliest of each. Hidden when
    // the session has no before/after image to feature.
    @ViewBuilder
    private var photosSection: some View {
        let candidates = featuredCandidates
        if !candidates.before.isEmpty || !candidates.after.isEmpty {
            BrandSection(title: "Photos") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Visible to you + the client. Tap “Feature” on a before and an after photo to set the pair the client sees first — the rest show as thumbnails. Leave both unset to feature the earliest of each.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                    phaseGrid(
                        heading: "Before", items: candidates.before,
                        selectedId: featuredBeforeId, onToggle: toggleFeaturedBefore)
                    phaseGrid(
                        heading: "After", items: candidates.after,
                        selectedId: featuredAfterId, onToggle: toggleFeaturedAfter)
                }
            }
        }
    }

    private func toggleFeaturedBefore(_ id: String) {
        featuredBeforeId = (featuredBeforeId == id) ? nil : id
    }

    private func toggleFeaturedAfter(_ id: String) {
        featuredAfterId = (featuredAfterId == id) ? nil : id
    }

    private var featureGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    }

    @ViewBuilder
    private func phaseGrid(
        heading: String, items: [ProBookingMediaItem],
        selectedId: String?, onToggle: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
            if items.isEmpty {
                Text("None yet.").font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            } else {
                LazyVGrid(columns: featureGridColumns, spacing: 8) {
                    ForEach(items) { item in
                        featureTile(item, isFeatured: selectedId == item.id, onToggle: onToggle)
                    }
                }
            }
        }
    }

    private func featureTile(
        _ item: ProBookingMediaItem, isFeatured: Bool,
        onToggle: @escaping (String) -> Void
    ) -> some View {
        let isProClient = item.visibility == "PRO_CLIENT"
        return ZStack(alignment: .topTrailing) {
            Button {
                viewingMedia = FullscreenMedia.remote(
                    id: item.id, urlString: item.displayUrl, isVideo: false)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BrandColor.bgPrimary)
                    if let thumb = item.displayThumbUrl, let url = URL(string: thumb) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView().tint(BrandColor.accent)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Text(isProClient ? "PRO + CLIENT" : "PUBLIC")
                        .font(BrandFont.mono(7)).tracking(0.8)
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(BrandColor.bgPrimary.opacity(0.7)).clipShape(Capsule())
                        .padding(5)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isFeatured ? BrandColor.accent : BrandColor.textMuted.opacity(0.25),
                                lineWidth: isFeatured ? 2 : 1)
                )
            }
            .buttonStyle(.plain)

            Button { onToggle(item.id) } label: {
                Text(isFeatured ? "★ Featured" : "Feature")
                    .font(BrandFont.body(10, .semibold))
                    .foregroundStyle(isFeatured ? BrandColor.onAccent : BrandColor.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isFeatured ? BrandColor.accent : BrandColor.bgSecondary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .padding(4)
        }
    }

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
                            dateRow(
                                "Window start", date: $windowStart, has: $hasWindowStart,
                                onDateChange: bumpWindowEndAfterStart,
                            )
                            dateRow(
                                "Window end", date: $windowEnd, has: $hasWindowEnd,
                                in: windowEndLowerBound...,
                            )
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

    private func dateRow(
        _ label: String,
        date: Binding<Date>,
        has: Binding<Bool>,
        in range: PartialRangeFrom<Date>? = nil,
        onDateChange: (() -> Void)? = nil,
    ) -> some View {
        HStack {
            Text(label).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            Spacer()
            Group {
                if let range {
                    DatePicker("", selection: date, in: range, displayedComponents: .date)
                } else {
                    DatePicker("", selection: date, displayedComponents: .date)
                }
            }
            .labelsHidden().tint(BrandColor.accent)
            .onChange(of: date.wrappedValue) {
                has.wrappedValue = true
                onDateChange?()
            }
        }
    }

    /// The window end can never be picked earlier than the day after the start —
    /// mirrors web's end `<input min={start + 1 day}>` and reuses the same
    /// `in: start...`-style bound already used in `ProBlockTimeSheet`.
    private var windowEndLowerBound: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: windowStart))
            ?? windowStart
    }

    /// Keep the window end a full suggested span past the start whenever moving
    /// the start would collapse the range to/before the end — mirrors web
    /// `AftercareForm.applyWindowStart`. Bumps to the 7-day suggested span (not
    /// just +1 day) so an auto-advanced window matches the fresh suggested width
    /// (decided w/ Tori 2026-07-09). The floor stays "end after start"; only this
    /// automatic advance lands on the span.
    private func bumpWindowEndAfterStart() {
        let cal = Calendar.current
        guard cal.startOfDay(for: windowEnd) <= cal.startOfDay(for: windowStart) else { return }
        windowEnd = cal.date(
            byAdding: .day, value: Self.suggestedWindowSpanDays,
            to: cal.startOfDay(for: windowStart),
        ) ?? windowStart
        hasWindowEnd = true
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
            // Full before/after media list for the featured-pair picker (the
            // aftercare GET returns only the single resolved pair, not every
            // candidate). Best-effort: a failure just leaves the picker empty.
            async let mediaTask = try? session.client.proMedia.list(bookingId: bookingId)
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

            // Media exists independently of any aftercare draft (captured during
            // the session), so set it before the summary guard returns early.
            mediaItems = await mediaTask ?? []

            guard let summary = booking.aftercareSummary else {
                // Fresh wrap-up: pre-select the recommended window from the
                // backend suggestion (service date + the offering's rebook
                // interval) so the recommendation defaults to a real date
                // instead of "None". Matches web AftercareForm; the pro can
                // still change or clear it. The backend sends this only when no
                // aftercare is saved yet, so a saved choice is never touched.
                if let suggestion = booking.rebookSuggestion,
                   let start = Wire.date(suggestion.windowStart),
                   let end = Wire.date(suggestion.windowEnd) {
                    rebookMode = .window
                    windowStart = start; hasWindowStart = true
                    windowEnd = end; hasWindowEnd = true
                }
                return
            }
            notes = summary.notes ?? ""
            version = summary.version
            isFinalized = summary.isFinalized
            // Seed the featured-pair picker from the saved selection (nil = the
            // client sees the earliest of each phase).
            featuredBeforeId = summary.featuredBeforeAssetId
            featuredAfterId = summary.featuredAfterAssetId
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

        // Only send a featured id that still maps to a current before/after image
        // (mirrors web's `validFeatured*` guard) — a stale/deleted id would trip
        // the server's ownership/phase validation and fail the whole save.
        let candidates = featuredCandidates
        let validFeaturedBefore = AftercareFeaturedPair.resolveValidFeaturedId(
            featuredBeforeId, in: candidates.before)
        let validFeaturedAfter = AftercareFeaturedPair.resolveValidFeaturedId(
            featuredAfterId, in: candidates.after)

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
            featuredBeforeAssetId: validFeaturedBefore,
            featuredAfterAssetId: validFeaturedAfter,
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

    // Width of a fresh/auto-advanced recommended booking window, in days —
    // mirrors web `SUGGESTED_REBOOK_WINDOW_SPAN_DAYS` (aftercareDates.ts).
    private static let suggestedWindowSpanDays = 7

    private static func defaultWindowStart() -> Date {
        let cal = Calendar.current
        return cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }

    private static func defaultWindowEnd() -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: suggestedWindowSpanDays, to: defaultWindowStart())
            ?? defaultWindowStart()
    }
}
