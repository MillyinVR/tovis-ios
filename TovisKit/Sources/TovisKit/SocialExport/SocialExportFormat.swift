// The boxes a pro's work actually gets posted in.
//
// The camera has always been a very good photographer and stopped at upload: it
// produced an excellent 3:4 JPEG and handed it over. This is the other half of
// the promise — the file that is ready to post, in the shape the platform wants,
// signed by the pro who made it.
//
// Two canvases, deliberately. 9:16 is Reels / TikTok / Shorts / the Looks feed;
// 4:5 is Instagram's tallest feed post, which is where salon before-afters get
// saved and shared. 1:1 is a real gap (the IG profile grid, most ad units) and is
// recorded as a follow-up rather than guessed at here — see
// docs/design/camera-excellence-plan.md D1.
import CoreGraphics

/// One platform-ready canvas.
public enum SocialExportFormat: String, CaseIterable, Sendable, Identifiable {
    /// 1080×1920 — Reels, TikTok, Shorts, the Looks feed.
    case feed916
    /// 1080×1350 — Instagram's tallest feed post.
    case instagram45

    public var id: String { rawValue }

    /// Export pixel size. Fixed at the platforms' own upload targets rather than
    /// derived from the source: a smaller source is upscaled to the box (the
    /// platform would do it anyway, worse), a larger one is downscaled once here
    /// instead of being re-compressed on the way up.
    public var pixelSize: CGSize {
        switch self {
        case .feed916: return CGSize(width: 1080, height: 1920)
        case .instagram45: return CGSize(width: 1080, height: 1350)
        }
    }

    /// Width ÷ height. Reads from `PublishCrop`, which is the same geometry the
    /// live crop guide draws and the coach judges inside — so what the pro was
    /// told was "in frame" while shooting is what survives the export.
    public var aspect: CGFloat {
        switch self {
        case .feed916: return PublishCrop.feed
        case .instagram45: return PublishCrop.instagramFeed
        }
    }

    public var shortLabel: String {
        switch self {
        case .feed916: return "9:16"
        case .instagram45: return "4:5"
        }
    }

    public var platformLabel: String {
        switch self {
        case .feed916: return "Reels · TikTok · Looks"
        case .instagram45: return "Instagram feed"
        }
    }

    /// How a before/after pair is laid out inside this canvas.
    ///
    /// Not a preference — geometry. Splitting a 9:16 box side by side leaves each
    /// half at roughly 0.28 w/h, which is a letterbox slot no face survives; the
    /// same split of a 4:5 box gives a normal tall portrait. So the tall canvas
    /// stacks and the squarer one sits side by side, and each half stays a shape
    /// a person fits in.
    public var pairArrangement: SocialExportArrangement {
        switch self {
        case .feed916: return .stacked
        case .instagram45: return .sideBySide
        }
    }
}

/// Where the "before" sits relative to the "after" in a diptych.
public enum SocialExportArrangement: String, Sendable, Equatable {
    /// Before left, after right.
    case sideBySide
    /// Before top, after bottom.
    case stacked
}

/// What is being exported.
public enum SocialExportSubject: Sendable, Equatable {
    /// One shot.
    case single(SocialExportSource)
    /// A before/after pair, rendered as a diptych. Order is fixed — a diptych
    /// that reads after-then-before is not a transformation, it is a warning.
    case pair(before: SocialExportSource, after: SocialExportSource)

    public var sources: [SocialExportSource] {
        switch self {
        case let .single(s): return [s]
        case let .pair(before, after): return [before, after]
        }
    }
}

/// One source image, described by the only two things the geometry needs: how big
/// it is, and where the subject is in it.
public struct SocialExportSource: Sendable, Equatable {
    /// Pixel dimensions of the source image, already upright.
    public let pixelSize: CGSize

    /// Where the person is, as a normalized TOP-LEFT rect of the source. Comes
    /// from the camera's own Vision detection when the shot was taken with the
    /// coach on; `nil` for an imported or older shot, which falls back to a plain
    /// centered crop. It is a hint that improves the crop, never a requirement.
    public let subject: CGRect?

    /// Pro's manual nudge along whatever axis the crop is free to slide on,
    /// −1 … +1 (negative = toward the top/left edge). 0 is the smart default.
    public let adjust: CGFloat

    public init(pixelSize: CGSize, subject: CGRect? = nil, adjust: CGFloat = 0) {
        self.pixelSize = pixelSize
        self.subject = subject
        self.adjust = adjust
    }

    /// Width ÷ height of the source. Zero-safe: a degenerate size reports 1 so the
    /// crop math downstream can never divide by zero on a malformed decode.
    public var aspect: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        return pixelSize.width / pixelSize.height
    }

    /// The same source with a different manual adjustment.
    public func adjusted(to value: CGFloat) -> SocialExportSource {
        SocialExportSource(pixelSize: pixelSize, subject: subject, adjust: value)
    }

    /// Build from the subject focal point the media pipeline already stores
    /// (camera C6 — the face the camera found at capture time, normalized
    /// top-left, and the same value the feed's cover-crop centres on).
    ///
    /// Reusing it is the cheap half of "smart crop": there is no new detection
    /// pass, no Vision on a downloaded JPEG, just the answer the camera already
    /// computed while the pro was standing there. A point is enough — the crop
    /// only reads the subject's centre — so it is widened into a nominal box
    /// rather than pretending to know the subject's size.
    ///
    /// Practice shots carry a focal today; booking and library media do not
    /// surface one on read, and they fall back to the centred crop.
    public init(pixelSize: CGSize, focal: MediaFocalPoint?, adjust: CGFloat = 0) {
        let box = focal.map { f -> CGRect in
            let side: CGFloat = 0.3
            return CGRect(x: f.x - side / 2, y: f.y - side / 2, width: side, height: side)
        }
        self.init(pixelSize: pixelSize, subject: box, adjust: adjust)
    }
}
