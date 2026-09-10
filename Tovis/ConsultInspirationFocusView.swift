import SwiftUI
import TovisKit
import UIKit

/// The same local, explicit focus confirmation as the web inspiration picker.
struct ConsultInspirationFocusView: View {
    let image: UIImage
    let busy: Bool
    let onConfirm: (CGRect) -> Void
    let onCancel: () -> Void
    @State private var crop: MediaCropRect?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Whose look should we focus on?").font(BrandFont.body(20, .semibold))
                Text("Tap the person, then adjust the box around the hair or feature you want to discuss. Leave out other people and unrelated details.")
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
                    .accessibilityLabel("Your inspiration photo")
                if let crop {
                    edge("Left edge", handle: .left, value: crop.x)
                    edge("Right edge", handle: .right, value: crop.x + crop.w)
                    edge("Top edge", handle: .top, value: crop.y)
                    edge("Bottom edge", handle: .bottom, value: crop.y + crop.h)
                    Text("This is the area we will use").font(BrandFont.body(14))
                    GeometryReader { geometry in
                        CropWindowLayer(image: image, crop: crop, container: geometry.size, fit: .contain, focal: nil)
                    }.frame(height: 200)
                    Button("Use this area") { onConfirm(crop.rect) }
                        .buttonStyle(.borderedProminent).tint(BrandColor.accent)
                        .accessibilityIdentifier("consult-focus-confirm")
                } else {
                    Button("Start with the person in the center") { place(x: 0.5, y: 0.5) }
                        .buttonStyle(.bordered)
                }
                Text("If you cannot isolate the look clearly, choose a closer photo.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                Button("Choose another photo", action: onCancel).buttonStyle(.bordered)
            }
            .padding(20).disabled(busy)
        }
        .foregroundStyle(BrandColor.textPrimary).background(BrandColor.bgSurface)
        .interactiveDismissDisabled(busy)
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
