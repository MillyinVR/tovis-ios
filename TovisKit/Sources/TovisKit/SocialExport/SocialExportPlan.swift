// Where every pixel goes — the whole geometry of an export, decided before a
// single byte is drawn.
//
// 🔴 Load-bearing arithmetic. This is what decides whether the client's face is
// in the picture the pro posts. A sign error, a swapped axis or an off-by-one on
// the free-travel clamp does not crash and does not look wrong in code review —
// it silently posts somebody's shoulder. It lives here, pure and in TovisKit,
// because that is the only thing in this repo CI actually runs.
import CoreGraphics

/// Which half of a diptych a placement is (or that it is the whole picture).
public enum SocialExportRole: String, Sendable, Equatable {
    case single
    case before
    case after
}

/// One source image's journey into the canvas.
public struct SocialExportPlacement: Sendable, Equatable {
    /// The part of the SOURCE that survives, as a normalized top-left rect.
    public let sourceCrop: CGRect
    /// Where it lands in the canvas, in canvas pixels (top-left origin).
    public let destination: CGRect
    public let role: SocialExportRole
}

/// A complete export, as geometry.
public struct SocialExportPlan: Sendable, Equatable {
    public let format: SocialExportFormat
    public let canvasSize: CGSize
    public let placements: [SocialExportPlacement]
    /// nil for a single shot; the arrangement used for a pair.
    public let arrangement: SocialExportArrangement?
}

public enum SocialExportPlanner {
    /// The hairline between the halves of a diptych, in canvas pixels. Small
    /// enough to read as a seam rather than a border (4 px of 1080 ≈ 0.4%), big
    /// enough that two similar frames don't blur into one photo.
    public static let diptychGutter: CGFloat = 4

    /// Where the subject's centre wants to sit inside the crop, vertically.
    ///
    /// Not 0.5. A portrait centred on the midpoint of the face reads as sinking —
    /// the eyes end up low and the frame grows dead space over the head. Beauty
    /// work is judged on the head and the hair, so the subject box sits a little
    /// high and the room goes underneath, where the shoulders and the finished
    /// style are. Same instinct the live coach's headroom rule already applies to
    /// the viewfinder; this is that rule surviving the crop.
    public static let subjectAnchorY: CGFloat = 0.44

    /// Horizontally there is no equivalent bias — off-centre horizontal framing
    /// is a compositional choice a photographer makes deliberately, not a default
    /// worth guessing. Centre the subject and let the pro nudge it.
    public static let subjectAnchorX: CGFloat = 0.5

    // MARK: - Crop

    /// The crop of a source, as a normalized TOP-LEFT rect.
    ///
    /// Three steps, in order:
    ///   1. the largest `targetAspect` rect that fits the source, centred
    ///      (`PublishCrop.rect` — the same geometry the live crop guide draws);
    ///   2. slide it along whichever axis has slack so the subject lands on its
    ///      anchor, clamped so the crop never leaves the source;
    ///   3. apply the pro's manual nudge across the travel that remains.
    ///
    /// - Parameters:
    ///   - subject: normalized top-left subject box in the SOURCE, or nil for a
    ///     plain centred crop.
    ///   - adjust: −1 … +1. 0 is the smart result; −1 pins the crop to the top or
    ///     left edge, +1 to the bottom or right. The mapping is across the
    ///     REMAINING travel in each direction, so both extremes are always
    ///     reachable no matter where the smart default landed.
    public static func crop(
        sourceAspect: CGFloat,
        targetAspect: CGFloat,
        subject: CGRect? = nil,
        adjust: CGFloat = 0
    ) -> CGRect {
        let base = PublishCrop.rect(aspect: targetAspect, frameAspect: sourceAspect)

        // Exactly one axis can have slack (the other is pinned at full extent by
        // construction), so figure out which and solve in one dimension.
        let horizontalSlack = max(0, 1 - base.width)
        let verticalSlack = max(0, 1 - base.height)

        if verticalSlack > horizontalSlack {
            let smart = smartOrigin(
                slack: verticalSlack,
                extent: base.height,
                subjectCenter: subject.map { clamped01($0.midY) },
                anchor: subjectAnchorY
            )
            let y = applyAdjust(smart, slack: verticalSlack, adjust: adjust)
            return CGRect(x: base.minX, y: y, width: base.width, height: base.height)
        }

        if horizontalSlack > 0 {
            let smart = smartOrigin(
                slack: horizontalSlack,
                extent: base.width,
                subjectCenter: subject.map { clamped01($0.midX) },
                anchor: subjectAnchorX
            )
            let x = applyAdjust(smart, slack: horizontalSlack, adjust: adjust)
            return CGRect(x: x, y: base.minY, width: base.width, height: base.height)
        }

        // Aspects match — the whole source ships and there is nothing to decide.
        return base
    }

