// Discover — native rebuild of the web SearchMapClient (/search): a full-screen
// map of nearby pros with category chips + free-text search, a Map/List toggle,
// an active-pro card, and a "Search this area" affordance when you pan. Backed by
// GET /api/v1/search/pros (geo) + /api/v1/discover/categories, the same data the
// web uses. Web renders Leaflet/OSM; here we use native MapKit.
import SwiftUI
import MapKit
import TovisKit

struct DiscoverView: View {
    @Environment(SessionModel.self) private var session
    @State private var location = LocationManager()

    private enum ViewMode { case map, list }

    /// Discover's primary axis (web D2): a looks-first inspiration grid ("Tap any
    /// look to book the pro who made it") vs. the geo pro-finder. Opens on looks.
    private enum DiscoverMode { case looks, pros }

    @State private var discoverMode: DiscoverMode = .looks

    @State private var query = ""
    @State private var categories: [DiscoverCategory] = []
    @State private var selectedCategory: DiscoverCategory?
    @State private var pros: [SearchProItem] = []
    @State private var activeProId: String?
    @State private var viewMode: ViewMode = .list   // pro-mode inner toggle (grid ↔ map)
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var searchToken = 0
    /// Defer the pro search + geolocation until the pro-finder is first opened
    /// (web parity — looks mode never geolocates).
    @State private var didLoadPros = false

    // Looks-first grid (D2). Ranked + category-filtered, cursor-paginated, with
    // 1-tap Book (resolve the look's offering → BookingFlowView) and tag chips
    // that open the web tag page in Safari — same conventions as the Looks feed.
    @State private var looks: [LooksFeedItem] = []
    @State private var looksCursor: String?
    @State private var looksLoading = false
    @State private var looksLoadingMore = false
    @State private var didLoadLooks = false
    @State private var trendingTags: [TrendingTag] = []
    @State private var bookLaunch: DiscoverBookLaunch?
    @State private var resolvingBookId: String?
    @State private var tagWebFor: DiscoverTagLink?
    /// Programmatic nav for the Book fallback (look has no bookable service) and
    /// look/pro card taps.
    @State private var navPath: [String] = []
    @State private var looksToken = 0

    // Map state
    @State private var camera: MapCameraPosition = .region(Self.fallbackRegion)
    @State private var searchedOrigin = Self.fallbackCenter   // origin of the last search
    @State private var mapCenter = Self.fallbackCenter        // current viewport center
    @State private var mapSpan = Self.fallbackRegion.span     // current zoom (for clustering)
    @State private var didInitialLocate = false

    // Filters (all already honored server-side via DiscoverService.searchPros).
    // Radius seeds from the client's saved Discovery-location setting (default 15mi,
    // web parity); the filter sheet can override it per session and persists it back.
    @State private var radiusMiles = DiscoveryRadius.current
    @State private var sort: DiscoverService.Sort = .distance
    @State private var mobileOnly = false
    @State private var openNowOnly = false
    @State private var minRating: Double?
    @State private var maxPrice: Int?
    @State private var showFilters = false

    // Place autocomplete — "jump the map to a place" suggestions for the search bar.
    @State private var placeResults: [PlacePrediction] = []
    @State private var placeToken = 0
    @State private var placeSessionToken = UUID().uuidString
    @State private var resolvingPlace = false

    // Los Angeles fallback so the first paint isn't empty before a fix arrives.
    private static let fallbackCenter = CLLocationCoordinate2D(latitude: 34.05, longitude: -118.24)
    private static let fallbackRegion = MKCoordinateRegion(
        center: fallbackCenter,
        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
    )

