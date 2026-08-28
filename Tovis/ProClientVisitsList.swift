// Tovis/ProClientVisitsList.swift
//
// The chart's unified per-visit card — the native twin of the web chart's
// `app/pro/clients/[id]/VisitHistoryList.tsx`, field for field.
//
// This was TWO tabs on both surfaces — "History" (a row per booking) and
// "Photos" (a grid per booking) — which were two groupings of the same visits,
// so a pro comparing a formula against the result had to hold one tab in their
// head while reading the other. `history[].photos` is the shape that merged
// them, grouped SERVER-side so "which visit is this frame from" has exactly one
// answer shared by web and native.
//
// Presentational only: the chart screen owns the fetch and hands the visits in,
// so this file cannot grow a read of its own.
import SwiftUI
import TovisKit

struct ProClientVisitsList: View {
    let visits: [ProChartBooking]
    /// Set when a frame is tapped; the chart screen owns the fullscreen cover.
    @Binding var viewingMedia: FullscreenMedia?

    var body: some View {
        VStack(spacing: 10) {
            if visits.isEmpty {
                Text("No visits yet.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .padding(.vertical, 30)
            } else {
                ForEach(visits) { visit in
                    BrandSurface { card(visit) }
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ b: ProChartBooking) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(b.serviceName ?? "Booking")
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Spacer()
                // "90 min · $180" — the same pair, in the same order, that the
                // web card prints. Either half alone when the other is absent.
                Text(priceLine(b))
                    .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textSecondary)
            }

            HStack(spacing: 6) {
                BrandPill(text: BookingStatusPresentation.label(b.status), tint: statusTone(b.status))

                // The NR/NNR/RR/RNR mark (K6), on the viewing pro's OWN rows
                // only — the mark answers "did this client request ME", so on
                // another pro's booking it would misread. The server already
                // sends nil there; the `isMine` check is the belt to that
                // braces, so a future server that sent one anyway still
                // couldn't render it here.
                if b.isMine, let relationship = b.relationshipBadge?.display, relationship.significant {
                    BrandPill(text: relationship.label, tint: wireBadgeTone(relationship.tone))
                        .accessibilityLabel(relationship.description)
                }

                // Why another pro's frames are visible at all: the CLIENT
                // promoted them with a public review. Web says the same thing on
                // the same condition.
                if !b.isMine, !b.photos.isEmpty {
                    BrandPill(text: "Client-shared", tint: BrandColor.iris)
                }
            }

            // Category + who worked the visit, and the "Me" mark on the viewing
            // pro's own rows — web's second line, which native was missing the
            // category and the mark from entirely.
            HStack(spacing: 6) {
                Text(proLine(b))
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                if b.isMine { BrandPill(text: "Me", tint: BrandColor.textMuted) }
            }

            Text(Wire.dateTime(b.scheduledFor, timeZone: b.timeZone))
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

            if let notes = b.aftercareNotes, !notes.isEmpty {
                Text(notes)
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                    .lineLimit(3)
            }

            // Only when the visit HAS frames. An empty grid or a "no photos"
            // placeholder on every photo-less visit is noise on a list where
            // most rows have none — web makes the same call.
            if !b.photos.isEmpty {
                photoGrid(b.photos)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "90 min · $180" — the web card's `{duration} • ${total}` line.
    ///
    /// Either half alone when the other is missing, and empty when both are.
    /// Web prints a literal em dash for a zero duration; native drops the half
    /// instead, because an orphan "— · $180" reads as a missing value rather
    /// than as a visit that was never given a length.
    private func priceLine(_ b: ProChartBooking) -> String {
        let duration = b.durationMinutes.flatMap { $0 > 0 ? "\($0) min" : nil }
        let money = b.total.map { Wire.money($0) ?? $0 }
        return [duration, money].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Color · Ana R." — category then the pro who worked it, matching the web
    /// card's `{category} • Pro: {name}` line. The category half is dropped when
    /// the service has none rather than printing a stray separator.
    private func proLine(_ b: ProChartBooking) -> String {
        [b.categoryName, b.proName].compactMap { $0 }.joined(separator: " · ")
    }

    /// A visit's frames, inline on its card. The ONLY photo grid in the chart —
    /// the separate Photos tab that held a second copy is gone.
    private func photoGrid(_ photos: [ProChartPhoto]) -> some View {
        // Three EQUAL columns of SQUARE tiles — web's `grid-cols-3` +
        // `aspect-square`. `.adaptive(minimum:)` looked right in code and
        // rendered wide rectangles that left half the row empty: it sizes
        // columns to fill, and a fixed `frame(height:)` cannot square them back.
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(photos) { photo in
                Button {
                    viewingMedia = FullscreenMedia.remote(id: photo.id, urlString: photo.imageUrl, isVideo: false)
                } label: {
                    tile(photo)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func tile(_ photo: ProChartPhoto) -> some View {
        ZStack(alignment: .topLeading) {
            BrandColor.bgSecondary
            if let url = URL(string: photo.imageUrl) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                    ProgressView().tint(BrandColor.accent)
                }
            }
            // The phase chip sits ON a photograph, so it carries its own OPAQUE
            // tokened backing rather than a tint — the same call web's neutral
            // Badge makes (`bg-bgSecondary`, `text-textSecondary`). Both tokens
            // flip with the mode, so this reads in light and dark and stays
            // white-label; the .white-on-.black chip it replaces did neither.
            Text(photo.phase)
                .font(BrandFont.mono(8)).tracking(0.6)
                .foregroundStyle(BrandColor.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(BrandColor.bgSecondary)
                .clipShape(Capsule())
                // Web's neutral Badge carries `border-textPrimary/12` as well as
                // its fill, and dropping it here was not cosmetic: the tile's
                // own placeholder is ALSO bgSecondary, so until the photo loads
                // the capsule had no edge and the label read as bare text.
                .overlay(Capsule().stroke(BrandColor.textPrimary.opacity(0.12), lineWidth: 1))
                .padding(6)
        }
        .aspectRatio(1, contentMode: .fill)
        // Clip AFTER the overlays, or the chip's backing draws outside the
        // tile's rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
