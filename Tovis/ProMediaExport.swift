// The pro's two ways out of the app with their own work: SAVE and EXPORT.
//
// They are deliberately different things, and the whole file is arranged around
// keeping them apart.
//
//   SAVE  — the original file, byte for byte, into the pro's camera roll. No
//           crop, no re-encode, no watermark, no membership, ever. Their photo,
//           their archive, their EXIF. `OriginalMediaBytes` → `PhotoLibrarySaver`,
//           and nothing in between.
//   EXPORT — a platform-ready render made to be posted: cropped to 4:5 or 9:16,
//           laid out as a diptych for a pair, and signed. Goes to the share sheet,
//           to Photos, or both — the pro's choice, and the destination has no say
//           in what gets drawn.
//
// 🔴 That separation is why the save path never touches `SocialExportRenderer`.
// The renderer requires a watermark and `SocialExportPolicy.watermark` refuses to
// produce one for a save, so "a save is always clean" is a fact about the types
// rather than a rule someone has to remember at four call sites.
import SwiftUI
import TovisKit
import UIKit

/// One image the export machinery can work from.
enum ProExportImageRef {
    /// A media asset the server holds. Save fetches its ORIGINAL bytes.
    case remote(URL)
    /// Bytes already in hand (a shot that hasn't been uploaded yet).
    case bytes(Data)
}

/// What a surface hands over when it offers save/export. Built by the pro-side
/// media surfaces only — a client viewing their own chart photo is the follow-up
/// card, not this (see HANDOFF-camera-redesign.md).
struct ProMediaExportContext {
    /// The shot itself — the "after" when there is a pair.
    let main: ProExportImageRef
    /// The subject focal the pipeline stored for `main`, when the surface has one.
    var focal: MediaFocalPoint?
    /// The paired "before". Present → the diptych formats are offered.
    var before: ProExportImageRef?
    var beforeFocal: MediaFocalPoint?
    /// Videos can be saved but not exported — the still pack is stills. Clip
    /// export is a follow-up (HANDOFF-camera-redesign.md).
    var isVideo: Bool = false

    var canExport: Bool { !isVideo }
    var hasPair: Bool { before != nil && !isVideo }
}

