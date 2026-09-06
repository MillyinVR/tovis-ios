// P3 — what the consult camera does with a frame after the shutter, as pure
// geometry and pure policy: which camera a shot opens on, where the guide box
// is drawn, and what rectangle of the captured still is uploaded.
//
// Nothing here touches AVFoundation, Vision, UIKit or the network. The Vision
// MEASUREMENT is `VisionDetect.eyeAndBrowBand` and the pixels are cut in
// `ConsultPhotoPreparation`; this file only decides. That split is what lets the
// bands be tested — and tuned on hardware — without a camera.
//
// ⚠️ This file imports TovisKit, so it must never be added to
// scripts/coach-tuning-bench/run.sh's source list (that tool compiles the
// perception sources standalone, without TovisKit).

import CoreGraphics
import Foundation
import TovisKit

nonisolated enum ConsultCaptureCrop {

    // MARK: - Which camera a shot opens on

    /// The camera a shot opens on the FIRST time the client takes it.
    ///
    /// The consult's premise is a client alone with her phone (Part 2, "book at
    /// the spark"), so the front camera is the default: it is the only one she
    /// can compose in. The exception is the hair pack's four views, which are of
    /// the back, crown and sides of her own head — the front camera physically
    /// cannot see them.
    ///
    /// An unknown key (a pack added after this build shipped) gets `.front`
    /// along with everything else. That is the deliberate direction to be wrong
    /// in: a self-shot opened on the rear camera shows the client a picture of
    /// her room, whereas a hair shot opened on the front camera shows her her own
    /// face — one of those reads as broken, the other as a camera she should
    /// flip. And she can, in one tap, and it is remembered from then on.
    static func defaultCamera(for shotKey: ConsultCaptureShotKey) -> ConsultCameraPosition {
        switch shotKey {
        case .hairBack, .hairLeft, .hairRight, .hairCrown:
            return .rear
        default:
            return .front
        }
    }

    // MARK: - The guide box

    /// The box drawn over the preview for a `TIGHT_CROP` shot, upright and
    /// normalized top-left within the capture frame. Nil for `FULL_VIEW`, which
    /// is composed and uploaded as framed.
    ///
    /// It is a COMPOSITION aid and the auto-crop's fallback, not the crop: when
    /// the landmarks read succeeds the band comes from the client's actual eyes
    /// and brows, which is tighter and truer than any fixed box. The box is what
    /// the crop falls back to when there is nothing to measure.
    ///
    /// Numbers approved as PROPOSALS (Tori, 2026-09-06) — tune on hardware.
    static func guideBox(for shot: ConsultCaptureShot) -> CGRect? {
        guard shot.framingOrDefault == .tightCrop else { return nil }
        switch shot.key {
        case .eyesCloseup:
            // A wide band across the face: both brows and both eyes, edge to
            // edge, which is what `eyes_closeup`'s acceptance rule asks for.
            return CGRect(x: 0.06, y: 0.30, width: 0.88, height: 0.28)
        default:
            // `area_closeup` and any future tight crop: a roughly square box on
            // the middle of the frame. There is no face to measure here, so this
            // box IS the crop.
            return CGRect(x: 0.10, y: 0.22, width: 0.80, height: 0.56)
        }
    }

    // MARK: - The crop plan

    /// Where a crop came from — carried so the camera can say the honest thing
    /// when it had nothing to measure, and so telemetry can tell a landmark
    /// crop from a fallback one.
    enum Source: Equatable, Sendable {
        case landmarks
        case guideBox
    }

    enum Plan: Equatable, Sendable {
        /// Upload the frame as taken.
        case fullFrame
        /// Upload this rectangle of it (upright, normalized top-left).
        case crop(CGRect, source: Source)
    }

    /// What to upload for this shot, given what Vision could read on the still.
    ///
    /// `landmarkBand` is `VisionDetect.eyeAndBrowBand`'s RAW union — nil when
    /// there was no face, or a face with no eye/brow landmarks.
    static func plan(for shot: ConsultCaptureShot, landmarkBand: CGRect?) -> Plan {
        // An unknown framing resolves to FULL_VIEW (`framingOrDefault`), so a
        // pack this build has not seen uploads exactly as every pre-P3 build did.
        guard shot.framingOrDefault == .tightCrop,
              let box = guideBox(for: shot) else { return .fullFrame }

        // `area_closeup` has no face in it by definition, so landmarks are not
        // just absent — they would be meaningless if something else in frame
        // produced them. The box is the crop.
        guard shot.key == .eyesCloseup else { return .crop(box, source: .guideBox) }

        guard let raw = landmarkBand, raw.width > 0, raw.height > 0 else {
            return .crop(box, source: .guideBox)
        }
        return .crop(band(fromEyeAndBrow: raw), source: .landmarks)
    }

    /// Grow the raw eye+brow union into a photographable band.
    ///
    /// The union is the landmarks and nothing more: it stops at the outer brow
    /// hairs and the lower lid. Uploading it would hand the gate a strip with the
    /// brows clipped at their own edge, which is the `VIEW_MISMATCH` this whole
    /// change exists to stop. So it is padded — more below than above, because
    /// lashes sit below the lower lid and the gate is told to read them.
    ///
    /// Padding is a fraction of the band's OWN size, not of the frame, so it
    /// scales with how close the client held the phone.
    ///
    /// Fractions approved as PROPOSALS (Tori, 2026-09-06) — tune on hardware.
    static func band(fromEyeAndBrow raw: CGRect) -> CGRect {
        let padX = raw.width * 0.18
        let padTop = raw.height * 0.35
        let padBottom = raw.height * 0.45
        let padded = CGRect(
            x: raw.minX - padX,
            y: raw.minY - padTop,
            width: raw.width + padX * 2,
            height: raw.height + padTop + padBottom
        )
        return clampedToFrame(padded)
    }

    /// Keep a rect inside the unit frame without changing its shape where it
    /// fits: slide it in first, and only shrink it if it is genuinely bigger
    /// than the frame. A plain `intersection` would silently narrow a band that
    /// merely sat too far left.
    static func clampedToFrame(_ rect: CGRect) -> CGRect {
        let width = min(rect.width, 1)
        let height = min(rect.height, 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Which camera the consult capture screen is using. A two-case enum rather
/// than `AVCaptureDevice.Position` so the policy above, its tests and the
/// persistence below need no AVFoundation.
nonisolated enum ConsultCameraPosition: String, Sendable, Equatable, CaseIterable {
    case front
    case rear
}

/// The client's last camera choice, per shot.
///
/// Per SHOT, not one global setting: the same client wants the front camera for
/// her eyes and the rear one for the back of her head, and making her flip twice
/// every time is the kind of small tax that ends a consult. Stored in
/// `UserDefaults` like the pro camera's own persisted capture settings —
/// a preference, not consult data, so it is not vault-bound and does not travel.
nonisolated enum ConsultCameraMemory {
    static let defaultsPrefix = "tovis.consult.camera."

    static func key(for shotKey: ConsultCaptureShotKey) -> String {
        defaultsPrefix + shotKey.rawValue
    }

    /// The camera to open on: what she chose last time for THIS shot, else the
    /// policy default. A stored value this build cannot parse is ignored rather
    /// than trusted.
    static func camera(
        for shotKey: ConsultCaptureShotKey,
        defaults: UserDefaults = .standard
    ) -> ConsultCameraPosition {
        guard let raw = defaults.string(forKey: key(for: shotKey)),
              let remembered = ConsultCameraPosition(rawValue: raw) else {
            return ConsultCaptureCrop.defaultCamera(for: shotKey)
        }
        return remembered
    }

    static func remember(
        _ position: ConsultCameraPosition,
        for shotKey: ConsultCaptureShotKey,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(position.rawValue, forKey: key(for: shotKey))
    }
}
