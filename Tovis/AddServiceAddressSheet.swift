// Add a service address for a mobile booking. Autocomplete-first: the client
// searches an address, picks a Google Places suggestion, and we resolve it to
// exact coordinates via the backend Places proxy — so the saved SERVICE_ADDRESS
// has precise lat/lng for the pro's travel-radius check (no server re-geocode,
// no "couldn't verify that address" guesswork). An optional apt/unit + label ride
// on top.
import SwiftUI
import TovisKit

struct AddServiceAddressSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called with the saved (geocoded) address so the caller can select it.
    let onSaved: (ClientAddress) -> Void

    @State private var label = ""
    @State private var search = ""
    @State private var apt = ""

    @State private var predictions: [PlacePrediction] = []
    @State private var picked: PlaceDetails?
    @State private var searchToken = 0
    @State private var sessionToken = UUID().uuidString
    @State private var resolving = false

    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Label (optional)", text: $label, placeholder: "Home, Studio…")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Address").font(BrandFont.body(12, .medium)).foregroundStyle(BrandColor.textMuted)
                        addressSearchField
                        if picked == nil { predictionList }
                    }

                    if picked != nil {
                        field("Apt / suite (optional)", text: $apt, placeholder: "Apt 4B")
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }

                    Button { Task { await save() } } label: {
                        Group {
                            if saving { ProgressView().tint(BrandColor.onAccent) }
                            else { Text("Save address").font(BrandFont.body(17, .semibold)) }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .foregroundStyle(BrandColor.onAccent)
                        .background(picked != nil ? BrandColor.accent : BrandColor.textMuted.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(picked == nil || saving)
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Service address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    private var addressSearchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(BrandColor.textMuted)
            TextField("Search your address", text: $search)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                .autocorrectionDisabled()
                .onChange(of: search) { _, _ in onSearchChanged() }
            if resolving {
                ProgressView().controlSize(.mini).tint(BrandColor.accent)
            } else if picked != nil {
                Button { clearPick() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BrandColor.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(picked != nil ? BrandColor.accent.opacity(0.5) : BrandColor.textMuted.opacity(0.18),
                    lineWidth: 1))
    }

    private var predictionList: some View {
        VStack(spacing: 0) {
            ForEach(predictions) { prediction in
                Button { Task { await pick(prediction) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prediction.mainText)
                            .font(BrandFont.body(14, .medium)).foregroundStyle(BrandColor.textPrimary)
                        Text(prediction.secondaryText)
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                if prediction.id != predictions.last?.id {
                    Divider().background(BrandColor.textMuted.opacity(0.12))
                }
            }
        }
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BrandFont.body(12, .medium)).foregroundStyle(BrandColor.textMuted)
            TextField(placeholder, text: text)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                .padding(12)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
        }
    }

    // MARK: - Autocomplete

    private func onSearchChanged() {
        // Editing after a pick invalidates it (the text no longer matches a place).
        if picked != nil { picked = nil; apt = "" }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { predictions = []; return }

        searchToken += 1
        let token = searchToken
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard token == searchToken else { return }
            let results = try? await session.client.places.autocomplete(
                input: trimmed, sessionToken: sessionToken
            )
            if token == searchToken { predictions = results ?? [] }
        }
    }

    private func pick(_ prediction: PlacePrediction) async {
        resolving = true
        defer { resolving = false }
        do {
            let details = try await session.client.places.details(
                placeId: prediction.placeId, sessionToken: sessionToken
            )
            picked = details
            search = details.formattedAddress
            predictions = []
            sessionToken = UUID().uuidString // a details call closes the Places session
            error = nil
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t load that address. Try another."
        }
    }

    private func clearPick() {
        picked = nil
        apt = ""
        search = ""
        predictions = []
    }

    private func save() async {
        guard let place = picked, !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedApt = apt.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = try await session.client.addresses.createServiceAddress(
                from: place,
                label: trimmedLabel.isEmpty ? nil : trimmedLabel,
                apt: trimmedApt.isEmpty ? nil : trimmedApt
            )
            onSaved(address)
            dismiss()
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t save that address. Try again."
        }
    }
}