    /// The crop origin that puts `subjectCenter` on `anchor` within the crop,
    /// clamped into the source. No subject → the centred default.
    private static func smartOrigin(
        slack: CGFloat,
        extent: CGFloat,
        subjectCenter: CGFloat?,
        anchor: CGFloat
    ) -> CGFloat {
        guard slack > 0 else { return 0 }
        guard let subjectCenter else { return slack / 2 }
        return min(max(subjectCenter - anchor * extent, 0), slack)
    }

    /// Map the pro's −1 … +1 nudge onto the travel still available on each side of
    /// the smart origin. Both ends stay reachable however off-centre the smart
    /// result was — a subject already hard against the top edge can still be
    /// dragged all the way down.
    private static func applyAdjust(
        _ origin: CGFloat,
        slack: CGFloat,
        adjust: CGFloat
    ) -> CGFloat {
        guard slack > 0 else { return 0 }
        let a = min(max(adjust, -1), 1)
        let moved = a >= 0 ? origin + a * (slack - origin) : origin + a * origin
        return min(max(moved, 0), slack)
    }

    private static func clamped01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    // MARK: - Plan

    /// The full geometry for one export.
    public static func plan(
        format: SocialExportFormat,
        subject: SocialExportSubject
    ) -> SocialExportPlan {
        let canvas = format.pixelSize

        switch subject {
        case let .single(source):
            let placement = SocialExportPlacement(
                sourceCrop: crop(
                    sourceAspect: source.aspect,
                    targetAspect: format.aspect,
                    subject: source.subject,
                    adjust: source.adjust
                ),
                destination: CGRect(origin: .zero, size: canvas),
                role: .single
            )
            return SocialExportPlan(
                format: format,
                canvasSize: canvas,
                placements: [placement],
                arrangement: nil
            )

        case let .pair(before, after):
            let arrangement = format.pairArrangement
            let slots = halves(of: canvas, arrangement: arrangement)
            let placements = zip([before, after], zip(slots, [SocialExportRole.before, .after]))
                .map { source, slotAndRole -> SocialExportPlacement in
                    let (slot, role) = slotAndRole
                    // Each half is cropped to ITS OWN aspect, not the canvas's —
                    // that is the whole reason the arrangement is per-format.
                    let halfAspect = slot.height > 0 ? slot.width / slot.height : format.aspect
                    return SocialExportPlacement(
                        sourceCrop: crop(
                            sourceAspect: source.aspect,
                            targetAspect: halfAspect,
                            subject: source.subject,
                            adjust: source.adjust
                        ),
                        destination: slot,
                        role: role
                    )
                }
            return SocialExportPlan(
                format: format,
                canvasSize: canvas,
                placements: placements,
                arrangement: arrangement
            )
        }
    }

    // MARK: - Where the signature can safely sit

    /// Inset from the canvas edge before anything is drawn, as a fraction of the
    /// short edge.
    public static let signatureInsetFraction: CGFloat = 0.045

    /// The box a signature may be drawn in — right-aligned along its bottom edge.
    ///
    /// 🔴 The 9:16 case is the reason this is a function and not a constant. A
    /// vertical post is not shown bare: the platform lays its caption, audio row
    /// and action rail over roughly the bottom 450 px of 1920, and the profile row
    /// over the top 220. A signature in the true bottom-right corner of a 9:16
    /// export is therefore a signature nobody ever sees — the one failure mode
    /// that makes the whole feature pointless while looking perfect in the
    /// preview. So the 9:16 box is inset to the published cover-safe band
    /// (`PublishCrop.coverSafeRect`, the same numbers the live overlay draws).
    /// A 4:5 feed post has no such overlay, so it uses the plain inset.
    ///
    /// Returned in TOP-LEFT canvas coordinates, like everything else here.
    public static func signatureBox(
        in canvas: CGSize,
        format: SocialExportFormat
    ) -> CGRect {
        let inset = min(canvas.width, canvas.height) * signatureInsetFraction
        let full = CGRect(origin: .zero, size: canvas).insetBy(dx: inset, dy: inset)
        switch format {
        case .feed916:
            return PublishCrop.coverSafeRect(in: full)
        case .instagram45:
            return full
        }
    }

    /// The two slots a diptych's halves occupy, gutter already removed.
    public static func halves(
        of canvas: CGSize,
        arrangement: SocialExportArrangement
    ) -> [CGRect] {
        switch arrangement {
        case .sideBySide:
            let w = (canvas.width - diptychGutter) / 2
            return [
                CGRect(x: 0, y: 0, width: w, height: canvas.height),
                CGRect(x: canvas.width - w, y: 0, width: w, height: canvas.height),
            ]
        case .stacked:
            let h = (canvas.height - diptychGutter) / 2
            return [
                CGRect(x: 0, y: 0, width: canvas.width, height: h),
                CGRect(x: 0, y: canvas.height - h, width: canvas.width, height: h),
            ]
        }
    }
}
