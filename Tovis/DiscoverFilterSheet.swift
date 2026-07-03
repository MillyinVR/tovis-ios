// Discover filters — radius, sort, rating, price, open-now, and comes-to-you.
// All are honored server-side by GET /api/v1/search/pros (and plumbed through
// DiscoverService), so this is pure UI: it mutates the bindings and asks
// Discover to re-search on apply. Option values mirror the web SearchMapClient
// (rating 4.0+/4.5+; price under $50/$100/$200).
import SwiftUI
import TovisKit

struct DiscoverFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var radiusMiles: Int
    @Binding var sort: DiscoverService.Sort
    @Binding var mobileOnly: Bool
    @Binding var openNowOnly: Bool
    @Binding var minRating: Double?
    @Binding var maxPrice: Int?
    let onApply: () -> Void

    private let radiusOptions = [5, 10, 15, 25, 50]
    private let sortOptions: [(DiscoverService.Sort, String)] = [
        (.distance, "Distance"),
        (.rating, "Top rated"),
        (.price, "Price"),
        (.name, "Name"),
    ]
    private let ratingOptions: [(Double?, String)] = [
        (nil, "Any"),
        (4.0, "4.0+"),
        (4.5, "4.5+"),
    ]
    private let priceOptions: [(Int?, String)] = [
        (nil, "Any"),
        (50, "<$50"),
        (100, "<$100"),
        (200, "<$200"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    BrandSection(title: "Search radius", trailing: "\(radiusMiles) mi") {
                        HStack(spacing: 8) {
                            ForEach(radiusOptions, id: \.self) { miles in
                                chip("\(miles) mi", selected: radiusMiles == miles) { radiusMiles = miles }
                            }
                        }
                    }

                    BrandSection(title: "Sort by") {
                        VStack(spacing: 8) {
                            ForEach(sortOptions, id: \.0) { option in
                                sortRow(option.1, selected: sort == option.0) { sort = option.0 }
                            }
                        }
                    }

                    BrandSection(title: "Rating") {
                        HStack(spacing: 8) {
                            ForEach(ratingOptions, id: \.1) { option in
                                chip(option.1, selected: minRating == option.0) { minRating = option.0 }
                            }
                        }
                    }

                    BrandSection(title: "Starting price") {
                        HStack(spacing: 8) {
                            ForEach(priceOptions, id: \.1) { option in
                                chip(option.1, selected: maxPrice == option.0) { maxPrice = option.0 }
                            }
                        }
                    }

                    BrandSection(title: "Options") {
                        VStack(spacing: 10) {
                            Toggle(isOn: $openNowOnly) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open now")
                                        .font(BrandFont.body(15, .medium)).foregroundStyle(BrandColor.textPrimary)
                                    Text("Pros with hours open at this moment")
                                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                                }
                            }
                            .tint(BrandColor.accent)

                            Toggle(isOn: $mobileOnly) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Comes to you")
                                        .font(BrandFont.body(15, .medium)).foregroundStyle(BrandColor.textPrimary)
                                    Text("Pros who travel to you")
                                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                                }
                            }
                            .tint(BrandColor.accent)
                        }
                    }

                    Button {
                        onApply()
                        dismiss()
                    } label: {
                        Text("Apply").font(BrandFont.body(17, .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(BrandColor.onAccent)
                            .background(BrandColor.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        radiusMiles = 25; sort = .distance; mobileOnly = false
                        openNowOnly = false; minRating = nil; maxPrice = nil
                    }
                    .tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(BrandFont.body(14, .medium))
                .foregroundStyle(selected ? BrandColor.onAccent : BrandColor.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(selected ? BrandColor.accent : BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(selected ? 0 : 0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func sortRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(BrandFont.body(15, .medium)).foregroundStyle(BrandColor.textPrimary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? BrandColor.accent.opacity(0.6) : BrandColor.textMuted.opacity(0.18),
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
