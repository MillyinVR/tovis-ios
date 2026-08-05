// The single clamp every AVCaptureDevice parameter write goes through.
//
// AVFoundation validates these writes with ObjC exceptions, which Swift cannot
// catch: an out-of-range gain, a NaN exposure bias or a focus point off the unit
// square is not a degraded camera, it is `abort()` on the session queue with no
// preview ever drawn.
//
// #273 fixed three such writes (still size, colour space, zoom) by checking each
// against the settled format. Build 37 then died on a FOURTH — locked white
// balance — even though that call site *had* a clamp:
//
//     min(max(Float(x), 1), maxGain)
//
// Swift's `min`/`max` are `Comparable`, so every comparison against NaN is
// false and the NaN falls straight back out. ±infinity, 0 and 99 all clamped
// correctly; NaN alone walked through, and a NaN that had been persisted to
// UserDefaults re-poisoned the device on every single camera open.
//
// So the clamp does not get rewritten per call site. It lives here once, it is
// NaN-safe, and it answers `nil` — "make no write at all" — whenever no safe
// value exists.
import CoreGraphics

public enum DeviceParameterGuard {

    /// `value` brought into `lower...upper`, or nil when no safe write exists.
    ///
    /// A non-nil result is always finite and always inside the range, including
    /// for ±infinity, which saturates to the nearer bound. Nil means the caller
    /// must leave the device alone rather than substitute a guess.
    ///
    /// Bounds read off a device are themselves treated as untrusted: a non-finite
    /// limit, or an inverted range, yields nil.
    public static func clamped<F: BinaryFloatingPoint>(_ value: F, lower: F, upper: F) -> F? {
        guard !value.isNaN, lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }

    /// Locked white-balance gains for `setWhiteBalanceModeLocked(with:)`, clamped
    /// into the device's `1...maxGain`.
    ///
    /// Nil if ANY component is unusable — a half-valid calibration would silently
    /// mis-colour every photo, and the honest answer is to stay on automatic
    /// white balance rather than lock to a guess.
    public static func whiteBalanceGains(
        r: Double, g: Double, b: Double, maxGain: Float
    ) -> (r: Float, g: Float, b: Float)? {
        guard let cr = clamped(Float(r), lower: 1, upper: maxGain),
              let cg = clamped(Float(g), lower: 1, upper: maxGain),
              let cb = clamped(Float(b), lower: 1, upper: maxGain)
        else { return nil }
        return (cr, cg, cb)
    }

    /// A focus / exposure point of interest in the device's unit square.
    ///
    /// Nil when either axis is NaN: a preview layer with zero bounds converts
    /// taps to NaN, and AVFoundation raises on the write rather than ignoring it.
    public static func unitPoint(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard let cx = clamped(x, lower: 0, upper: 1),
              let cy = clamped(y, lower: 0, upper: 1)
        else { return nil }
        return (cx, cy)
    }

    /// `unitPoint(x:y:)` for the `CGPoint` the capture APIs actually take.
    public static func unitPoint(_ point: CGPoint) -> CGPoint? {
        guard let safe = unitPoint(x: Double(point.x), y: Double(point.y)) else { return nil }
        return CGPoint(x: safe.x, y: safe.y)
    }
}
