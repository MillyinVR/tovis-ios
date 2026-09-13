import SwiftUI
import TovisKit
import UIKit

/// The words of one focus card. Twin of web's `BrandConsultFocusCopy`.
struct ConsultPhotoFocusCopy: Equatable, Sendable {
    let title: String
    let instruction: String
    let center: String
    let confirm: String
    let cancel: String
    let preview: String
    let closer: String
    let photo: String
    /// Offers the WHOLE frame as its own answer. Nil = a crop is required.
    let fullFrame: String?

    /// Someone else's photograph, narrowed to the look being discussed.
    static let inspiration = ConsultPhotoFocusCopy(
        title: "Whose look should we focus on?",
        instruction: "Tap the person, then adjust the box around the hair or feature you want to discuss. Leave out other people and unrelated details.",
        center: "Start with the person in the center",
        confirm: "Use this area",
        cancel: "Choose another photo",
        preview: "This is the area we will use",
        closer: "If you cannot isolate the look clearly, choose a closer photo.",
        photo: "Your inspiration photo",
        fullFrame: nil
    )

    /// 🔴 Her own photo (Tori, 2026-09-13). The whole frame is the FIRST
    /// answer here, not a fallback: she has just chosen a picture of herself,
    /// and cropping is the exception — for a group shot, or when she is small
    /// in the frame. Same words as web's `captureFocus`.
    static let selfie = ConsultPhotoFocusCopy(
        title: "Happy with this photo?",
        instruction: "Send it as it is, or zoom in on yourself first — worth doing if someone else is in the shot, or if you are small in the frame.",
        center: "Zoom in on me",
        confirm: "Use this area",
        cancel: "Choose another photo",
        preview: "This is the part we will use",
        closer: "Keep just yourself in the part you choose — leave anyone else out of it.",
        photo: "Your photo",
        fullFrame: "Use the whole photo"
    )
}

/// The same local, explicit focus confirmation as the web picker.
///
/// `onConfirm(nil)` is "the whole photograph, as it is" — offered only when the
/// copy carries a `fullFrame` label, because an inspiration reference has no
/// such answer: singling a region out is the entire point of asking for one.
struct ConsultPhotoFocusView: View {
    let image: UIImage
    let copy: ConsultPhotoFocusCopy
    let busy: Bool
    let onConfirm: (CGRect?) -> Void
    let onCancel: () -> Void
    @State private var crop: MediaCropRect?

    var body: some View {
        ScrollView { content }
        .foregroundStyle(BrandColor.textPrimary).background(BrandColor.bgSurface)
        .interactiveDismissDisabled(busy)
    }

    /// The card itself, outside the scroller.
    ///
    /// 🔴 Not `private`, and not inlined into `body`: `ImageRenderer` draws a
    /// `ScrollView` as an empty page, so a render test over `body` proves
    /// nothing at all (it writes a blank PNG and passes). The tests draw THIS,
    /// which is the thing the sheet actually puts on screen.
    @ViewBuilder var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(copy.title).font(BrandFont.body(20, .semibold))
                Text(copy.instruction)
                    .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        GeometryReader { geometry in
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .gesture(SpatialTapGesture().onEnded { value in
                                        guard !busy, geometry.size.width > 0, geometry.size.height > 0 else { return }
                                        place(x: value.location.x / geometry.size.width,
                                              y: value.location.y / geometry.size.height)
                                    })
                                if let crop {
                                    Rectangle().stroke(BrandColor.accent, lineWidth: 3)
                                        .frame(width: crop.w * geometry.size.width, height: crop.h * geometry.size.height)
                                        .offset(x: crop.x * geometry.size.width, y: crop.y * geometry.size.height)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .accessibilityLabel(copy.photo)
                if let fullFrame = copy.fullFrame {
                    Button(fullFrame) { onConfirm(nil) }
                        .buttonStyle(.borderedProminent).tint(BrandColor.accent)
                        .accessibilityIdentifier("consult-focus-full-frame")
                }
                if let crop {
                    edge("Left edge", handle: .left, value: crop.x)
                    edge("Right edge", handle: .right, value: crop.x + crop.w)
                    edge("Top edge", handle: .top, value: crop.y)
                    edge("Bottom edge", handle: .bottom, value: crop.y + crop.h)
                    Text(copy.preview).font(BrandFont.body(14))
                    GeometryReader { geometry in
                        CropWindowLayer(image: image, crop: crop, container: geometry.size, fit: .contain, focal: nil)
                    }.frame(height: 200)
                    Button(copy.confirm) { onConfirm(crop.rect) }
                        .buttonStyle(.borderedProminent).tint(BrandColor.accent)
                        .accessibilityIdentifier("consult-focus-confirm")
                } else {
                    Button(copy.center) { place(x: 0.5, y: 0.5) }
                        .buttonStyle(.bordered)
                }
                Text(copy.closer)
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                Button(copy.cancel, action: onCancel).buttonStyle(.bordered)
            }
            .padding(20).disabled(busy)
    }

    private func place(x: Double, y: Double) {
        crop = MediaCropRect(x: min(0.6, max(0, x - 0.2)),
                             y: min(0.5, max(0, y - 0.25)), w: 0.4, h: 0.5)
    }

    private enum Edge { case left, right, top, bottom }

    private func edge(_ label: String, handle: Edge, value: Double) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            Slider(value: Binding(get: { value }, set: { resize(handle, to: $0) }), in: 0...1, step: 0.005)
                .accessibilityLabel(label).tint(BrandColor.accent)
        }
    }

    private func resize(_ edge: Edge, to value: Double) {
        guard let crop, value.isFinite else { return }
        var left = crop.x, right = crop.x + crop.w, top = crop.y, bottom = crop.y + crop.h
        switch edge {
        case .left: left = min(right - 0.08, max(0, value))
        case .right: right = max(left + 0.08, min(1, value))
        case .top: top = min(bottom - 0.08, max(0, value))
        case .bottom: bottom = max(top + 0.08, min(1, value))
        }
        if let updated = MediaCropRect(x: left, y: top, w: right - left, h: bottom - top) {
            self.crop = updated
        }
    }
}
