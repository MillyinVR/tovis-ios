// The pro's library — ONE set of photos whose top zone IS the public portfolio.
// It renders INSIDE the Profile tab, under the profile header, the way a grid
// does in every app a pro already uses.
//
// 🔴 It used to be a screen of its own, pushed from a "Portfolio" row in the
// Business list, with a second row ("My media") leading to a second grid of the
// same photos whose only unique power was the asset editor. Three doors into one
// room, and the profile's own portfolio tab was a read-only mirror that decided
// nothing. Now: the tab IS this, and the editor lives on the tile.
//
// Backed by `GET /api/v1/pro/portfolio`, which shares its builder with the web
// page, so the two can never disagree about what is public or what a photo is
// waiting on. The model it renders:
//
//   - publishing is ONE act, with its destinations written down before it lands;
//   - public-vs-private is carried by WHICH ZONE a tile sits in, not by a badge,
//     so a tile's chip is only ever something the pro DECIDED (Signature/Cover);
//   - a blocked photo names a PERSON, not a rule, and offers the only real
//     action — re-issuing the aftercare, which is where media-use is ticked.
import SwiftUI
import TovisKit

struct ProLibrarySection: View {
    @Environment(SessionModel.self) private var session

    /// Bumped by the host when it wants a reload — the Profile tab's own
    /// pull-to-refresh, which owns the scroll view this renders into.
    var reloadTick: Int = 0

    private enum Phase {
        case loading
        case loaded(ProLibraryPageModel)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var activeFilter: String = "ALL"
    @State private var openTile: ProLibraryTile?
    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                    .padding(.vertical, 60)
            case let .failed(message):
                errorState(message)
            case let .loaded(model):
                content(model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { if case .loading = phase { await load() } }
        .onChange(of: reloadTick) { Task { await load() } }
        .sheet(item: $openTile) { tile in
            ProPortfolioSheet(
                tile: tile,
                serviceOptions: serviceOptions,
                onChanged: { Task { await load() } }
            )
        }
        .sheet(isPresented: $composing) {
            ProNewMediaPostView { Task { await load() } }
        }
    }

    /// Nil only against a server that predates the field — the picker then has
    /// nothing to offer and the editor's save gate keeps a pro from clearing
    /// their tags by accident.
    private var serviceOptions: [ProLibraryServiceOption] {
        guard case let .loaded(model) = phase else { return [] }
        return model.serviceOptions ?? []
    }

    @ViewBuilder
    private func content(_ model: ProLibraryPageModel) -> some View {
        Text(model.subtitle)
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textSecondary)
            .padding(.bottom, 14)

        if !model.isBlank {
            filterRow(model.filters)
                .padding(.bottom, 4)
        }

        if let lead = model.lead {
            leadCard(lead)
        }

        if !model.publicTiles.isEmpty {
            zoneHeader(
                title: "Public · \(model.counts.publicCount)",
                tint: BrandColor.accent,
                note: nil,
                blurb: "Exactly what a client sees on your profile, and what’s live in the Looks feed."
            )
            grid(model.publicTiles)
        }

