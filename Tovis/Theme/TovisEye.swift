import SwiftUI

/// The Tovis "Eye" mark, ported 1:1 from the web SVG (`lib/brand/eyeSvg.ts`):
/// a leaf/eye silhouette filled with the Peacock-Plume radial gradient, plus the
/// cream highlight dot. Drawn natively so it stays crisp at any size.
struct TovisEye: View {
    var size: CGFloat = 72

    // Gradient stops — exact hex values from the web mark.
    private let stops: [Gradient.Stop] = [
        .init(color: Color(red: 255 / 255, green: 246 / 255, blue: 226 / 255), location: 0.00), // #FFF6E2
        .init(color: Color(red: 242 / 255, green: 180 / 255, blue: 62 / 255), location: 0.22),  // #F2B43E
        .init(color: Color(red: 21 / 255, green: 201 / 255, blue: 168 / 255), location: 0.48),   // #15C9A8
        .init(color: Color(red: 21 / 255, green: 116 / 255, blue: 196 / 255), location: 0.74),   // #1574C4
        .init(color: Color(red: 107 / 255, green: 75 / 255, blue: 230 / 255), location: 1.00),   // #6B4BE6
    ]

    var body: some View {
        ZStack {
            EyeShape()
                .fill(
                    RadialGradient(
                        stops: stops,
                        center: UnitPoint(x: 0.48, y: 0.40),
                        startRadius: 0,
                        endRadius: size * 0.64
                    )
                )
            // Highlight dot: SVG circle cx=42 cy=38 r=6.5 on a 100-unit canvas.
            Circle()
                .fill(Color(red: 255 / 255, green: 246 / 255, blue: 226 / 255))
                .frame(width: size * 0.13, height: size * 0.13)
                .position(x: size * 0.42, y: size * 0.38)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Tovis")
    }
}

/// The leaf/eye silhouette: SVG path `M50 4 C78 27 78 73 50 96 C22 73 22 27 50 4 Z`
/// on a 0–100 canvas, scaled to fit.
private struct EyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        var path = Path()
        path.move(to: p(50, 4))
        path.addCurve(to: p(50, 96), control1: p(78, 27), control2: p(78, 73))
        path.addCurve(to: p(50, 4), control1: p(22, 73), control2: p(22, 27))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        BrandColor.bgPrimary.ignoresSafeArea()
        TovisEye(size: 120)
    }
}