/// Loads the pro's identity once, then saves and renders on demand.
///
/// Held by the surface that presents the export sheet so a format switch or a
/// crop nudge re-renders without re-downloading the source.
@MainActor
@Observable
final class ProMediaExportModel {
    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
        case done(String)
    }

    private(set) var phase: Phase = .idle
    /// The pro's own signature + tier, loaded once per sheet.
    private(set) var membership: ProMembership?
    private(set) var profile: ProMyProfile?
    private(set) var identityLoaded = false

    /// Decoded sources, keyed so a re-render doesn't re-download.
    private var decoded: [String: CGImage] = [:]

    /// Pixel size of the main shot once it has been decoded. The sheet needs it to
    /// label the crop slider honestly — a source taller than the export box slides
    /// up and down, a wider one slides side to side, and telling the pro the wrong
    /// one is a small lie they discover by dragging.
    private(set) var mainPixelSize: CGSize?

    /// The watermark this pro's exports carry right now — also what the sheet
    /// shows them, so the preview cannot disagree with the file.
    var exportWatermark: ExportWatermark {
        SocialExportPolicy.watermark(
            for: .socialExport,
            membership: membership,
            handle: profile?.handle,
            businessName: profile?.businessName,
            platformMark: TovisBrand.displayName
        ) ?? ExportWatermark(signature: nil, showsPlatformMark: false, platformMark: TovisBrand.displayName)
    }

    /// True when the pro has no handle and no business name — the sheet nudges
    /// rather than inventing a signature.
    var hasNothingToSignWith: Bool { exportWatermark.signature == nil }

    // MARK: - Identity

    /// Membership + profile. Both failures are non-fatal: a pro who can't reach
    /// the server still gets to export, and `SocialExportPolicy` resolves a
    /// missing membership generously (see its doc for why that is the right side
    /// to fail on).
    func loadIdentity(_ client: TovisClient) async {
        guard !identityLoaded else { return }
        identityLoaded = true
        async let status = try? client.proMembership.status()
        async let mine = try? client.proProfile.myProfile()
        membership = await status
        profile = await mine
    }

    // MARK: - Save (never marked, never re-encoded)

    /// The pro's original file into their camera roll.
    ///
    /// 🔴 The bytes go from the server to `PHAssetCreationRequest` untouched.
    /// Decoding and re-encoding here would strip the capture date, the
    /// orientation tag the web gallery reads, the lens and the colour profile —
    /// and the photo would still look fine, so nobody would notice for months.
    func saveOriginal(_ ref: ProExportImageRef) async {
        phase = .working("Saving…")
        do {
            let data: Data = switch ref {
            case let .remote(url): try await OriginalMediaBytes.fetch(url)
            case let .bytes(data): data
            }
            guard await PhotoLibrarySaver.save(data) else {
                phase = .failed("Couldn’t save to your photos — check Tovis has photo access.")
                return
            }
            phase = .done("Saved to your photos")
        } catch {
            phase = .failed("Couldn’t fetch that photo to save. Try again.")
        }
    }

    // MARK: - Export

    /// Render `format` from this context and return JPEG bytes.
    ///
    /// `pairMode` decides between the single shot and the before/after diptych;
    /// `adjust` is the pro's crop nudge, applied to both halves of a pair.
    func renderExport(
        _ context: ProMediaExportContext,
        format: SocialExportFormat,
        asPair: Bool,
        adjust: CGFloat
    ) async throws -> Data {
        let wantsPair = asPair && context.hasPair
        let mainImage = try await image(for: context.main, key: "main")

        let mainSource = SocialExportSource(
            pixelSize: CGSize(width: mainImage.width, height: mainImage.height),
            focal: context.focal,
            adjust: adjust
        )

        let plan: SocialExportPlan
        var images: [CGImage]
        if wantsPair, let beforeRef = context.before {
            let beforeImage = try await image(for: beforeRef, key: "before")
            let beforeSource = SocialExportSource(
                pixelSize: CGSize(width: beforeImage.width, height: beforeImage.height),
                focal: context.beforeFocal,
                adjust: adjust
            )
            plan = SocialExportPlanner.plan(
                format: format, subject: .pair(before: beforeSource, after: mainSource)
            )
            images = [beforeImage, mainImage]
        } else {
            plan = SocialExportPlanner.plan(format: format, subject: .single(mainSource))
            images = [mainImage]
        }

        let watermark = exportWatermark
        return try await Task.detached(priority: .userInitiated) {
            try SocialExportRenderer.render(plan: plan, images: images, watermark: watermark)
        }.value
    }

    /// Write export bytes to a temp file so the share sheet can hand a real
    /// image (with a filename) to Instagram, Messages or AirDrop rather than a
    /// raw `Data` blob that some targets refuse.
    func temporaryFile(for data: Data, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Save an already-rendered export to Photos. Distinct from `saveOriginal`
    /// on purpose: this one IS marked, because it is an export.
    func savePhotosCopy(of data: Data) async {
        phase = .working("Saving…")
        phase = await PhotoLibrarySaver.save(data)
            ? .done("Export saved to your photos")
            : .failed("Couldn’t save to your photos — check Tovis has photo access.")
    }

    func clearStatus() { phase = .idle }

    // MARK: - Sources

    /// Decode-bounded and orientation-baked, cached per sheet. The bound matters:
    /// these are ORIGINAL uploads at full capture resolution, and holding two of
    /// them undecoded-to-screen-size for a diptych is the allocation that used to
    /// jetsam the camera.
    private func image(for ref: ProExportImageRef, key: String) async throws -> CGImage {
        if let cached = decoded[key] { return cached }
        let data: Data = switch ref {
        case let .remote(url): try await OriginalMediaBytes.fetch(url)
        case let .bytes(bytes): bytes
        }
        guard let image = await Task.detached(priority: .userInitiated, operation: {
            UprightImageDecode.cgImage(from: data, maxPixel: Self.exportMaxPixel)
        }).value else {
            throw SocialExportRenderError.cropFailed
        }
        decoded[key] = image
        if key == "main" {
            mainPixelSize = CGSize(width: image.width, height: image.height)
        }
        return image
    }

    /// Which way the crop can travel for `format`, once the source is known.
    /// Defaults to vertical before the first decode — the camera's own 3:4 is
    /// taller than both export boxes, so that is the common case rather than a
    /// coin flip.
    func cropTravelIsVertical(for format: SocialExportFormat) -> Bool {
        guard let size = mainPixelSize, size.width > 0, size.height > 0 else { return true }
        let crop = PublishCrop.rect(
            aspect: format.aspect, frameAspect: size.width / size.height
        )
        return (1 - crop.height) > (1 - crop.width)
    }

    /// Surface a failure raised by the sheet (a temp-file write, a render throw)
    /// through the same status line as the model's own.
    func setFailure(_ message: String) { phase = .failed(message) }

    #if DEBUG
    /// DEBUG ONLY — stand in for the two network reads so the export sheet can be
    /// looked at without a running local stack, and so BOTH tiers can actually be
    /// screenshotted (offline, membership is nil, which resolves to the member
    /// treatment — so the free tier would otherwise never be visible).
    ///
    /// `SIMCTL_CHILD_TOVIS_DEBUG_EXPORT_TIER=free|member`. It seeds through the
    /// real decoders rather than faking the model's state, so what a screenshot
    /// shows went through the same path a server response would.
    func applyDebugIdentity(tier: String, handle: String) {
        identityLoaded = true
        let unbranded = tier != "free"
        let plan = unbranded ? "pro" : "free"
        let membershipJSON = Data("""
        {"planKey":"\(plan)","rawPlanKey":"\(plan)","status":"active","compPlanKey":null,
        "compUntil":null,"entitlements":[],"exportsUnbranded":\(unbranded),
        "currentPeriodEnd":null,"cancelAtPeriodEnd":false,"trialEndsAt":null,
        "hasBillingAccount":true}
        """.utf8)
        let profileJSON = Data("""
        {"id":"debug","businessName":"Tori Studio","handle":"\(handle)","bio":null,
        "location":null,"avatarUrl":null,"professionType":null,"nameDisplay":null,
        "isPremium":false}
        """.utf8)
        membership = try? JSONDecoder().decode(ProMembership.self, from: membershipJSON)
        profile = try? JSONDecoder().decode(ProMyProfile.self, from: profileJSON)
    }
    #endif

    /// Long-edge budget for a source about to be cropped into a 1920-tall canvas.
    /// Generous enough that a 9:16 crop of a wide source still oversamples, small
    /// enough that two of them fit comfortably in memory.
    nonisolated private static let exportMaxPixel: CGFloat = 3000
}