        ForEach(model.groups) { group in
            zoneHeader(
                title: "\(group.title) · \(group.count)",
                tint: BrandColor.textSecondary,
                note: group.note,
                blurb: group.blurb
            )
            grid(group.tiles)

            if group.remaining > 0 {
                // Narrows the page to THIS zone, which is what lets the group
                // render uncapped — every other view re-caps it, so a link to a
                // broader filter would land on the same tiles and offer the same
                // "Show N more" again.
                Button {
                    Task { await load(filter: group.zone.rawValue) }
                } label: {
                    Text("Show \(group.remaining) more")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(BrandColor.textPrimary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }

        if model.isBlank {
            blankState
        }
    }

    // MARK: - Filters

    private func filterRow(_ filters: [ProLibraryFilter]) -> some View {
        // WRAPS rather than scrolls: on web the same row overflowed a phone and
        // hid the "Waiting" chip entirely — and that is the one chip revealing
        // the consent-held state, which is the MAJORITY state in production.
        FlowLayout(spacing: 8) {
            ForEach(filters) { filter in
                Button {
                    Task { await load(filter: filter.key) }
                } label: {
                    Text(filter.count.map { "\(filter.label) \($0)" } ?? filter.label)
                        .font(BrandFont.mono(10))
                        .foregroundStyle(filter.active ? BrandColor.accent : BrandColor.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            (filter.active ? BrandColor.accent : BrandColor.textPrimary).opacity(filter.active ? 0.10 : 0.05)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter.active ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Zones

    private func zoneHeader(title: String, tint: Color, note: String?, blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(BrandFont.mono(10))
                    .foregroundStyle(tint)
                Spacer()
                if let note {
                    Text(note.uppercased())
                        .font(BrandFont.mono(9))
                        .foregroundStyle(BrandColor.gold)
                }
            }
            Text(blurb)
                .font(BrandFont.body(12.5))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private func grid(_ tiles: [ProLibraryTile]) -> some View {
        LazyVGrid(columns: MediaGridLayout.columns(count: 3, spacing: 9), spacing: 9) {
            ForEach(tiles) { tile in
                Button { openTile = tile } label: { self.tile(tile) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibleName(tile))
            }
        }
    }

    private func tile(_ tile: ProLibraryTile) -> some View {
        // Cells are sized by the COLUMN, never by the upload — `.scaledToFill()`
        // inflates layout width and leaves a ragged, overlapping grid the moment
        // a landscape shot sits beside a portrait one.
        MediaGridCell(aspectRatio: 3.0 / 4.0, cornerRadius: 14) {
            if let url = URL(string: tile.src) {
                // The pro's own library is the first place they look after a
                // re-frame, so it honours the same rect every public surface does.
                MediaGridImage(url: url, display: tile.displayCrop)
                    // A held photo reads as not-yet-yours at a glance, before any copy.
                    .saturation(tile.isHeld ? 0 : 1)
                    .opacity(tile.isHeld ? 0.55 : 1)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
        .overlay(alignment: .topLeading) {
            if let mark = tile.mark {
                Text(mark.label.uppercased())
                    .font(BrandFont.mono(8))
                    .foregroundStyle(BrandColor.gold)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    // Tint + border, like web's chip: a bare 15% tint over a
                    // light photo leaves gold-on-cream with almost no edge.
                    .background(BrandColor.gold.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(BrandColor.gold.opacity(0.35), lineWidth: 1)
                    )
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tile.isVideo {
                // A glyph, not a duration: MediaAsset stores no duration at all.
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(5)
                    .background(BrandColor.bgPrimary.opacity(0.65))
                    .clipShape(Circle())
                    .padding(6)
            }
        }
        .overlay(alignment: .center) {
            // 🔴 A pair is INDICATED, never rendered as a live comparison view: a
            // recognised gesture wins the scroll, so an interactive slider would
            // eat the tap this tile exists to receive.
            if tile.before != nil {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BrandColor.bgPrimary)
                    .frame(width: 22, height: 22)
                    .background(BrandColor.textPrimary)
                    .clipShape(Circle())
            }
        }
        .overlay(alignment: .bottom) {
            if let hold = tile.hold {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                    Text("Waiting on \(hold.clientFirstName)".uppercased())
                        .font(BrandFont.mono(8))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(BrandColor.gold)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(tileScrim)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !tile.isHeld && !tile.isPublic {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(width: 26, height: 26)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if tile.isPublic, let engagement = tile.engagement {
                HStack(spacing: 8) {
                    stat("eye", engagement.views)
                    stat("heart", engagement.likes)
                    if engagement.booked > 0 {
                        stat("calendar", engagement.booked, tint: BrandColor.gold)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(tileScrim)
            }
        }
        // 🔴 Clips the OVERLAYS, not just the image. `MediaGridCell` clips its own
        // content, but an `.overlay` applied to the result is not — so the scrim
        // drew a square-cornered band across the tile's rounded bottom. Invisible
        // in light mode (scrim ≈ page colour) and obvious in dark.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 🔴 Not decoration — legibility. These overlays sit directly on a
    /// PHOTOGRAPH, so `textPrimary` is near-black in light mode and the views /
    /// likes counts rendered black-on-dark and vanished entirely; only the gold
    /// "booked" stat survived, which read as "this tile has one number". Web has
    /// carried the same scrim from the start (`from-bgPrimary/88 to-transparent`)
    /// — it was the one piece of the tile this port dropped.
    private var tileScrim: some View {
        LinearGradient(
            colors: [BrandColor.bgPrimary.opacity(0.88), BrandColor.bgPrimary.opacity(0)],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func stat(_ symbol: String, _ value: Int, tint: Color = BrandColor.textPrimary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text("\(value)").font(BrandFont.mono(8.5))
        }
        .foregroundStyle(tint)
    }

    /// 🔴 Every visual signal on a tile is positional or graphical — the zone
    /// carries public-vs-private, a dimmed photo carries the hold, the counts
    /// ride an overlay — so the whole state has to reach a screen reader.
    private func accessibleName(_ tile: ProLibraryTile) -> String {
        var parts = [tile.caption ?? "Untitled photo"]
        if let mark = tile.mark { parts.append(mark.label) }
        if tile.isVideo { parts.append("Video") }

        if let hold = tile.hold {
            parts.append("Waiting on \(hold.clientFirstName) before it can be published")
        } else if tile.isPublic {
            parts.append("Public")
            if let e = tile.engagement { parts.append("\(e.views) views, \(e.likes) likes") }
        } else {
            parts.append("Only you. Tap to publish")
        }

        return parts.joined(separator: ". ")
    }

    // MARK: - Lead / empty / error

    private func leadCard(_ lead: ProLibraryLead) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOTHING PUBLIC YET")
                .font(BrandFont.mono(9))
                .foregroundStyle(BrandColor.accent)
            Text(lead.title)
                .font(BrandFont.display(17, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(lead.body)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)

            HStack(spacing: 9) {
                ForEach(lead.shots) { shot in
                    Button { openTile = shot } label: {
                        MediaGridCell(aspectRatio: 3.0 / 4.0, cornerRadius: 11) {
                            if let url = URL(string: shot.src) {
                                MediaGridImage(url: url, display: shot.displayCrop)
                            }
                        }
                        .frame(width: 66)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Publish \(shot.caption ?? "this photo")")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            Button {
                if let first = lead.shots.first { openTile = first }
            } label: {
                Text(lead.ctaLabel)
                    .font(BrandFont.body(14.5, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(BrandColor.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 12)
    }

    private var blankState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 24))
                .foregroundStyle(BrandColor.onAccent)
                .frame(width: 54, height: 54)
                .background(BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

            Text("Your work lives here")
                .font(BrandFont.display(20, .bold))
                .foregroundStyle(BrandColor.textPrimary)

            Text("Upload a few photos of work you’re proud of, and they’ll be one tap from public. Everything you shoot at the chair lands here too, private until you and your client say otherwise.")
                .font(BrandFont.body(13.5))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)

            Button { composing = true } label: {
                Text("Upload your first Look")
                    .font(BrandFont.body(14.5, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Or finish a booking — session photos arrive on their own.")
                .font(BrandFont.body(12.5))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 12)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    // MARK: - Load

    private func load(filter: String? = nil) async {
        let next = filter ?? activeFilter
        do {
            let model = try await session.client.proProfile.portfolio(
                filter: next == "ALL" ? nil : next
            )
            activeFilter = next
            phase = .loaded(model)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your portfolio.")
        }
    }
}