    /// True when any filter differs from the defaults (drives the filter-button dot).
    /// The radius baseline is the saved Discovery-location radius (which the filter
    /// sheet writes back on apply), so an unchanged radius never lights the dot.
    private var filtersActive: Bool {
        radiusMiles != DiscoveryRadius.current || sort != .distance || mobileOnly
            || openNowOnly || minRating != nil || maxPrice != nil
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack(alignment: .top) {
                BrandColor.bgPrimary.ignoresSafeArea()

                if discoverMode == .looks {
                    looksLayer
                } else {
                    Group {
                        if viewMode == .map { mapLayer } else { listLayer }
                    }

                    topControls

                    if viewMode == .map, let pro = activePro {
                        activeCard(pro)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationDestination(for: String.self) { proId in
                ProProfileView(professionalId: proId, fallbackName: proName(proId) ?? "Pro")
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(BrandColor.accent)
        .task {
            if categories.isEmpty {
                categories = (try? await session.client.discover.categories()) ?? []
            }
            if !didLoadLooks { await loadLooks() }
            if trendingTags.isEmpty {
                trendingTags = (try? await session.client.discover.trendingTags()) ?? []
            }
        }
        .onChange(of: discoverMode) { enterMode() }
        .onChange(of: location.coordinate?.latitude) { recenterOnUser() }
        .sheet(item: $bookLaunch) { launch in
            BookingFlowView(
                professionalId: launch.pro.id,
                proName: launch.pro.displayName,
                offering: launch.offering
            )
        }
        .sheet(item: $tagWebFor) { link in
            SafariView(url: link.url)
        }
    }

    /// Lazily kick off the pro search + geolocation the first time the pro-finder
    /// is opened (web parity — looks mode never geolocates). If the client saved a
    /// Discovery location, the search opens there; otherwise it geolocates as before.
    private func enterMode() {
        guard discoverMode == .pros, !didLoadPros else { return }
        didLoadPros = true
        radiusMiles = DiscoveryRadius.current
        Task { await seedFromSavedAreaThenSearch() }
    }

    /// Seed the origin from the client's saved Discovery location when set (so a
    /// returning user lands on their area), else fall back to the device location.
    private func seedFromSavedAreaThenSearch() async {
        if let area = try? await session.client.addresses.searchArea(),
           let lat = area.lat, let lng = area.lng {
            // The saved area carries its own synced radius; fall back to the cache.
            radiusMiles = area.radiusMiles ?? DiscoveryRadius.current
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            searchedOrigin = coord
            mapCenter = coord
            didInitialLocate = true   // a later CoreLocation fix must not steal the saved area
            withAnimation {
                camera = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
                ))
            }
            await runSearch()
            location.request()        // still surface the user dot / recenter button
        } else {
            location.request()        // no saved area → geolocate (recenterOnUser searches on fix)
            await runSearch()
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Map(position: $camera, selection: $activeProId) {
            ForEach(clusters) { cluster in
                if cluster.count == 1, let pro = cluster.items.first {
                    Annotation(pro.displayName, coordinate: cluster.coordinate) {
                        ProPin(active: pro.id == activeProId)
                    }
                    .tag(pro.id)
                } else {
                    Annotation("", coordinate: cluster.coordinate) {
                        ClusterPin(count: cluster.count)
                            .onTapGesture { zoomInto(cluster) }
                    }
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton() }
        .ignoresSafeArea(edges: .top)
        .onMapCameraChange(frequency: .onEnd) { context in
            mapCenter = context.region.center
            mapSpan = context.region.span
        }
        .overlay(alignment: .top) {
            if showSearchThisArea {
                Button { Task { await searchThisArea() } } label: {
                    Label("Search this area", systemImage: "arrow.clockwise")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(.vertical, 9).padding(.horizontal, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 168)   // sits below the floating header + chips
                .transition(.opacity)
            }
        }
    }

    /// Distance the viewport has drifted from the searched origin (miles).
    private var driftMiles: Double {
        CLLocation(latitude: mapCenter.latitude, longitude: mapCenter.longitude)
            .distance(from: CLLocation(latitude: searchedOrigin.latitude, longitude: searchedOrigin.longitude))
            / 1609.34
    }
    private var showSearchThisArea: Bool { driftMiles >= 0.5 }

    private struct Pinnable: Identifiable {
        let item: SearchProItem
        let coordinate: CLLocationCoordinate2D
        var id: String { item.id }
    }

    private var pinnable: [Pinnable] {
        pros.compactMap { pro in
            guard let lat = pro.mapLocation?.lat, let lng = pro.mapLocation?.lng else { return nil }
            return Pinnable(item: pro, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
    }

    private struct MapCluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let items: [SearchProItem]
        var count: Int { items.count }
    }

    /// Grid-cluster the pins so they don't overlap when zoomed out (SwiftUI Map
    /// has no native clustering). Cells scale with the current zoom span, so pins
    /// merge when far apart on screen and split as you zoom in.
    private var clusters: [MapCluster] {
        let pins = pinnable
        guard !pins.isEmpty else { return [] }
        let cellLat = max(mapSpan.latitudeDelta / 8, 0.0004)
        let cellLng = max(mapSpan.longitudeDelta / 8, 0.0004)

        var buckets: [String: [Pinnable]] = [:]
        for pin in pins {
            let row = Int((pin.coordinate.latitude / cellLat).rounded(.down))
            let col = Int((pin.coordinate.longitude / cellLng).rounded(.down))
            buckets["\(row):\(col)", default: []].append(pin)
        }

        return buckets.map { key, group in
            let lat = group.reduce(0.0) { $0 + $1.coordinate.latitude } / Double(group.count)
            let lng = group.reduce(0.0) { $0 + $1.coordinate.longitude } / Double(group.count)
            return MapCluster(
                id: group.count == 1 ? group[0].id : key,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                items: group.map(\.item)
            )
        }
    }

    private func zoomInto(_ cluster: MapCluster) {
        withAnimation {
            camera = .region(MKCoordinateRegion(
                center: cluster.coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: max(mapSpan.latitudeDelta / 3, 0.002),
                    longitudeDelta: max(mapSpan.longitudeDelta / 3, 0.002)
                )
            ))
        }
    }

    // MARK: - List

    // The web "GRID" view: a "Trending near you" portrait rail + a 2-column grid
    // of pro cards (DiscoverGridView / TrendingProRail).
    private var listLayer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading && pros.isEmpty {
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else if pros.isEmpty {
                    Text("No pros found nearby. Try a wider search or another area.")
                        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 14)
                } else {
                    if !trending.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            gridSectionHeader("Trending near you")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(trending) { pro in
                                        NavigationLink(value: pro.id) { TrendingCard(pro: pro) }
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        gridSectionHeader("Pros near you")
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(pros) { pro in
                                NavigationLink(value: pro.id) {
                                    ProGridCard(pro: pro, active: pro.id == activeProId)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 108)   // clear the floating header + chips (list starts below the status bar)
            .padding(.bottom, 24)
        }
    }

    private var trending: [SearchProItem] { Array(pros.prefix(10)) }

    private func gridSectionHeader(_ text: String) -> some View {
        Text("◆ \(text)".uppercased())
            .font(BrandFont.mono(10)).tracking(1.4)
            .foregroundStyle(BrandColor.textMuted)
            .padding(.leading, 2)
    }

    // MARK: - Top controls (search + view toggle + category chips)

    private var topControls: some View {
        VStack(spacing: 10) {
            HStack {
                modeToggle
                Spacer()
            }
            HStack(spacing: 10) {
                searchField
                filterButton
                viewToggle
            }
            if !placeResults.isEmpty { placeSuggestions }
            categoryRail
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Mode toggle (Looks ↔ Find a pro) — web DiscoverModeToggle

    private var modeToggle: some View {
        HStack(spacing: 4) {
            modeButton(.looks, label: "Looks", icon: "sparkles")
            modeButton(.pros, label: "Find a pro", icon: "mappin.and.ellipse")
        }
        .padding(4)
        .background(BrandColor.bgPrimary.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func modeButton(_ mode: DiscoverMode, label: String, icon: String) -> some View {
        let active = discoverMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { discoverMode = mode }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(label.uppercased())
                    .font(BrandFont.mono(11)).tracking(0.8)
            }
            .foregroundStyle(active ? BrandColor.bgPrimary : BrandColor.textSecondary)
            .padding(.vertical, 6).padding(.horizontal, 11)
            .background(active ? AnyShapeStyle(BrandColor.textPrimary) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: - Looks-first mode (web D2 LooksBookableGrid + TrendingTagsRail)

    private var looksLayer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    Text("Discover")
                        .font(BrandFont.display(26, .semibold)).italic()
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    modeToggle
                }

                Text("Tap any look to book the pro who made it.")
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)

                if !categories.isEmpty { categoryRail }
                trendingRail

                looksGrid
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var trendingRail: some View {
        Group {
            if !trendingTags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    gridSectionHeader("Trending tags")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(trendingTags) { tag in
                                Button { openTag(tag) } label: {
                                    Text("#\(tag.display)")
                                        .font(BrandFont.mono(11))
                                        .foregroundStyle(BrandColor.textPrimary)
                                        .padding(.vertical, 7).padding(.horizontal, 13)
                                        .background(BrandColor.bgPrimary.opacity(0.3), in: Capsule())
                                        .overlay(Capsule().stroke(BrandColor.accent.opacity(0.4), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var looksGrid: some View {
        if looksLoading && looks.isEmpty {
            ProgressView().tint(BrandColor.accent)
                .frame(maxWidth: .infinity).padding(.top, 60)
        } else if looks.isEmpty {
            VStack(spacing: 6) {
                Text("No looks to book yet")
                    .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Try a different category, or switch to Find a pro to browse by location.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 20)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(looks) { look in
                    DiscoverLookCard(look: look, resolving: resolvingBookId == look.id) {
                        Task { await startBooking(look) }
                    }
                }
            }

            if looksCursor != nil {
                Button { Task { await loadMoreLooks() } } label: {
                    Text(looksLoadingMore ? "Loading…" : "Load more")
                        .font(BrandFont.mono(11)).tracking(0.8)
                        .foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(BrandColor.bgPrimary.opacity(0.25), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(looksLoadingMore)
                .padding(.top, 8)
            }
        }
    }

    /// The active discover category as a slug for the looks feed (nil = all).
    private var activeCategorySlug: String? {
        guard let cat = selectedCategory, !cat.isAll else { return nil }
        return cat.slug
    }

    private func selectCategory(_ cat: DiscoverCategory) {
        selectedCategory = cat.isAll ? nil : cat
        if discoverMode == .looks {
            Task { await loadLooks() }
        } else {
            Task { await runSearch() }
        }
    }

    /// The web tag page for a chip tap (mirrors the Looks feed's `tagURL`).
    private func openTag(_ tag: TrendingTag) {
        guard let slug = tag.slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.tovis.app/looks/tags/\(slug)") else { return }
        tagWebFor = DiscoverTagLink(url: url)
    }

    private func loadLooks() async {
        looksToken += 1
        let token = looksToken
        looksLoading = true
        didLoadLooks = true
        do {
            let page = try await session.client.looks.feed(
                category: activeCategorySlug, sort: "ranked", limit: 24
            )
            guard token == looksToken else { return }
            looks = page.items
            looksCursor = page.nextCursor
        } catch {
            guard token == looksToken else { return }
            looks = []
            looksCursor = nil
        }
        if token == looksToken { looksLoading = false }
    }

    private func loadMoreLooks() async {
        guard let cursor = looksCursor, !looksLoadingMore else { return }
        looksLoadingMore = true
        defer { looksLoadingMore = false }
        do {
            let page = try await session.client.looks.feed(
                category: activeCategorySlug, sort: "ranked", cursor: cursor, limit: 24
            )
            let seen = Set(looks.map(\.id))
            looks.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            looksCursor = page.nextCursor
        } catch {
            // Best-effort — leave the current page intact on failure.
        }
    }

    /// 1-tap Book from the grid — resolve the look's offering and open the
    /// booking sheet preselected (web parity on the conversion). Falls back to the
    /// pro profile when the look carries no service or the fetch fails.
    private func startBooking(_ look: LooksFeedItem) async {
        guard let pro = look.professional else { return }
        guard resolvingBookId == nil else { return }
        resolvingBookId = look.id
        defer { resolvingBookId = nil }

        func fallbackToProfile() {
            if navPath.last != pro.id { navPath.append(pro.id) }
        }

        guard let serviceId = look.serviceId else { fallbackToProfile(); return }
        do {
            let profile = try await session.client.profiles.professional(id: pro.id)
            guard let offering = profile.offerings.first(where: { $0.serviceId == serviceId }) else {
                fallbackToProfile()
                return
            }
            bookLaunch = DiscoverBookLaunch(pro: pro, offering: offering)
        } catch {
            fallbackToProfile()
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(BrandColor.textMuted)
            TextField("Search pros, services, or a place", text: $query)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
                .onChange(of: query) { debouncedSearch(); loadPlaceSuggestions() }
            if loading {
                ProgressView().controlSize(.mini).tint(BrandColor.accent)
            } else if !query.isEmpty {
                Button { query = ""; Task { await runSearch() } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BrandColor.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1))
    }

    private var viewToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { viewMode = viewMode == .map ? .list : .map }
        } label: {
            Image(systemName: viewMode == .map ? "list.bullet" : "map")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BrandColor.textPrimary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewMode == .map ? "Show list" : "Show map")
    }

    private var filterButton: some View {
        Button { showFilters = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(filtersActive ? BrandColor.accent : BrandColor.textPrimary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(filtersActive ? BrandColor.accent.opacity(0.6) : BrandColor.textMuted.opacity(0.2),
                            lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if filtersActive {
                        Circle().fill(BrandColor.accent).frame(width: 8, height: 8).padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filters")
        .sheet(isPresented: $showFilters) {
            DiscoverFilterSheet(
                radiusMiles: $radiusMiles, sort: $sort, mobileOnly: $mobileOnly,
                openNowOnly: $openNowOnly, minRating: $minRating, maxPrice: $maxPrice,
                defaultRadius: DiscoveryRadius.current,
                onApply: {
                    // Radius doubles as the saved Discovery-location radius — persist it
                    // so it sticks (and clears the filter dot at its new baseline).
                    DiscoveryRadius.set(radiusMiles)
                    Task { await runSearch() }
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.identity) { cat in
                    let active = selectedCategory?.identity == cat.identity
                        || (selectedCategory == nil && cat.isAll)
                    Button {
                        selectCategory(cat)
                    } label: {
                        Text(cat.isAll ? "All" : cat.label)
                            .font(BrandFont.body(13, active ? .semibold : .regular))
                            .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                            .padding(.vertical, 7).padding(.horizontal, 13)
                            .background(active ? AnyShapeStyle(BrandColor.accent) : AnyShapeStyle(.ultraThinMaterial),
                                        in: Capsule())
                            .overlay(Capsule().stroke(BrandColor.textMuted.opacity(active ? 0 : 0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Active pro card (map mode)

    private var activePro: SearchProItem? {
        guard let id = activeProId else { return nil }
        return pros.first { $0.id == id }
    }

    private func activeCard(_ pro: SearchProItem) -> some View {
        VStack {
            Spacer()
            NavigationLink(value: pro.id) {
                BrandSurface {
                    HStack(spacing: 12) {
                        BrandAvatar(name: pro.displayName, avatarUrl: pro.avatarUrl, size: 54)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pro.displayName)
                                .font(BrandFont.body(16, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                            if let meta = metaLine(pro) {
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
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(BrandColor.textMuted)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
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
        let origin = searchedOrigin
        do {
            let page = try await session.client.discover.searchPros(
                q: query,
                lat: origin.latitude,
                lng: origin.longitude,
                radiusMiles: radiusMiles,
                categoryId: selectedCategory?.id,
                sort: sort,
                mobileOnly: mobileOnly,
                openNowOnly: openNowOnly,
                minRating: minRating,
                maxPrice: maxPrice
            )
            pros = page.items
            if let active = activeProId, !pros.contains(where: { $0.id == active }) {
                activeProId = nil
            }
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t search. Try again."
        }
        loading = false
    }

    private func searchThisArea() async {
        searchedOrigin = mapCenter
        await runSearch()
    }

    // MARK: - Place autocomplete (jump the map to a place)

    private var placeSuggestions: some View {
        VStack(spacing: 0) {
            ForEach(placeResults) { place in
                Button { Task { await pickPlace(place) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(BrandColor.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.mainText)
                                .font(BrandFont.body(14, .medium)).foregroundStyle(BrandColor.textPrimary)
                            Text(place.secondaryText)
                                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                        }
                        Spacer(minLength: 8)
                        if resolvingPlace { ProgressView().controlSize(.mini).tint(BrandColor.accent) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9).padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                if place.id != placeResults.last?.id {
                    Divider().background(BrandColor.textMuted.opacity(0.12))
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1))
    }

    private func loadPlaceSuggestions() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { placeResults = []; return }
        placeToken += 1
        let token = placeToken
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard token == placeToken else { return }
            let results = try? await session.client.places.autocomplete(
                input: trimmed, sessionToken: placeSessionToken,
                lat: mapCenter.latitude, lng: mapCenter.longitude, kind: "ANY"
            )
            if token == placeToken { placeResults = Array((results ?? []).prefix(4)) }
        }
    }

    private func pickPlace(_ prediction: PlacePrediction) async {
        resolvingPlace = true
        defer { resolvingPlace = false }
        guard let details = try? await session.client.places.details(
            placeId: prediction.placeId, sessionToken: placeSessionToken
        ) else { return }

        placeSessionToken = UUID().uuidString // close the Places billing session
        placeToken += 1                        // cancel any in-flight suggestion fetch
        placeResults = []
        query = ""                             // a picked place is a location search, not text
        let coord = CLLocationCoordinate2D(latitude: details.lat, longitude: details.lng)
        searchedOrigin = coord
        mapCenter = coord
        withAnimation {
            camera = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            ))
        }
        await runSearch()
    }

    private func recenterOnUser() {
        guard !didInitialLocate, let coord = location.coordinate else { return }
        didInitialLocate = true
        searchedOrigin = coord
        mapCenter = coord
        withAnimation {
            camera = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            ))
        }
        Task { await runSearch() }
    }

    // MARK: - Helpers

    private func proName(_ id: String) -> String? { pros.first { $0.id == id }?.displayName }

    private func metaLine(_ pro: SearchProItem) -> String? {
        var parts: [String] = []
        if let craft = pro.professionType { parts.append(craft.capitalized) }
        if let rating = pro.ratingAvg, pro.ratingCount > 0 {
            parts.append("★ \(String(format: "%.1f", rating)) (\(pro.ratingCount))")
        }
        if let d = pro.distanceMiles { parts.append("\(String(format: "%.1f", d)) mi") }
        if parts.isEmpty { return pro.locationLabel ?? pro.mapLocation?.cityState }
        return parts.joined(separator: " · ")
    }

    private func money(_ value: Double) -> String {
        value.rounded() == value ? "$\(Int(value))" : String(format: "$%.2f", value)
    }
}

// MARK: - Map pin

private struct ProPin: View {
    let active: Bool

    var body: some View {
        ZStack {
            if active {
                Circle().fill(BrandColor.gold).frame(width: 26, height: 26)
                Circle().fill(.white).frame(width: 20, height: 20)
            }
            Circle()
                .fill(BrandColor.accent)
                .frame(width: active ? 14 : 13, height: active ? 14 : 13)
                .overlay(Circle().stroke(.white, lineWidth: active ? 0 : 3))
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

/// A grouped-pins bubble shown when several pros overlap at the current zoom; tap
/// zooms in to split it apart.
private struct ClusterPin: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(BrandFont.body(14, .bold))
            .foregroundStyle(BrandColor.onAccent)
            .frame(minWidth: 30, minHeight: 30)
            .padding(.horizontal, 6)
            .background(BrandColor.accent, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

// Shared decorative box used as the card "image" area — a diagonal sheen over a
// dark base (mirrors the web cards' gradient + texture placeholder).
private struct CardSheen: View {
    var body: some View {
        ZStack {
            BrandColor.bgPrimary.opacity(0.45)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.08), location: 0.0),
                    .init(color: .white.opacity(0.02), location: 0.35),
                    .init(color: .black.opacity(0.24), location: 1.0),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}

private func roundedDollars(_ value: Double?) -> String? {
    guard let value, value > 0 else { return nil }
    return "$\(Int(value.rounded()))"
}

// MARK: - Trending rail card (web TrendingProRail) — 140pt, 7:9 portrait

private struct TrendingCard: View {
    let pro: SearchProItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                Group {
                    if let url = pro.avatarUrl.flatMap({ URL(string: $0) }) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { CardSheen() }
                    } else {
                        CardSheen()
                    }
                }
                .frame(width: 140, height: 180)
                .clipped()

                LinearGradient(colors: [.clear, BrandColor.bgPrimary.opacity(0.7)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)

                HStack(alignment: .top) {
                    if let craft = pro.professionType {
                        badge(craft.uppercased(), bg: BrandColor.bgPrimary.opacity(0.55))
                    }
                    Spacer()
                    if let price = roundedDollars(pro.minPrice) {
                        badge("\(price)+", bg: BrandColor.bgPrimary.opacity(0.7), mono: true)
                    }
                }
                .padding(8)
            }
            .frame(width: 140, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(pro.displayName)
                    .font(BrandFont.body(13, .black)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                Text(subLine)
                    .font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
            }
        }
        .frame(width: 140)
    }

    private var subLine: String {
        var s = pro.locationLabel ?? pro.mapLocation?.cityState ?? "Nearby"
        if let rating = pro.ratingAvg, pro.ratingCount > 0 {
            s += " · ★ \(String(format: "%.1f", rating))"
        }
        return s
    }

    private func badge(_ text: String, bg: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? BrandFont.mono(10) : BrandFont.mono(9)).tracking(0.8)
            .foregroundStyle(BrandColor.textPrimary)
            .padding(.vertical, 4).padding(.horizontal, 7)
            .background(bg, in: mono ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
    }
}

// MARK: - Grid card (web DiscoverGridView) — 2-col, 0.92 aspect + View profile

private struct ProGridCard: View {
    let pro: SearchProItem
    let active: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CardSheen()
                VStack {
                    HStack {
                        if let craft = pro.professionType {
                            Text(craft.uppercased())
                                .font(BrandFont.mono(9)).tracking(1)
                                .foregroundStyle(BrandColor.textPrimary)
                                .padding(.vertical, 4).padding(.horizontal, 7)
                                .background(BrandColor.bgPrimary.opacity(0.8),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text(priceLabel)
                            .font(BrandFont.mono(10)).tracking(0.6)
                            .foregroundStyle(BrandColor.onAccent)
                            .padding(.vertical, 6).padding(.horizontal, 11)
                            .background(BrandColor.accent, in: Capsule())
                    }
                }
                .padding(8)
            }
            .aspectRatio(0.92, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pro.displayName)
                        .font(BrandFont.body(13, .black)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                    Spacer(minLength: 2)
                    if let rating = pro.ratingAvg, pro.ratingCount > 0 {
                        Text("★ \(String(format: "%.1f", rating))")
                            .font(BrandFont.body(11, .black)).foregroundStyle(BrandColor.textSecondary)
                    }
                }
                if let meta = metaLine {
                    Text(meta).font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.textSecondary).lineLimit(1)
                }
            }
            .padding(12)

            Text("View profile")
                .font(BrandFont.mono(10)).tracking(1.4)
                .foregroundStyle(BrandColor.textPrimary)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(BrandColor.bgPrimary.opacity(0.25), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(active ? BrandColor.accent.opacity(0.7) : .white.opacity(0.1), lineWidth: 1)
        )
    }

    private var priceLabel: String {
        roundedDollars(pro.minPrice).map { "FROM \($0)" } ?? "VIEW"
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let loc = pro.locationLabel ?? pro.mapLocation?.cityState { parts.append(loc) }
        if pro.supportsMobile { parts.append("Mobile") }
        if let d = pro.distanceMiles { parts.append("\(String(format: "%.1f", d)) mi") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Looks-first mode plumbing (web D2 LooksBookableGrid)

/// Carries the resolved offering for the booking sheet. Identified by the pro so
/// `.sheet(item:)` re-presents cleanly per tap.
private struct DiscoverBookLaunch: Identifiable {
    let pro: LooksProfessional
    let offering: ProOffering
    var id: String { pro.id }
}

/// A tapped trending-tag chip's web destination, wrapped for `.sheet(item:)`.
private struct DiscoverTagLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A bookable look tile — image, tag + price badges, pro name/service, and a
/// tap-anywhere-to-book gesture ("Tap any look to book the pro who made it").
/// Mirrors web LooksBookableGrid's card.
private struct DiscoverLookCard: View {
    let look: LooksFeedItem
    let resolving: Bool
    let onBook: () -> Void

    private var proName: String { look.professional?.displayName ?? "Pro" }
    private var tag: String? { look.category ?? look.serviceName }
    private var serviceLabel: String? { look.serviceName ?? look.caption }

    var body: some View {
        Button(action: onBook) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let url = (look.thumbUrl ?? look.url).flatMap(URL.init(string:)) {
                            // Focal-aware cover crop (camera C6c) — center the 3:4
                            // tile on the subject; null focal → centered fill.
                            FocalCoverImage(url: url, focal: look.focalPoint) { CardSheen() }
                        } else {
                            CardSheen()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3.0 / 4.0, contentMode: .fill)
                    .clipped()

                    LinearGradient(colors: [.clear, BrandColor.bgPrimary.opacity(0.6)],
                                   startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)

                    if let tag {
                        Text(tag.uppercased())
                            .font(BrandFont.mono(9)).tracking(1)
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.vertical, 4).padding(.horizontal, 7)
                            .background(BrandColor.bgPrimary.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(6)
                    }

                    VStack {
                        HStack {
                            Spacer()
                            if let price = look.priceLabel {
                                Text("FROM \(price)")
                                    .font(BrandFont.mono(9)).tracking(0.6)
                                    .foregroundStyle(BrandColor.textPrimary)
                                    .padding(.vertical, 4).padding(.horizontal, 7)
                                    .background(BrandColor.bgPrimary.opacity(0.7), in: Capsule())
                            }
                        }
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 5) {
                                if resolving {
                                    ProgressView().controlSize(.mini).tint(BrandColor.onAccent)
                                }
                                Text("Book")
                                    .font(BrandFont.mono(10)).tracking(0.6)
                                    .foregroundStyle(BrandColor.onAccent)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 12)
                            .background(BrandColor.accent, in: Capsule())
                        }
                    }
                    .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(proName)
                        .font(BrandFont.body(12, .black)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                    if let serviceLabel {
                        Text(serviceLabel)
                            .font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                    }
                }
                .padding(10)
            }
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Book \(serviceLabel ?? "this look") with \(proName)")
    }
}
