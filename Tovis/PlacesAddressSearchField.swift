// A reusable Google Places address search field: type an address, see live
// predictions, pick one and it resolves to an exact pin (placeId + lat/lng) via
// the backend Places proxy (PlacesService — the Google key is server-only). Binds
// the resolved `PlaceDetails?` (nil = nothing picked yet); editing the text after
// a pick clears it. Shared by the client `AddServiceAddressSheet` and the pro
// new-booking MOBILE address sub-section so the autocomplete + resolve wiring
// lives in one place.
import SwiftUI
import TovisKit

struct PlacesAddressSearchField: View {
    @Environment(SessionModel.self) private var session

    /// The resolved address, or nil while the field is empty / being edited.
    @Binding var picked: PlaceDetails?
    var placeholder: String = "Search your address"
    /// Autocomplete bias: "ADDRESS" for a street-level service address (default),
    /// "AREA" for a city/ZIP-level discovery origin (mirrors the web `kind=AREA`).
    var kind: String = "ADDRESS"
    /// Disables editing (e.g. while the parent is saving).
    var disabled: Bool = false

    @State private var search = ""
    @State private var predictions: [PlacePrediction] = []
    @State private var searchToken = 0
    @State private var sessionToken = UUID().uuidString
    @State private var resolving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            if picked == nil { predictionList }
            if let error {
                Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(BrandColor.textMuted)
            TextField(placeholder, text: $search)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                .autocorrectionDisabled()
                .disabled(disabled)
                .onChange(of: search) { _, _ in onSearchChanged() }
            if resolving {
                ProgressView().controlSize(.mini).tint(BrandColor.accent)
            } else if picked != nil {
                Button { clearPick() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BrandColor.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
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
        .background(predictions.isEmpty ? Color.clear : BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(predictions.isEmpty ? Color.clear : BrandColor.textMuted.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Autocomplete

    private func onSearchChanged() {
        // Editing after a pick invalidates it (the text no longer matches a place).
        if picked != nil { picked = nil }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { predictions = []; return }

        searchToken += 1
        let token = searchToken
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard token == searchToken else { return }
            let results = try? await session.client.places.autocomplete(
                input: trimmed, sessionToken: sessionToken, kind: kind
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
        search = ""
        predictions = []
        error = nil
    }
}
