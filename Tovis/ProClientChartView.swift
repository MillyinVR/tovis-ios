// Pro client chart — native port of web `/pro/clients/[id]` (chart view). Reads the
// aggregate (GET /pro/clients/[id]/chart) and renders the client header (+ access
// countdown + stats), the safety strip (alert banner + allergies, severity-colored),
// a do-not-rebook banner, and the 8-tab chart: Notes · Allergies · History ·
// Products · Reviews · Pro feedback · Photos · Technical record (founder-gated). The
// per-tab write forms are native (notes, allergies, alert, do-not-rebook, profile
// context, and the technical record's formula/consent/photo-release).
import SwiftUI
import TovisKit

struct ProClientChartView: View {
    @Environment(SessionModel.self) private var session
    let clientId: String
    let fullName: String

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case allergies = "Allergies"
        case history = "History"
        case products = "Products"
        case reviews = "Reviews"
        case feedback = "Pro feedback"
        case photos = "Photos"
        case technical = "Technical record"
        var id: String { rawValue }
    }

    // Chart ↔ public-profile toggle (increment 3 of the pro private-client-view
    // parity): mirrors the web `/pro/clients/[id]?view=public` branch, which flips
    // the chart to that client's PUBLIC creator profile.
    enum ViewMode: String, CaseIterable, Identifiable {
        case chart = "Chart"
        case publicProfile = "Public profile"
        var id: String { rawValue }
    }
    @State private var viewMode: ViewMode = .chart

    private enum Phase { case loading, loaded(ProClientChart), failed(String) }
    @State private var phase: Phase = .loading
    @State private var tab: Tab = .notes
    @State private var showAddNote = false
    @State private var viewingMedia: FullscreenMedia?

    // Message-the-client entry point (the pro chart has no web counterpart button;
    // web reaches messaging from the booking, but the native chart is a natural
    // place for a general pro→client conversation).
    @State private var messageNav: MessageThreadNav?
    @State private var messageWorking = false

    // Per-tab chart edits (increment 1 of the pro private-client-view parity):
    // alert banner, do-not-rebook flag, profile context (occupation + social
    // handle), and add-allergy — each a native port of a web sibling form.
    enum EditSheet: String, Identifiable {
        case alert, doNotRebook, profileContext, addAllergy
        var id: String { rawValue }
    }
    @State private var editSheet: EditSheet?

    private var loadedChart: ProClientChart? {
        if case let .loaded(chart) = phase { return chart }
        return nil
    }

    private func reloadChart() { Task { await load() } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                viewToggle
                switch viewMode {
                case .chart:
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 70)
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(chart):
                        content(chart)
                    }
                case .publicProfile:
                    ProClientPublicProfileView(clientId: clientId)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle(fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await openMessageThread() }
                } label: {
                    if messageWorking {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                }
                .tint(BrandColor.accent)
                .disabled(messageWorking)
                .accessibilityLabel("Message client")
            }
        }
        .navigationDestination(item: $messageNav) { nav in
            ThreadView(thread: nav.thread)
        }
        .sheet(isPresented: $showAddNote) {
            ProAddNoteSheet(clientId: clientId, onSaved: reloadChart)
        }
        .sheet(item: $editSheet) { sheet in
            switch sheet {
            case .alert:
                ProEditAlertBannerSheet(
                    clientId: clientId, current: loadedChart?.alertBanner, onSaved: reloadChart
                )
            case .doNotRebook:
                ProDoNotRebookSheet(
                    clientId: clientId,
                    active: loadedChart?.doNotRebook != nil,
                    currentReason: loadedChart?.doNotRebook?.reason,
                    onSaved: reloadChart
                )
            case .profileContext:
                ProEditProfileContextSheet(
                    clientId: clientId,
                    occupation: loadedChart?.header.occupation ?? "",
                    socialHandle: loadedChart?.header.socialHandle ?? "",
                    onSaved: reloadChart
                )
            case .addAllergy:
                ProAddAllergySheet(clientId: clientId, onSaved: reloadChart)
            }
        }
        .tint(BrandColor.accent)
    }

    /// Resolve-or-create the general pro↔client thread and push the conversation.
    /// Needs the pro's OWN professionalId (the PRO_PROFILE resolve requires
    /// contextId == the viewer's profile id), fetched via myProfile(). Best-effort:
    /// on failure the pro stays on the chart.
    private func openMessageThread() async {
        guard !messageWorking else { return }
        messageWorking = true
        defer { messageWorking = false }
        guard let myId = try? await session.client.proProfile.myProfile().id else { return }
        if let thread = try? await session.client.messages.openClientThread(
            professionalId: myId,
            clientId: clientId
        ) {
            messageNav = MessageThreadNav(thread: thread)
        }
    }

    private var viewToggle: some View {
        Picker("View", selection: $viewMode) {
            ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func content(_ chart: ProClientChart) -> some View {
        headerCard(chart.header)
        safetyStrip(chart)
        doNotRebookSection(chart)
        if let intel = chart.relationshipIntelligence {
            relationshipIntelligenceSection(intel)
        }
        tabBar(technicalEnabled: chart.technicalEnabled)
        tabContent(chart)
    }

    // MARK: - Header

    private func headerCard(_ h: ProChartHeader) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    BrandAvatar(name: h.fullName, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h.fullName).font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        if let occ = h.occupation { Text(occ).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted) }
                        if let handle = h.socialHandle { Text(handle).font(BrandFont.mono(11)).foregroundStyle(BrandColor.accent) }
                    }
                    Spacer()
                }
                if let until = h.accessUntil {
                    Text("Access · closes \(Wire.dateOnly(until))")
                        .font(BrandFont.mono(9)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                }
                HStack(spacing: 10) {
                    statTile("\(h.bookingCount)", "Bookings")
                    statTile("\(h.reviewCount)", "Reviews")
                    if let pref = h.preferredContactMethod { statTile(pref.capitalized, "Prefers") }
                }
                Button { editSheet = .profileContext } label: {
                    Label(
                        (h.occupation?.isEmpty == false || h.socialHandle?.isEmpty == false)
                            ? "Edit context" : "Add context",
                        systemImage: "pencil"
                    )
                    .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.accent)
                }
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
            Text(label.uppercased()).font(BrandFont.mono(8)).tracking(0.6).foregroundStyle(BrandColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(BrandColor.bgPrimary).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Safety strip + do-not-rebook

    private func safetyStrip(_ chart: ProClientChart) -> some View {
        let hasAlert = (chart.alertBanner?.isEmpty == false)
        let hasAllergies = !chart.allergies.isEmpty
        return BrandSurface(tint: (hasAlert || hasAllergies) ? BrandColor.ember.opacity(0.10) : BrandColor.bgSurface) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    if let alert = chart.alertBanner, !alert.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BrandColor.ember)
                            Text(alert).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        }
                    } else {
                        Text("No alert banner set.").font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer(minLength: 8)
                    Button { editSheet = .alert } label: {
                        Text(hasAlert ? "Edit" : "Add").font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.accent)
                    }
                }
                if hasAllergies {
                    FlexChips(chart.allergies.map { "\($0.label) · \($0.severity)" }, tone: BrandColor.ember)
                } else {
                    Text("No allergies on file.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func doNotRebookSection(_ chart: ProClientChart) -> some View {
        let dnr = chart.doNotRebook
        BrandSurface(tint: dnr != nil ? BrandColor.ember.opacity(0.14) : BrandColor.bgSurface) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if dnr != nil {
                        Image(systemName: "hand.raised.fill").foregroundStyle(BrandColor.ember)
                        Text("Do not rebook").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    }
                    Spacer(minLength: 8)
                    Button { editSheet = .doNotRebook } label: {
                        Text(dnr != nil ? "Edit" : "Flag do not rebook")
                            .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.accent)
                    }
                }
                if let reason = dnr?.reason, !reason.isEmpty {
                    Text(reason).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Relationship intelligence

    // Mirrors web's `RelationshipIntelligenceCard` — smart-flag chips above a 2-col
    // grid of stat tiles, plus a contact/source footnote. Every string is formatted
    // server-side (`formatRelationshipIntelligence`); this view only lays them out.
    private func relationshipIntelligenceSection(
        _ intel: ProChartRelationshipIntelligence
    ) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]
        let hasContact = intel.preferredContactMethod?.isEmpty == false
        let hasSource = intel.referralSource?.isEmpty == false
        return BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Relationship intelligence")
                    .font(BrandFont.mono(9)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                if !intel.flags.isEmpty {
                    smartFlagChips(intel.flags)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    intelTile("Lifetime value (you)", intel.lifetimeValue)
                    intelTile("Visits with you", intel.visits)
                    intelTile("Cadence", intel.cadence)
                    intelTile("Lead time", intel.leadTime)
                    intelTile("Pattern", intel.pattern)
                    intelTile("Rebooking", intel.rebooking)
                }
                if hasContact || hasSource {
                    HStack(spacing: 14) {
                        if let contact = intel.preferredContactMethod, hasContact {
                            (Text("Prefers ").foregroundStyle(BrandColor.textSecondary)
                                + Text(contact).foregroundStyle(BrandColor.textPrimary).fontWeight(.bold))
                                .font(BrandFont.body(11))
                        }
                        if let source = intel.referralSource, hasSource {
                            (Text("Source: ").foregroundStyle(BrandColor.textSecondary)
                                + Text(source).foregroundStyle(BrandColor.textPrimary).fontWeight(.bold))
                                .font(BrandFont.body(11))
                        }
                    }
                }
            }
        }
    }

    private func intelTile(
        _ label: String,
        _ tile: ProChartRelationshipIntelligence.Tile
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(BrandFont.mono(8)).tracking(0.6).foregroundStyle(BrandColor.textMuted)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(tile.value)
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let hint = tile.hint, !hint.isEmpty {
                Text(hint)
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func smartFlagChips(
        _ flags: [ProChartRelationshipIntelligence.Flag]
    ) -> some View {
        let columns = [GridItem(.adaptive(minimum: 120), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(flags) { flag in
                let tone = flagTone(flag.tone)
                Text(flag.label)
                    .font(BrandFont.mono(10)).foregroundStyle(tone)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(tone.opacity(0.12)).clipShape(Capsule())
            }
        }
    }

    /// Maps the wire tone string to a brand tone color (web's `Badge` tones).
    private func flagTone(_ tone: String) -> Color {
        switch tone {
        case "warn": return BrandColor.amber
        case "success": return BrandColor.emerald
        default: return BrandColor.accent  // "info"
        }
    }

    // MARK: - Tabs

    private func tabBar(technicalEnabled: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(Tab.allCases.filter { $0 != .technical || technicalEnabled }) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 5) {
                            Text(t.rawValue)
                                .font(BrandFont.body(13, tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? BrandColor.textPrimary : BrandColor.textMuted)
                            Rectangle().fill(tab == t ? BrandColor.accent : Color.clear).frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ chart: ProClientChart) -> some View {
        switch tab {
        case .notes: notesTab(chart)
        case .allergies: allergiesTab(chart)
        case .history: historyTab(chart)
        case .products: productsTab(chart)
        case .reviews: reviewsTab(chart)
        case .feedback: feedbackTab(chart)
        case .photos: photosTab(chart)
        case .technical: technicalTab()
        }
    }

    private func notesTab(_ chart: ProClientChart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showAddNote = true } label: {
                Label("Add a note", systemImage: "square.and.pencil")
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
            if chart.noteGroups.isEmpty {
                emptyTab("No notes yet.")
            } else {
                ForEach(chart.noteGroups) { group in
                    BrandSection(title: group.label) {
                        VStack(spacing: 10) {
                            ForEach(group.notes) { note in
                                BrandSurface {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let title = note.title, !title.isEmpty {
                                            Text(title).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                        }
                                        Text(note.body).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                                        Text(Wire.dateOnly(note.createdAt)).font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func allergiesTab(_ chart: ProClientChart) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { editSheet = .addAllergy } label: {
                Label("Add allergy", systemImage: "plus.circle")
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
            if chart.allergies.isEmpty {
                emptyTab("No allergies recorded yet.")
            } else {
                ForEach(chart.allergies) { a in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(a.label).font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                Spacer()
                                BrandPill(text: a.severity, tint: severityTone(a.severity))
                            }
                            if let desc = a.description, !desc.isEmpty {
                                Text(desc).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                            }
                            Text("Recorded by \(a.recordedBy)").font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func historyTab(_ chart: ProClientChart) -> some View {
        VStack(spacing: 10) {
            if chart.history.isEmpty {
                emptyTab("No bookings yet.")
            } else {
                ForEach(chart.history) { b in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(b.serviceName ?? "Booking").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                Spacer()
                                if let total = b.total { Text(Wire.money(total) ?? total).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textSecondary) }
                            }
                            HStack(spacing: 6) {
                                BrandPill(text: b.status.capitalized, tint: statusTone(b.status))
                                if !b.isMine { Text("with \(b.proName)").font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted) }
                            }
                            Text(Wire.dateTime(b.scheduledFor, timeZone: b.timeZone)).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                            if let notes = b.aftercareNotes, !notes.isEmpty {
                                Text(notes).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary).lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func productsTab(_ chart: ProClientChart) -> some View {
        VStack(spacing: 10) {
            if chart.products.isEmpty {
                emptyTab("No products recommended yet.")
            } else {
                ForEach(chart.products) { p in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.brand.map { "\($0) · \(p.name)" } ?? p.name)
                                .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                            if let note = p.note, !note.isEmpty {
                                Text(note).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func reviewsTab(_ chart: ProClientChart) -> some View {
        VStack(spacing: 10) {
            if chart.reviewsLeft.isEmpty {
                emptyTab("This client hasn't left any reviews yet.")
            } else {
                ForEach(chart.reviewsLeft) { r in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                ForEach(0..<5, id: \.self) { i in
                                    Image(systemName: i < r.rating ? "star.fill" : "star").font(.system(size: 11)).foregroundStyle(BrandColor.gold)
                                }
                                Spacer()
                                Text("for \(r.proName)").font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                            }
                            if let h = r.headline, !h.isEmpty { Text(h).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary) }
                            if let b = r.body, !b.isEmpty { Text(b).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func feedbackTab(_ chart: ProClientChart) -> some View {
        VStack(spacing: 10) {
            if chart.proFeedback.isEmpty {
                emptyTab("No pro feedback yet.")
            } else {
                ForEach(chart.proFeedback) { f in
                    BrandSurface {
                        VStack(alignment: .leading, spacing: 4) {
                            if let title = f.title, !title.isEmpty {
                                Text(title).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                            }
                            Text(f.body).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                            Text("— \(f.proName)").font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func photosTab(_ chart: ProClientChart) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if chart.photos.isEmpty {
                emptyTab("No photos yet.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(chart.photos) { photo in
                        Button {
                            viewingMedia = FullscreenMedia.remote(id: photo.id, urlString: photo.imageUrl, isVideo: false)
                        } label: {
                            ZStack(alignment: .topLeading) {
                                BrandColor.bgSecondary
                                if let url = URL(string: photo.imageUrl) {
                                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { ProgressView().tint(BrandColor.accent) }
                                }
                                Text(photo.phase).font(BrandFont.mono(8)).tracking(0.6).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.5)).clipShape(Capsule())
                                    .padding(6)
                            }
                            .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .mediaFullscreenCover($viewingMedia)
            }
        }
    }

    private func technicalTab() -> some View {
        // Founder-gated formula history + consent/patch-test records + photo-release,
        // loaded lazily from GET /pro/clients/{id}/technical so the server-decrypted
        // encrypted free text only travels when this tab is open (mirrors the web).
        ProClientTechnicalView(clientId: clientId)
    }

    // MARK: - Bits

    private func severityTone(_ severity: String) -> Color {
        switch severity.uppercased() {
        case "HIGH", "SEVERE": return BrandColor.ember
        case "MODERATE", "MEDIUM": return BrandColor.gold
        default: return BrandColor.emerald
        }
    }

    private func emptyTab(_ message: String) -> some View {
        Text(message).font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 30)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28).background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func load() async {
        do {
            let chart = try await session.client.proClients.chart(clientId: clientId)
            phase = .loaded(chart)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this client’s chart.")
        }
    }
}

/// A simple wrapping chip row.
private struct FlexChips: View {
    let items: [String]
    let tone: Color
    init(_ items: [String], tone: Color) { self.items = items; self.tone = tone }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 90), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(BrandFont.mono(10)).foregroundStyle(tone)
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(tone.opacity(0.12)).clipShape(Capsule())
            }
        }
    }
}
