import SwiftUI
import TovisKit

/// The pro's service-tag picker: the chosen tags as removable pills, a search
/// field, and the filtered option list.
///
/// Extracted from `ProMediaEditSheet`, which had the only copy, when the new-post
/// screen needed the identical control — a second hand-rolled copy is how three
/// display-name ports drifted (see `ProPublicNameSource`). Both callers feed the
/// same `serviceIds` set to the same taxonomy the server validates against.
///
/// Selection is an ORDERED array, not a `Set`: `POST /pro/media` falls back to
/// `serviceIds[0]` as the asset's primary service when the pro doesn't nominate
/// one, so "the first one I picked" has to survive. (The edit sheet's `PATCH` is
/// an order-insensitive replacement set, so it reads the same either way — it
/// just gets a deterministic order now instead of a `Set`'s arbitrary one.)
struct ProServiceTagPicker: View {
    let options: [ProMediaServiceTag]
    @Binding var selectedServiceIds: [String]
    /// Shown in place of the pills when nothing is picked yet. Each caller words
    /// its own gate ("before saving" vs "before posting"), so the copy stays out
    /// of the shared control.
    var emptyMessage: String
    var isDisabled: Bool = false

    @State private var query: String = ""

    private var selectedTags: [ProMediaServiceTag] {
        // Keyed off the selection order, not the options order, so the pills read
        // in the order the pro picked them — and pill 1 is the primary fallback.
        selectedServiceIds.compactMap { id in options.first { $0.serviceId == id } }
    }

    private var filteredOptions: [ProMediaServiceTag] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return options }
        return options.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !selectedTags.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(selectedTags) { tag in
                        Button { toggle(tag.serviceId) } label: {
                            HStack(spacing: 5) {
                                Text(tag.name).font(BrandFont.body(12, .semibold))
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(BrandColor.onAccent)
                            .padding(.vertical, 6).padding(.horizontal, 11)
                            .background(BrandColor.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(tag.name)")
                    }
                }
            } else {
                Text(emptyMessage)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.ember)
            }

            TextField("Search services", text: $query)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredOptions) { option in
                        optionRow(option)
                        if option.id != filteredOptions.last?.id {
                            Divider().overlay(BrandColor.textMuted.opacity(0.12))
                        }
                    }
                }
            }
            // ⚠️ A ScrollView is greedy — it takes the full height it's offered, so
            // this needs an explicit height, not just a maxHeight, or a 3-row list
            // sits in a box of dead space. Sized to the shorter of "the rows I have"
            // and a scrollable cap.
            .frame(height: min(CGFloat(max(filteredOptions.count, 1)) * 42, 220))
            .background(BrandColor.bgSecondary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .disabled(isDisabled)
    }

    private func optionRow(_ option: ProMediaServiceTag) -> some View {
        let selected = selectedServiceIds.contains(option.serviceId)
        return Button { toggle(option.serviceId) } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? BrandColor.accent : BrandColor.textMuted)
                Text(option.name)
                    .font(BrandFont.body(14, selected ? .semibold : .regular))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ serviceId: String) {
        if let index = selectedServiceIds.firstIndex(of: serviceId) {
            selectedServiceIds.remove(at: index)
        } else {
            selectedServiceIds.append(serviceId)
        }
    }
}
