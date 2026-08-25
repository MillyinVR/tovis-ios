// Deterministic frames for `run.sh --selftest`, generated rather than committed.
//
// The bench's REAL corpus is 35 photographs from an installed simulator
// runtime (docs/camera-tuning-bench.md). That corpus cannot go in CI: the
// files are Apple's, this repo is public, and the runtime version on a hosted
// runner is not the one the recorded numbers came from — so a job that
// re-measured against it would either publish someone else's assets or
// compare numbers to a different set of images.
//
// So CI checks the OTHER thing, the thing that actually rotted twice: that the
// bench still compiles against the live sources and still runs end to end.
// These frames exist to be run over, not to be measured — nothing pins the
// values they produce, and they are NOT photographs. Synthetic gradients have
// no faces, no real optics and no salon light; every number they yield is
// meaningless as tuning data. The self-test asserts the pipeline COMPLETED.
//
// Foundation + CoreGraphics + ImageIO only: this builds on its own, with none
// of the app sources, so a failure here can never be confused for a failure in
// the bench proper.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One synthetic frame. Deliberately varied so the run touches more than one
/// branch of the coaches — a flat mid-grey field would exercise almost nothing.
struct Frame {
    let name: String
    /// Returns the colour at a normalized point. Pure, so the bytes are
    /// identical on every machine and every run.
    let shade: (Double, Double) -> (r: Double, g: Double, b: Double)
}

let frames: [Frame] = [
    // Very dark — LightingCoach's `lumaTooDark` side.
    Frame(name: "01-underexposed") { _, _ in (0.06, 0.06, 0.07) },
    // Very bright — the `lumaTooBright` side.
    Frame(name: "02-blown-out") { _, _ in (0.97, 0.96, 0.95) },
    // Warm on the left, cool on the right: the left/right/thirds spread
    // `mixedLightSpread` is measured from.
    Frame(name: "03-split-warm-cool") { x, _ in
        x < 0.5 ? (0.72, 0.55, 0.32) : (0.35, 0.48, 0.74)
    },
    // High-frequency checks — edge energy, which is what `sharpness` and
    // `clutterReference` are normalized against.
    Frame(name: "04-fine-checks") { x, y in
        let on = (Int(x * 64) + Int(y * 64)) % 2 == 0
        let v = on ? 0.82 : 0.18
        return (v, v, v)
    },
    // A smooth ramp with almost no edge energy — the soft end of the same axis.
    Frame(name: "05-smooth-ramp") { x, y in
        let v = 0.2 + 0.6 * ((x + y) / 2)
        return (v, v, v)
    },
]

let side = 512

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: selftest-corpus <output-dir>\n".utf8))
    exit(64)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()
for frame in frames {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    for row in 0..<side {
        for column in 0..<side {
            let (r, g, b) = frame.shade(
                (Double(column) + 0.5) / Double(side), (Double(row) + 0.5) / Double(side))
            let i = (row * side + column) * 4
            bytes[i] = UInt8(max(0, min(255, r * 255)).rounded())
            bytes[i + 1] = UInt8(max(0, min(255, g * 255)).rounded())
            bytes[i + 2] = UInt8(max(0, min(255, b * 255)).rounded())
            bytes[i + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    else {
        FileHandle.standardError.write(Data("error: could not build \(frame.name)\n".utf8))
        exit(1)
    }
    let url = outDir.appendingPathComponent("\(frame.name).png")
    guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("error: could not open \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("error: could not write \(url.path)\n".utf8))
        exit(1)
    }
}
print("\(frames.count)")
