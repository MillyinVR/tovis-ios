// Aftercare authoring screen — native port of web
// `app/pro/bookings/[id]/aftercare` (`AftercareForm`). Write aftercare notes,
// recommend products (name + link + note), set a rebook recommendation, and
// either save a draft or finalize + send to the client. GET prefills from any
// existing summary; POST saves (sendToClient false = draft, true = send).
//
// Deferred vs web: the "Next booking date" rebook mode (an exact picked slot via
// RebookSlotPicker) needs the openings/availability subsystem — offered here are
// None + Booking window. Product reminders + the product catalog picker are also
// deferred (external name+link products only).
import SwiftUI
import TovisKit

struct ProAftercareAuthorView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let bookingId: String
    /// Called after a successful send so the caller (session hub) can refresh.
    var onSent: (() -> Void)?

    private enum RebookMode: String { case none = "NONE", window = "RECOMMENDED_WINDOW" }

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
                    modeChip("Booking window", mode: .window)
                }
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
            let booking = try await session.client.proBookings.aftercareDetail(bookingId: bookingId)
            timeZone = booking.locationTimeZone
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
            if summary.rebookMode == RebookMode.window.rawValue {
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

        let request = ProAftercareSaveRequest(
            notes: String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)),
            recommendedProducts: payloadProducts,
            rebookMode: rebookMode.rawValue,
            rebookedFor: nil,
            rebookWindowStart: rebookMode == .window ? isoStartOfDay(windowStart, zone) : nil,
            rebookWindowEnd: rebookMode == .window ? isoEndOfDay(windowEnd, zone) : nil,
            createRebookReminder: false,
            rebookReminderDaysBefore: 2,
            createProductReminder: false,
            productReminderDaysAfter: 7,
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
