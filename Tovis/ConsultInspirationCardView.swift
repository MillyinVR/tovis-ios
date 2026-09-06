// P5d — an inspiration CARD on the device: a crop of the client's own
// reference, a plain word for what is in the crop, and a question about it.
//
// The native twin of tovis-app's `InspirationCardMessage`
// (app/client/(gated)/consult/[id]/ClientConsultFlow.tsx).
//
// 🔴 Nothing here is composed on the device. The crop rectangle, the plain
// word, the question and its options all arrive on the wire already resolved —
// the server built them from its reading of the photograph and the brand's copy
// table. What goes back is the question key and the option enum, through the
// answer route the wizard already used.
//
// 🔴 The order on screen is crop → word → question, and it is the Stage 2 rule:
// no jargon before its picture. She is looking at the silvery part of her own
// reference before anything calls it "ash", and the word is offered ("some
// people call it") rather than assumed.
import SwiftUI
import TovisKit
import UIKit

/// One decoded copy of the reference, shared by every card on the thread.
///
/// 🔴 A cache, not a convenience. A hair-colour consult renders up to eleven
/// cards, and every one of them crops the SAME photograph; without this each
/// card view would fetch and decode it again on appear. Keyed by the signed
/// URL, so a renewed URL is a new entry and a swapped reference cannot show the
/// old picture.
actor ConsultInspirationReferenceStore {
    static let shared = ConsultInspirationReferenceStore()

    private var cached: (url: URL, image: UIImage)?
    private var inFlight: (url: URL, task: Task<UIImage?, Never>)?

    func image(for url: URL) async -> UIImage? {
        if let cached, cached.url == url { return cached.image }
        if let inFlight, inFlight.url == url { return await inFlight.task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else {
                return nil
            }
            return await ImageDownsample.thumbnail(
                from: data, maxPixel: ImageDownsample.screenMaxPixel
            )
        }
        inFlight = (url, task)
        let image = await task.value
        inFlight = nil
        if let image { cached = (url, image) }
        return image
    }
}

/// The reference, cropped to one normalized region of it.
///
/// The crop is done from the decoded image rather than by asking the server for
/// a cut version: the reference is short-lived signed media, and cropping it
/// server-side would be a second render path and a second thing to purge.
///
/// A nil region shows the whole picture — what the client sees when the reading
/// settled nothing, and the same thing "the whole thing" shows on purpose.
struct ConsultInspirationCropView: View {
    let url: URL
    let region: ConsultInspirationRegion?
    let accessibilityLabel: String
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var failed = false

    /// The crop as a pixel rect, clamped into the image. A region whose width
    /// or height rounds to nothing falls back to the whole picture rather than
    /// to a zero-sized view that looks like a layout bug.
    private func cropped(_ source: UIImage) -> UIImage {
        guard let region, region.w > 0.01, region.h > 0.01,
              let cgImage = source.cgImage else { return source }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let rect = CGRect(
            x: max(0, min(width - 1, CGFloat(region.x) * width)),
            y: max(0, min(height - 1, CGFloat(region.y) * height)),
            width: max(1, min(width, CGFloat(region.w) * width)),
            height: max(1, min(height, CGFloat(region.h) * height))
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cut = cgImage.cropping(to: rect) else { return source }
        return UIImage(cgImage: cut, scale: source.scale, orientation: source.imageOrientation)
    }

    var body: some View {
        Group {
            if let image {
                let shown = cropped(image)
                Button(action: onTap) {
                    Image(uiImage: shown)
                        .resizable()
                        .aspectRatio(shown.size.width / max(shown.size.height, 1), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityLabel) — tap to see the whole photo")
            } else if failed {
                // Surfaced, never silent: she is being asked about a picture,
                // so if we cannot put it in front of her she is told.
                Text("We couldn’t load your inspiration photo for this one.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("consult-inspiration-card-image-error")
            } else {
                ProgressView()
                    .tint(BrandColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
        }
        .accessibilityIdentifier("consult-inspiration-crop")
        .task(id: url) {
            let loaded = await ConsultInspirationReferenceStore.shared.image(for: url)
            image = loaded
            failed = loaded == nil
        }
    }
}

/// One card: the crop, then the plain word for it, then the question.
struct ConsultInspirationCardView: View {
    let message: ConsultThreadMessage
    let card: ConsultInspirationCard
    let model: ConsultFlowViewModel
    let onFullscreen: (FullscreenMedia) -> Void

    @State private var url: URL?

    /// The options that carry a crop of their own — the coarse spark card's
    /// "the color" versus "the shape of it". Seeing the difference is what
    /// makes the question answerable by someone never asked it before.
    private var optionCrops: [ConsultInspirationCardOption] {
        card.optionRegions.filter { $0.region != nil }
    }

    var body: some View {
        ConsultThreadCardView(dimmed: card.isAnswered) {
            VStack(alignment: .leading, spacing: 10) {
                if let url {
                    ConsultInspirationCropView(
                        url: url,
                        region: card.region,
                        accessibilityLabel: card.name ?? "Part of your inspiration photo",
                        onTap: { open(url) }
                    )
                    if !optionCrops.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(optionCrops) { option in
                                VStack(spacing: 4) {
                                    ConsultInspirationCropView(
                                        url: url,
                                        region: option.region,
                                        accessibilityLabel: option.label,
                                        onTap: { open(url) }
                                    )
                                    Text(option.label)
                                        .font(BrandFont.body(11))
                                        .foregroundStyle(BrandColor.textSecondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                // 🔴 UNDER the crop. Never above it.
                if let name = card.name {
                    Text(name)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("consult-inspiration-card-name")
                }

                Text(card.question.label)
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("consult-inspiration-card-prompt")

                if card.isAnswered {
                    Text(
                        card.question.options
                            .filter { card.selectedValues.contains($0.value) }
                            .map(\.label)
                            .joined(separator: ", ")
                    )
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ConsultInspirationQuestionView(
                        question: card.question,
                        busy: model.busy,
                        // The card already asked it, under the crop and after
                        // the plain word. Once is the product.
                        showLabel: false,
                        onAnswer: { values in
                            Task {
                                await model.answerInspiration(
                                    message, question: card.question, selectedValues: values
                                )
                            }
                        }
                    )
                    .id("\(card.questionKey):\(card.selectedValues.joined(separator: ","))")
                }
            }
        }
        .accessibilityIdentifier("consult-inspiration-card")
        .task(id: card.questionKey) {
            // The view model caches the signed read, so every card on the
            // thread shares ONE request for the URL and one decode of the bytes.
            if case let .ready(fetched) = await model.inspirationImage() {
                url = fetched
            }
        }
    }

    private func open(_ url: URL) {
        onFullscreen(
            FullscreenMedia(
                id: "consult-inspiration",
                source: .remote(url: url, isVideo: false),
                overlay: nil
            )
        )
    }
}
