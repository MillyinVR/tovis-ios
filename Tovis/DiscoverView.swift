// Discover — search pros + services (GET /api/v1/search). Native rebuild of the
// web /search surface: a query field, a Pros/Services toggle, and result rows
// that push into the pro profile. Booking flow (holds → availability → checkout)
// lands later; for now Discover → pro profile is the path.
import SwiftUI
import TovisKit

struct DiscoverView: View {
    @Environment(SessionModel.self) private var session

    enum Tab: String, CaseIterable { case pros = "Pros", services = "Services" }

    @State private var query = ""
    @State private var tab: Tab = .pros
    @State private var pros: [SearchPro] = []
    @State private var services: [SearchServiceItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var searchToken = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                searchField
                tabs
                results
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .task { if pros.isEmpty && services.isEmpty { await runSearch() } }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(BrandColor.textMuted)
            TextField("Search pros or services", text: $query)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
                .onChange(of: query) { debouncedSearch() }
            if !query.isEmpty {
                Button { query = ""; Task { await runSearch() } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BrandColor.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 20)
    }

    private var tabs: some View {
        HStack(spacing: 28) {
            ForEach(Tab.allCases, id: \.self) { item in
                let active = item == tab
                Button { tab = item; Task { await runSearch() } } label: {
                    VStack(spacing: 8) {
                        Text(item.rawValue.uppercased())
                            .font(BrandFont.mono(12)).tracking(0.8)
                            .foregroundStyle(active ? BrandColor.textPrimary : BrandColor.textMuted)
                        Rectangle().fill(active ? BrandColor.accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if loading && pros.isEmpty && services.isEmpty {
            ProgressView().tint(BrandColor.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Text(errorMessage).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await runSearch() } }
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 40)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    switch tab {
                    case .pros:
                        if pros.isEmpty { emptyRow("No pros found") }
                        ForEach(pros) { pro in
                            NavigationLink {
                                ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
                            } label: { ProRow(pro: pro) }
                            .buttonStyle(.plain)
                        }
                    case .services:
                        if services.isEmpty { emptyRow("No services found") }
                        ForEach(services) { service in
                            Button {
                                query = service.name; tab = .pros; Task { await runSearch() }
                            } label: { ServiceRow(service: service) }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity).padding(.top, 48)
    }

    // MARK: - Search

    private func debouncedSearch() {
        searchToken += 1
        let token = searchToken
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if token == searchToken { await runSearch() }
        }
    }

    private func runSearch() async {
        loading = true
        errorMessage = nil
        do {
            switch tab {
            case .pros: pros = try await session.client.search.pros(query: query)
            case .services: services = try await session.client.search.services(query: query)
            }
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t search. Try again."
        }
        loading = false
    }
}

// MARK: - Rows

private struct ProRow: View {
    let pro: SearchPro

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                BrandAvatar(name: pro.displayName, avatarUrl: pro.avatarUrl, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pro.displayName)
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    if let meta = metaLine {
                        Text(meta).font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let price = pro.minPrice {
                            Text("from \(money(price))")
                                .font(BrandFont.body(12.5, .semibold)).foregroundStyle(BrandColor.accent)
                        }
                        if pro.supportsMobile { BrandPill(text: "Mobile", tint: BrandColor.iris) }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let craft = pro.professionType { parts.append(craft.capitalized) }
        if let rating = pro.ratingAvg, pro.ratingCount > 0 {
            parts.append("★ \(String(format: "%.1f", rating)) (\(pro.ratingCount))")
        }
        if let d = pro.distanceMiles { parts.append("\(String(format: "%.1f", d)) mi") }
        return parts.isEmpty ? pro.locationLabel : parts.joined(separator: " · ")
    }

    private func money(_ value: Double) -> String {
        let whole = value.rounded() == value
        return "$" + (whole ? String(Int(value)) : String(format: "%.2f", value))
    }
}

private struct ServiceRow: View {
    let service: SearchServiceItem

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                Image(systemName: "scissors")
                    .font(.system(size: 16)).foregroundStyle(BrandColor.accent)
                    .frame(width: 34, height: 34)
                    .background(BrandColor.accent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                    if let cat = service.categoryName {
                        Text(cat).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    }
                }
                Spacer()
                Text("Find pros")
                    .font(BrandFont.mono(10)).tracking(0.6).foregroundStyle(BrandColor.accent)
            }
        }
    }
}