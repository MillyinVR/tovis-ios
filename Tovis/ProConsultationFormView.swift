// The consultation form — native port of web `app/pro/bookings/[id]/ConsultationForm.tsx`.
// Set the line items + total, then send the secure approval link to the client.
// Line items pre-fill from the booking's services; the pro can edit price/
// duration/notes per line, remove lines, and add more. Send posts to
// `POST .../consultation-proposal` and surfaces an undeliverable warning when the
// client has no contact method (the proposal still saves).
//
// A booking is modeled as exactly ONE main (BASE) service + ADD_ONs — enforced
// server-side in both the proposal route and the finalize write-boundary (totals
// derive the booking's single primary service from that BASE). So the "Add"
// picker is base/add-on aware: until a base exists it offers base services; once
// one is set it offers that offering's add-ons (tagged ADD_ON). The web form
// only ever added BASE — adding a second one tripped the server's "exactly one
// base service" rule; offering add-ons is the supported way to bill additional
// services here.
import SwiftUI
import TovisKit

struct ProConsultationFormView: View {
    @Environment(SessionModel.self) private var session
    let bookingId: String
    /// Pre-filled line items from the booking's service items.
    let initialItems: [ProConsultationLineItem]
    /// Suggested total (the booking's proposed/total/subtotal) — seeds the first
    /// added service's price and shows the "Suggested $X" chip.
    let suggestedTotal: String?
    /// Called after a successful send so the hub re-loads its state.
    let onSent: () -> Void

    @State private var items: [ProConsultationLineItem] = []
    @State private var services: [ProConsultationServiceOption] = []
    @State private var addOns: [ProConsultationAddOnOption] = []
    @State private var selectedOptionId: String = ""
    @State private var notes: String = ""
    @State private var saving = false
    @State private var loadingServices = true
    @State private var errorText: String?
    @State private var message: String?
    // F12 — a caution about the appointment's new end time. Separate from
    // `message` because the send SUCCEEDED: emerald would read "all good" about
    // the one thing the pro needs to notice, and ember would read "fix this".
    // Gold is the same pair of values as web's `--tone-warn`.
    @State private var scheduleNotice: String?

    private var total: Double {
        ProConsultationMoney.sum(items.map(\.price))
    }
    private var totalLabel: String { ProConsultationMoney.label(total) }

    private var itemsValid: Bool {
        guard !items.isEmpty else { return false }
        for item in items {
            if item.serviceId.isEmpty { return false }
            if item.itemType == "BASE" && (item.offeringId ?? "").isEmpty { return false }
            guard let price = ProConsultationMoney.parse(item.price), price > 0 else { return false }
            guard let duration = ProConsultationMoney.parseDuration(item.durationMinutes), duration > 0
            else { return false }
        }
        return true
    }

    private var canSubmit: Bool {
        !bookingId.isEmpty && !saving && itemsValid && total > 0
    }

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let suggestedTotal {
                    BrandPill(text: "Suggested $\(suggestedTotal)", tint: BrandColor.accent)
                }

