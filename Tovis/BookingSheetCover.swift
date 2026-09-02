// The top of the booking sheet, to `BookingSheetFrame` — the native twin of
// `app/(main)/booking/AvailabilityDrawer/components/SheetCover.tsx`: the look you
// are booking as a photo cover, then the service line, then the reassurance chips.
//
// Every chip is omitted when its signal is unknown rather than rendered as a zero
// or a placeholder (see `lib/booking/trustSignals`), which means the row can
// legitimately come out with only the cancellation chip in it — the honest result
// for a brand-new pro.
import SwiftUI
import TovisKit

struct BookingSheetCover: View {
    let cover: AvailabilityCover?
    let trust: AvailabilityTrust?
    let serviceName: String
    let proName: String
    let proAvatarUrl: String?
    /// The offering's formatted lowest price, WITHOUT the word — the wire sends
    /// a bare "$250" and the caller supplies "From". `StartingPrice` does that.
    let priceFromLabel: String?
    let durationMinutes: Int
    let onClose: () -> Void

    private var coverURL: URL? {
        guard let raw = cover?.imageUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// The stored original behind the render — see `FallbackAsyncImage`.
    private var coverFallbackURL: URL? {
        guard let raw = cover?.fallbackImageUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var title: String {
        if let name = cover?.lookName, !name.isEmpty { return name }
        return serviceName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverWell
            summary
        }
    }

    // MARK: - Cover

    /// The look, so the sheet is visibly about the thing you tapped. Without one
    /// (a booking started from a pro's profile) this collapses to a plain bar
    /// carrying the close button, rather than an empty photo well.
    private var coverWell: some View {
        ZStack(alignment: .topTrailing) {
            if let coverURL {
                Color.clear
                    .frame(height: 132)
                    .frame(maxWidth: .infinity)
                    .background(BrandColor.bgSecondary)
                    .overlay {
                        FallbackAsyncImage(url: coverURL, fallbackURL: coverFallbackURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        // Fade INTO the sheet body rather than to a fixed colour,
                        // which would band in one of the two modes. Same stops as
                        // the web twin's CSS gradient, so the two covers fade
                        // over the same distance.
                        LinearGradient(
                            stops: [
                                .init(color: BrandColor.bgPrimary, location: 0.03),
                                .init(color: BrandColor.bgPrimary.opacity(0.05), location: 0.58),
                                .init(color: Color.black.opacity(0.45), location: 1),
                            ],
                            startPoint: .bottom, endPoint: .top
                        )
                    }
                    .overlay(alignment: .bottomLeading) {
                        // ⚠️ `textPrimary`, not white. This sits at the very
                        // bottom of the scrim, where the gradient is ~90%
                        // `bgPrimary` — on the SHEET's surface, not on the photo.
                        // White there is white-on-near-white in light mode.
                        HStack(spacing: 6) {
                            Text("◆")
                                .font(BrandFont.body(11))
                                .foregroundStyle(BrandColor.accent)
                            Text("BOOKING THIS LOOK")
                                .font(BrandFont.mono(10)).tracking(1.3)
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                        .padding(.leading, 20).padding(.bottom, 8)
                    }
            } else {
                Color.clear.frame(height: 48)
            }

            closeButton
                .padding(.top, 12).padding(.trailing, 12)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(coverURL == nil ? BrandColor.textSecondary : .white)
                .frame(width: 32, height: 32)
                .background(
                    coverURL == nil
                        ? AnyShapeStyle(BrandColor.bgSurface)
                        : AnyShapeStyle(Color.black.opacity(0.45)),
                    in: Circle()
                )
                .overlay(
                    Circle().stroke(
                        coverURL == nil ? BrandColor.textMuted.opacity(0.18) : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    // MARK: - Summary + trust

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(BrandFont.display(19, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 7) {
                        BrandAvatar(name: proName, avatarUrl: proAvatarUrl, size: 20)
                        Text("with \(proName)")
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textSecondary)
                            .lineLimit(1)
                        if let rating = BookingSheetPresentation.ratingLabel(trust?.rating) {
                            Text(rating)
                                .font(BrandFont.body(12, .semibold))
                                .foregroundStyle(BrandColor.gold)
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    // ⚠️ Prices are STARTING prices — never a bare figure.
                    if let price = StartingPrice.label(priceFromLabel) {
                        Text(price)
                            .font(BrandFont.display(16, .bold))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                    if durationMinutes > 0 {
                        Text("\(durationMinutes) MIN")
                            .font(BrandFont.mono(10)).tracking(0.6)
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
            }

            trustRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var trustRow: some View {
        let chips = BookingSheetPresentation.trustChips(trust)
        if !chips.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(chips) { chip in
                    Text(chip.text)
                        .font(BrandFont.body(10.5, .medium))
                        .foregroundStyle(chip.isAccent ? BrandColor.accent : BrandColor.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(
                            (chip.isAccent ? BrandColor.accent : BrandColor.textMuted).opacity(0.10),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                (chip.isAccent ? BrandColor.accent : BrandColor.textMuted).opacity(0.3),
                                lineWidth: 1
                            )
                        )
                }
            }
        }
    }
}