                if items.isEmpty {
                    Text("Add services above. Sending a consult with “nothing” is not a personality trait.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                } else {
                    ForEach($items) { $item in
                        lineItem($item)
                    }
                }

                servicePicker

                notesField

                Button { Task { await submit() } } label: {
                    HStack(spacing: 8) {
                        if saving { ProgressView().tint(BrandColor.onAccent) }
                        Image(systemName: "paperplane.fill").font(.system(size: 13, weight: .semibold))
                        Text(saving ? "Sending…" : "Send to client for approval")
                            .font(BrandFont.body(15, .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSubmit ? BrandColor.accent : BrandColor.bgSecondary)
                    .foregroundStyle(canSubmit ? BrandColor.onAccent : BrandColor.textMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canSubmit)

                Text("Client sees line items + total and must approve before you proceed.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)

                if !canSubmit && !saving && !items.isEmpty {
                    Text(total <= 0
                        ? "Add a price to each service before you can send."
                        : "Each service needs a valid price and duration (in minutes) before you can send.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }

                if let message {
                    Text(message)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.emerald)
                }
                if let scheduleNotice {
                    Text(scheduleNotice)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.gold)
                }
                if let errorText {
                    Text(errorText)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                }
            }
        }
        .task {
            if items.isEmpty { items = ProConsultationLineItem.sorted(initialItems) }
            await loadServices()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text("Services")
                .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(BrandColor.textMuted)
            Spacer()
            (Text("Total: ").foregroundStyle(BrandColor.textSecondary)
                + Text(totalLabel).foregroundStyle(BrandColor.textPrimary).bold())
                .font(BrandFont.body(13))
        }
    }

    @ViewBuilder
    private func lineItem(_ item: Binding<ProConsultationLineItem>) -> some View {
        let value = item.wrappedValue
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(value.label)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    HStack(spacing: 6) {
                        BrandPill(text: value.itemType == "ADD_ON" ? "ADD-ON" : "SERVICE")
                        BrandPill(
                            text: value.source == "BOOKING" ? "BOOKED" : "PROPOSAL",
                            tint: value.source == "BOOKING" ? BrandColor.accent : BrandColor.textMuted,
                        )
                    }
                    if let category = value.categoryName, !category.isEmpty {
                        Text(category).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("$\(value.price.isEmpty ? "0.00" : value.price)")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("\(value.durationMinutes.isEmpty ? "—" : value.durationMinutes) min")
                        .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                }
            }

            HStack(spacing: 10) {
                fieldColumn("Price") {
                    TextField("0.00", text: item.price)
                        .keyboardType(.decimalPad)
                        .modifier(ProConsultationInputStyle())
                        .disabled(saving)
                }
                fieldColumn("Duration") {
                    TextField("60", text: item.durationMinutes)
                        .keyboardType(.numberPad)
                        .modifier(ProConsultationInputStyle())
                        .disabled(saving)
                }
            }

            fieldColumn("Line-item notes") {
                TextField("Optional details for this line item…", text: item.notes, axis: .vertical)
                    .lineLimit(2...4)
                    .modifier(ProConsultationInputStyle())
                    .disabled(saving)
            }

            Button {
                removeItem(value.id)
            } label: {
                Text("Remove")
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(saving)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BrandColor.textMuted.opacity(0.12)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var servicePicker: some View {
        if loadingServices {
            Text("Loading your services…")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
        } else if !hasBaseItem && services.isEmpty {
            Text("No services found for your profile. Add offerings before sending consult approvals.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
        } else if pickerOptions.isEmpty {
            // A base service is set but it has no add-ons configured. Additional
            // services on one booking are modeled as add-ons of the base service.
            Text("No add-ons available for this service. Add-ons must be set up on your offering to bill additional services here.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        } else {
            HStack(spacing: 10) {
                Picker(hasBaseItem ? "Add an add-on" : "Select a service", selection: $selectedOptionId) {
                    ForEach(pickerOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(BrandColor.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button { addSelectedService() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("Add").font(BrandFont.body(14, .semibold))
                    }
                    .foregroundStyle(BrandColor.accent)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(BrandColor.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(saving)
            }
        }
    }

    private var notesField: some View {
        fieldColumn("Consultation notes") {
            TextField("Optional: goals, techniques, anything you agreed on…", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .modifier(ProConsultationInputStyle())
                .disabled(saving)
        }
    }

    private func fieldColumn<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandFont.mono(10)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(BrandColor.textMuted)
            content()
        }
    }

    // MARK: - Picker options (base vs add-on)
    //
    // The server requires exactly one BASE service per booking; additional
    // services are ADD_ONs drawn from the base offering's configured add-on set.
    // So until a base exists the picker offers base services; once one is set it
    // offers that offering's add-ons (which the server will accept as ADD_ON).

    private struct PickerOption: Identifiable {
        let id: String
        let label: String
        let name: String
        let isAddOn: Bool
        let serviceId: String
        let offeringId: String?
        let defaultPrice: Double?
        let defaultDuration: Int?
        let categoryName: String?
    }

    private var hasBaseItem: Bool { items.contains { $0.itemType == "BASE" } }
    private var baseOfferingId: String? {
        items.first(where: { $0.itemType == "BASE" })?.offeringId
    }

    private var pickerOptions: [PickerOption] {
        if !hasBaseItem {
            return services.map { service in
                PickerOption(
                    id: service.offeringId, label: serviceOptionLabel(service),
                    name: service.serviceName, isAddOn: false,
                    serviceId: service.serviceId, offeringId: service.offeringId,
                    defaultPrice: service.defaultPrice,
                    defaultDuration: service.defaultDurationMinutes,
                    categoryName: service.categoryName,
                )
            }
        }
        // Add-ons scoped to the current base offering.
        return addOns
            .filter { baseOfferingId == nil || $0.parentOfferingId == baseOfferingId }
            .map { addOn in
                PickerOption(
                    id: "\(addOn.parentOfferingId):\(addOn.serviceId)",
                    label: addOnOptionLabel(addOn), name: addOn.serviceName, isAddOn: true,
                    serviceId: addOn.serviceId, offeringId: addOn.parentOfferingId,
                    defaultPrice: addOn.defaultPrice,
                    defaultDuration: addOn.defaultDurationMinutes,
                    categoryName: addOn.categoryName,
                )
            }
    }

    // MARK: - Logic (ported from ConsultationForm.tsx)

    private func serviceOptionLabel(_ service: ProConsultationServiceOption) -> String {
        let categoryPrefix = service.categoryName.map { "\($0) · " } ?? ""
        let priceSuffix = service.defaultPrice.map { " ($\(ProConsultationMoney.label2($0)))" } ?? ""
        return "\(categoryPrefix)\(service.serviceName)\(priceSuffix)"
    }

    private func addOnOptionLabel(_ addOn: ProConsultationAddOnOption) -> String {
        let categoryPrefix = addOn.categoryName.map { "\($0) · " } ?? ""
        let priceSuffix = addOn.defaultPrice.map { " ($\(ProConsultationMoney.label2($0)))" } ?? ""
        let recommended = addOn.isRecommended ? " ★" : ""
        return "Add-on · \(categoryPrefix)\(addOn.serviceName)\(priceSuffix)\(recommended)"
    }

    private func loadServices() async {
        loadingServices = true
        errorText = nil
        defer { loadingServices = false }
        do {
            let response = try await session.client.proSession.consultationServices(bookingId: bookingId)
            services = response.services
            addOns = response.addOns
            syncSelectedOption()
        } catch let error as APIError {
            errorText = error.userMessage
        } catch {
            errorText = "Failed to load services."
        }
    }

    /// Keep `selectedOptionId` pointing at a valid option as the option set
    /// changes (base services → that offering's add-ons once a base is added).
    private func syncSelectedOption() {
        if !pickerOptions.contains(where: { $0.id == selectedOptionId }) {
            selectedOptionId = pickerOptions.first?.id ?? ""
        }
    }

    private func addSelectedService() {
        errorText = nil
        message = nil
        guard let option = pickerOptions.first(where: { $0.id == selectedOptionId })
            ?? pickerOptions.first else {
            errorText = "Select a service to add."
            return
        }

        // The first base line uses the suggested total when present, else the
        // offering default. Add-ons always use their own default price.
        let price: String
        if !option.isAddOn, items.isEmpty, let suggestedTotal { price = suggestedTotal }
        else if let defaultPrice = option.defaultPrice { price = ProConsultationMoney.label2(defaultPrice) }
        else { price = "" }

        let duration = (option.defaultDuration ?? 0) > 0 ? String(option.defaultDuration ?? 0) : ""

        items.append(
            ProConsultationLineItem(
                bookingServiceItemId: nil,
                offeringId: option.offeringId,
                serviceId: option.serviceId,
                itemType: option.isAddOn ? "ADD_ON" : "BASE",
                label: option.name,
                categoryName: option.categoryName,
                price: price,
                durationMinutes: duration,
                notes: "",
                sortOrder: items.count,
                source: "PROPOSAL",
            )
        )
        items = ProConsultationLineItem.sorted(items)
        syncSelectedOption()
    }

    private func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        for index in items.indices { items[index].sortOrder = index }
        items = ProConsultationLineItem.sorted(items)
        syncSelectedOption()
    }

    private func submit() async {
        errorText = nil
        message = nil
        scheduleNotice = nil
        guard !items.isEmpty else { errorText = "Add at least one service."; return }
        guard itemsValid else {
            errorText = "Fix line items before sending. Price must be valid and duration must be whole minutes."
            return
        }

        saving = true
        defer { saving = false }

        let payload: [ProConsultationProposalItem] = items.enumerated().compactMap { index, item in
            guard let price = ProConsultationMoney.parse(item.price),
                  let duration = ProConsultationMoney.parseDuration(item.durationMinutes)
            else { return nil }
            let trimmedNotes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProConsultationProposalItem(
                bookingServiceItemId: item.bookingServiceItemId,
                offeringId: item.offeringId,
                serviceId: item.serviceId,
                itemType: item.itemType,
                label: item.label,
                categoryName: item.categoryName,
                price: ProConsultationMoney.label2(price),
                durationMinutes: duration,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                sortOrder: index,
                source: item.source,
            )
        }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let result = try await session.client.proSession.sendConsultationProposal(
                bookingId: bookingId,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                proposedTotal: ProConsultationMoney.label2(total),
                items: payload,
            )
            if result.undeliverable {
                errorText = "Consultation saved, but we couldn’t send the secure link — this client has no email or phone on file (or delivery failed). Add a contact method and resend."
                onSent()
                return
            }
            // F12 — the send worked, and the new end time is worth a word.
            // `onSent()` reloads the hub, which flips to "Waiting on client" and
            // takes this view (and the notice) with it, so hold here instead.
            if let notice = result.scheduleNotice {
                scheduleNotice = notice
                return
            }
            message = "Sent to client for approval."
            onSent()
        } catch let error as APIError {
            errorText = error.userMessage
        } catch {
            errorText = "Network error sending consultation."
        }
    }
}

/// A consultation form line item — native counterpart of the web `LineItem`.
/// Money/duration parsing + formatting, ported from ConsultationForm's
/// `normalizeMoneyInput` / `normalizeDurationInput` / `sumMoneyStrings`.
enum ProConsultationMoney {
    /// Parse a money string ($/commas stripped); nil if invalid (web regex
    /// `^\d*\.?\d{0,2}$`) or non-positive-empty. Empty → nil here (callers gate on >0).
    static func parse(_ raw: String) -> Double? {
        let value = raw.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let pattern = "^[0-9]*\\.?[0-9]{0,2}$"
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let normalized = value.hasPrefix(".") ? "0\(value)" : value
        if normalized == "." || normalized == "0." { return nil }
        return Double(normalized)
    }

    static func parseDuration(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              let n = Int(value), n > 0 else { return nil }
        return n
    }

    /// Sum of the valid prices, rounded to cents (web `sumMoneyStrings`).
    static func sum(_ prices: [String]) -> Double {
        let total = prices.reduce(0.0) { acc, raw in acc + (parse(raw) ?? 0) }
        return (total * 100).rounded() / 100
    }

    /// "$X.XX" total label.
    static func label(_ amount: Double) -> String { "$" + label2(amount) }
    /// "X.XX" (two-decimal) value.
    static func label2(_ amount: Double) -> String { String(format: "%.2f", amount) }
}

/// The bordered text-field look used across the consultation form.
private struct ProConsultationInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
