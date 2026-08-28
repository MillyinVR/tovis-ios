// Pro session photo capture — the custom camera for BEFORE/AFTER session photos.
// Phase A: live preview + shutter → upload (presign→PUT→confirm) + a strip of
// what you've shot this session. The on-device AI coach (overlays, readiness
// ring, pose templates) layers onto this preview in Phase B.
import AVFoundation
import PhotosUI
import SwiftUI
import TovisKit

struct ProCapturePhotosView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Where these shots go — a booking's phase, or the practice library. The
    /// camera, coach, guide and calibration are identical either way; the
    /// destination is only what the shoot OWES. See `ProCameraDestination`.
    let destination: ProCameraDestination
    /// Base service name (e.g. "Balayage") — selects the ShotGuide, and gives
    /// the coach the booking's own word for what's in the frame. Nil → generic.
    var serviceName: String? = nil
    /// The client's stored full name, so the coach can say "Center Maya"
    /// instead of "Center them". Nil when practising, or when the
    /// booking has no usable name — see `CoachBookingVocabulary`.
    var clientName: String? = nil
    /// The booking's salon location id and mode ("SALON"/"MOBILE") — the
    /// stable, non-GPS key the coach's room memory hangs on (P4.1). Nil/MOBILE
    /// means this shoot has no room to remember; see `CoachRoomMemory`.
    var locationId: String? = nil
    var locationType: String? = nil
    /// "Before" photos to ghost as onion-skin while shooting AFTER, so the pairs
    /// line up. Empty for the BEFORE phase (nothing to match yet).
    var referenceURLs: [URL] = []
    /// Photos this phase already has on the server (from an earlier camera open).
    /// Counts toward the one-photo requirement — reopening the camera on a phase
    /// that's already covered must not act like nothing has been shot.
    var alreadyCaptured: Int = 0

    /// The phase being shot — `.other` when practising.
    private var phase: MediaPhase { destination.phase }
    /// The namespace the byte vault, the clip vault, and this shoot's stored
    /// white-balance / card calibration key on. Practice has its own, so a
    /// stranded practice photo is never re-offered to a booking's queue and a
    /// calibration solved at home never re-colours a client's before/after.
    private var custodyScope: String { destination.custodyScope }

    @State private var camera = CameraController()
    /// Torch state. `torchOn` drives `camera.setTorch` via onChange — the device
    /// write stays on the session queue, the toggle stays a plain SwiftUI Bool.
    @State private var torchOn = false
    /// Whether a pinch gesture is in progress (anchors the zoom once per
    /// gesture). Zoom values go straight to the controller — no @State mirror,
    /// so no bookkeeping reset can ever flow back through as a zoom write.
    @State private var pinchActive = false
    /// Onion-skin (before/after matching) state.
    @State private var onionEnabled = true
    @State private var onionOpacity: Double = 0.35
    @State private var referenceIndex = 0
    /// The directed shot list for this service + progress through it.
    @State private var guide: ShotGuide = .generic
    @State private var currentStepID: String?
    @State private var completedStepIDs: Set<String> = []
    /// The standard (built-in) guide for this service — what "guide" returns
    /// to when the pro switches off a trending pack.
    @State private var standardGuide: ShotGuide = .generic
    /// Trending shot packs matching this service (server-driven, fetched once
    /// per camera open; empty on failure → standard guides only).
    @State private var trendingPacks: [ProShotPack] = []
    /// The active trending pack id (nil = the standard set).
    @State private var activePackID: String?
    /// "Match a look": a pro-picked reference photo measured (on-device) into
    /// a one-shot guided brief. Non-nil = it drives the guide, the ghost, and
    /// the light target.
    @State private var matchLook: ReferenceLook?
    @State private var showLookPicker = false
    @State private var lookPickerItem: PhotosPickerItem?
    @State private var analyzingLook = false
    /// Phase D AI enhance: the matched look is being enriched by Claude (in
    /// flight) / is waiting on the pro's first-use consent.
    @State private var enhancingLook = false
    @State private var pendingEnhanceLook: ReferenceLook?
    /// Which AI direction line the pro is on (tap the card to advance).
    @State private var lookDirectionIndex = 0
    /// Tap-to-focus reticle position (preview space) + a token to time its fade.
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    /// Guided auto-capture's arming rule (fires once per stabilization — must
    /// drop out of "ready" and settle again before the next auto-shot, OR come
    /// back from a burst that kept nothing). The state machine lives in
    /// `GuidedCaptureArm` so the "silently stalls after a rejected burst" case
    /// is a unit test rather than a shape you have to trace through handlers.
    @State private var autoArm = GuidedCaptureArm()
    /// A steady-ready auto-capture was wanted but a transient gate (upload in
    /// flight, review sheet, calibration, recording, interrupted session) blocked
    /// it. Re-fire when the gate clears instead of waiting for the subject to
    /// break the hold and re-stabilize — which may never happen if they hold still.
    @State private var guidedCaptureQueued = false
    /// Showing the white-balance calibration target (fill it with a neutral surface).
    @State private var calibrating = false
    /// Within calibration: card mode (scan the printed calibration card —
    /// color matrix + exposure anchor) vs towel mode (WB only).
    @State private var cardMode = false
    /// A card scan is in flight (two captures + solve).
    @State private var scanningCard = false
    /// Which physical reference the card scan targets — the printed Tovis card by
    /// default. DEBUG builds can switch to a standard ColorChecker Classic chart
    /// (e.g. a ColorChecker Passport), whose factory-known colors let the color
    /// pipeline be validated against a trustworthy reference with no printing.
    @State private var scanTarget: CalibrationTarget = .tovisCardV0
    /// The active card-solved chromatic correction, baked into every captured
    /// JPEG before upload. Persisted per booking (before + after match).
    @State private var cardMatrix: ColorMatrix3x3?
    /// One-line calibration feedback ("Card locked — …" / "Couldn't read…").
    @State private var calibrationStatus: String?
    /// Scene warmth at card-scan time — the drift detector compares the live
    /// warmth against this to notice "the light changed since calibration."
    @State private var calibrationWarmth: Double?
    /// When the live warmth first drifted past tolerance (nil = not drifting).
    @State private var driftSince: Date?
    /// The re-scan nudge was acted on/shown — don't nag again this session.
    @State private var driftDismissed = false
    /// Local thumbnails of shots taken this session (newest first) — shown
    /// instantly from the captured bytes, no network round-trip.
    @State private var captured: [CapturedShot] = []
    /// A captured shot opened full-screen (tap the captured strip).
    @State private var viewingMedia: FullscreenMedia?
    /// The app-level upload queue — the ONLY thing that owes the server a photo.
    ///
    /// 🔴 This view used to own that queue in `@State`, which is precisely why
    /// nothing uploaded: closing the camera destroyed it, backgrounding the app
    /// killed its transfers, and every shot raced every other shot. Custody now
    /// lives in `SessionUploadQueue`, outlives this screen, and survives a
    /// relaunch. Read here only to SHOW what's outstanding — never to gate the
    /// shutter on it.
    private var uploads: SessionUploadQueue { .shared }

    /// `uploading` covers only the fast, on-device span of a shot — capture,
    /// QC, thumbnail, the durable local write. It gates the shutter, so it
    /// must never include the network: a shot is "done" the moment it's
    /// safely on disk, not once the server has it.
    @State private var uploading = false

    /// Presents the keep-or-discard card for refused photos.
    @State private var showTerminalDecision = false
    /// Re-entry guard while refused photos are being written to the library, so a
    /// second tap can't double-save (and then double-release) the same bytes.
    @State private var savingToLibrary = false
    /// Recorded clips whose upload failed — kept safe in the ClipVault (never
    /// tmp), retried on demand. Tuple carries the phase so a BEFORE clip
    /// stranded by a crash still lands in BEFORE when swept up later.
    @State private var failedClips: [(url: URL, phase: MediaPhase)] = []
    /// Clip uploads currently running in the background ("Saving clip…" pill).
    @State private var savingClips = 0
    @State private var errorMessage: String?

    private struct CapturedShot: Identifiable {
        let id = UUID()
        let image: UIImage
        /// The vault file this shot is waiting on the server for — nil once
        /// upload is confirmed (or if the local write itself failed, in which
        /// case there's nothing left to track). Backs the pending-sync badge.
        var custodyURL: URL?
    }

    /// A manual shot the photographer check flagged — held for the pro's
    /// keep-or-retake call instead of silently entering the portfolio.
    @State private var pendingRetake: PendingRetake?
    private struct PendingRetake: Identifiable {
        let id = UUID()
        let data: Data
        /// Canonical QC reason (Calm Mentor text) — the RetakeDialog message
        /// renders this through `.retakeConfirm` at display time, docs/design/
        /// camera-personality-packs.md §4. Deliberately the CANONICAL reason,
        /// not a pack-flourished one — `.retakeConfirm`'s own copy is where
        /// this utterance's one flourish happens.
        let reason: String
        /// Whether keeping this shot should also complete the current guided step
        /// — carried from the capture decision so a kept-anyway shot advances the
        /// guide exactly as an accepted one would (and a freeform grab doesn't).
        let advanceGuide: Bool
        /// Subject focal (camera C6) computed on this still — carried so a
        /// kept-anyway shot uploads with the same smart-crop hint as an accepted one.
        let focal: MediaFocalPoint?
        /// The moment the shutter actually fired — sampled at `capturePhoto()`,
        /// carried through the QC/retake decision so a kept-anyway shot's
        /// attestation reflects when it was TAKEN, not when the pro tapped "keep".
        let capturedAt: Date
    }

    /// Each "before" reference, measured — the targets the AFTER shoot matches
    /// so the transformation compare is credible: same angle via onion-skin,
    /// same LIGHT and same FRAMING via this.
    @State private var referenceStamps: [URL: BeforeShotStamp] = [:]
    /// Brief white flash on a successful capture (shutter confirmation).
    @State private var flash = false

    // AI photographer (Phase B1): live coach + how-it-guides toggles.
    @State private var settings = CoachSettings()
    @State private var coach: CoachEngine?
    @State private var showSettings = false
    /// DEBUG tuning console (rides over the live camera; not a reviewing state).
    @State private var showTuning = false
    #if DEBUG
    /// The most recent card-scan read-out (pass or fail) for the DEBUG diagnostics
    /// sheet — the signal that turns tuning a target's geometry into a tight loop.
    @State private var lastDiagnostics: CalibrationDiagnostics?
    @State private var showingDiagnostics = false
    #endif
    @State private var showBestShots = false
    /// Guards exit while the coach has auto-harvested best shots the pro hasn't
    /// reviewed yet — otherwise tapping Done silently discards them.
    @State private var showExitConfirm = false

    // MARK: The three drawers (the subtraction pass's disclosure model)
    /// Swipe the coach line up → the seven dimensions (was: seven status pills).
    @State private var showDimensions = false
    /// Tap ⋯ → the tools tray (was: eyedropper + AE/AF + gear in the header).
    @State private var showTools = false
    /// The practice library, reached from the tools tray while practising.
    @State private var showPracticeLibrary = false
    /// PRACTICE ONLY — keep a copy of each kept shot in the pro's own camera
    /// roll. Off by default and remembered between shoots.
    ///
    /// Deliberately NOT offered in a session: a client's before/after is their
    /// photo, and quietly copying it to the pro's phone is not a toggle to slip
    /// into a tools tray. (The refused-photo escape hatch is a different thing —
    /// there the alternative is losing the bytes entirely.)
    @AppStorage("tovis.camera.practice.saveToPhotos") private var savePracticeToPhotos = false
    /// Tap the step chip → the guide sheet (was: the eight-part guide bar).
    @State private var showGuideSheet = false

    // MARK: The lane's transients
    // Two lane tiers expire rather than persist: a step change announces the new
    // shot for a beat, and a light-match result confirms itself. Both fall back
    // to the coach tip. Each carries a token so a newer transient supersedes an
    // older one's pending expiry instead of being cut short by it.
    @State private var stepTransient: String?
    @State private var stepTransientToken = 0
    @State private var lightTransient: (text: String, ok: Bool)?
    @State private var lightTransientToken = 0
    /// The coach's answer to a tip the pro just retired, inside its transient
    /// window (P4.1).
    @State private var roomDismissTransient: String?
    @State private var roomDismissToken = 0
    /// Whether that confirmation still has a tip to put back.
    @State private var roomDismissUndoable = false
    /// WHEN the before/after verdict reaches the lane — the light half on a
    /// change of its verdict (exactly as it fires today) and the PAIR on the
    /// transition into parity, once (P5.3). Pure and clock-injected, so the
    /// "is this a nag?" question is settled by `BeforePairAnnouncerTests`.
    @State private var pairAnnouncer = BeforePairAnnouncer()
    /// Times out the error line so one failure can't hold the lane forever.
    @State private var errorToken = 0
    /// …except for the one message that isn't backed by any other state.
    @State private var errorSticky = false
    /// The all-steps-done card is a decision point shown once; "Keep shooting"
    /// dismisses it and the lane carries the set-complete line from then on.
    @State private var setCompleteDismissed = false
    /// The requirement-met card ("that's the one you need") was answered. It also
    /// retires itself on the next shot — a pro who kept shooting has answered it.
    @State private var requirementCardDismissed = false
    /// Photos kept in THIS camera session (kept, not necessarily uploaded yet).
    @State private var keptThisSession = 0

    // MARK: "Choose from library instead"
    /// The dead-end states' second door — see `CameraLibraryImport`.
    @State private var showLibraryPicker = false
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var importingLibrary = false
    /// A just-recorded clip awaiting frame-by-frame review (nil = none).
    @State private var scrubClip: ScrubClip?

    private struct ScrubClip: Identifiable, Equatable { let url: URL; var id: String { url.absoluteString } }

    /// True while a selection/review surface is up (best-shots tray, frame
    /// scrubber, settings, the tools tray, the guide sheet, or either photo
    /// picker) — the live camera pauses so it isn't still capturing +
    /// auto-harvesting while the pro picks photos.
    ///
    /// The dimensions drawer is deliberately NOT here: it's a live read-out of
    /// the same signals the coach line shows, opened precisely to watch a number
    /// move, and the design says "live while open — swipe down or shoot to
    /// dismiss." Pausing the camera behind it would freeze what it exists to show.
    private var isReviewing: Bool {
        showBestShots || showSettings || showLookPicker || showTools
            || showGuideSheet || showLibraryPicker || showPracticeLibrary
            || scrubClip != nil
    }

    /// The coach reads the frame as good-to-shoot (green ring).
    private var isReady: Bool { coach?.isReady ?? false }

    /// Onion-skin is on, and there's something to ghost — a "before" (AFTER
    /// phase) or an active match-look reference (which takes precedence).
    private var showOnion: Bool {
        onionEnabled && (matchLook != nil || !referenceURLs.isEmpty)
    }
    private var currentReferenceURL: URL? {
        guard !referenceURLs.isEmpty else { return nil }
        return referenceURLs[min(max(referenceIndex, 0), referenceURLs.count - 1)]
    }

    // The view is assembled in three layers (stack → lifecycle → presentation)
    // because one flat modifier chain exceeds what the type-checker resolves
    // in reasonable time.
    var body: some View {
        presentationLayer
    }

    /// The camera stack itself.
    private var cameraStack: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .denied:
                deadEnd(.permissionDenied)
            case let .failed(message):
                deadEnd(.cameraFailed(message))
            default:
                cameraUI
            }

            if flash {
                Color.white.ignoresSafeArea().transition(.opacity)
            }
        }
    }

    /// Lifecycle wiring: startup, teardown, and the live onChange reactions.
    private var lifecycleLayer: some View {
        cameraStack
        .task {
            standardGuide = ShotGuide.resolve(forServiceNamed: serviceName)
            if activePackID == nil { guide = standardGuide }
            if currentStepID == nil { currentStepID = guide.steps.first?.id }
            let engine = coach ?? CoachEngine(settings: settings)
            coach = engine
            // What this shoot is OF, in the booking's words. Practice passes
            // neither, so it resolves to `.empty` and the coach keeps its
            // canonical lines — there is no client to name there.
            engine.bookingVocabulary = CoachBookingVocabulary(
                serviceName: serviceName, clientFullName: clientName)
            // What this ROOM has already been told. Nil for practice and for a
            // mobile shoot — neither has a room that outlives the booking —
            // and the coach then behaves exactly as it always has.
            //
            // Built ONCE per engine per room, not once per `.task`. This task
            // runs again every time the view comes back from a fullScreenCover
            // (the frame scrubber, the best-shots tray) with the SAME engine,
            // and a fresh memory would reset its "already counted this shoot"
            // set — so one shoot would be counted twice and the offer would
            // arrive before the pro had really met the tip three times.
            if engine.roomMemory?.locationId != locationId {
                engine.setRoomMemory(CoachRoomMemory(locationId: locationId,
                                                     locationType: locationType))
            }
            // Re-arm CoreMotion: the frame scrubber is a fullScreenCover, which
            // fires this view's onDisappear → engine.stop(); on return the
            // engine is reused, so the level stream must be restarted here or
            // the horizon (and LevelCoach) freeze at stale tilt.
            engine.start()
            // The photographer meters for the face: feed the coach's face
            // detection into exposure so "too dark"/"backlit" fix themselves.
            #if DEBUG
            engine.onFaceCenter = { [weak camera = camera] center in
                camera?.setFaceExposure(center: center)
                // The crosshair itself derives from the controller's
                // `lastFaceMeterDevicePoint`, which nils when no face —
                // nothing to mirror here.
            }
            #else
            engine.onFaceCenter = { [weak camera = camera] center in
                camera?.setFaceExposure(center: center)
            }
            #endif
            engine.analyzer.setExpectations(activeExpectations)
            engine.analyzer.setCropGuide(settings.showCropGuide ? PublishCrop.feedRect : nil)
            // Persist gray-card WB per booking: the AFTER shoot re-applies the
            // BEFORE's calibration automatically (one card, one session).
            camera.onWhiteBalanceLocked = { r, g, b in
                UserDefaults.standard.set([r, g, b], forKey: wbDefaultsKey)
            }
            // A calibration stored by a build that let a non-finite gain through
            // is unusable forever — drop it so this shoot just runs on automatic
            // white balance instead of retrying it every launch.
            camera.onWhiteBalanceUnusable = {
                UserDefaults.standard.removeObject(forKey: wbDefaultsKey)
            }
            // A take that ended BY ITSELF — the 60s cap firing mid-shoot is the
            // normal case; nobody called stopRecording, so nothing awaited it.
            // The file is complete and KEPT: stash it into the vault and upload
            // it exactly like an awaited stop. A late delegate arriving after
            // the stop-watchdog lands here too — its awaiter gave up, but the
            // take is real; a stashed file does not conflict with a live
            // recording, so it is kept even if take 2 has already started.
            // (Phase is fixed by the screen's destination — see below.)
            camera.onUnawaitedClipFinished = { url in
                let stored = ClipVault.stash(url, bookingId: custodyScope, phase: phase)
                uploadClip(stored, phase: phase)
            }
            await camera.start(frameDelegate: engine.analyzer)
            if !camera.whiteBalanceCalibrated,
               let gains = UserDefaults.standard.array(forKey: wbDefaultsKey) as? [Double],
               gains.count == 3 {
                camera.applyWhiteBalanceGains(r: gains[0], g: gains[1], b: gains[2])
            }
            // Same for a card calibration (matrix + exposure anchor [+ the
            // scan-time warmth the drift detector compares against]) — but only
            // restore it when the stored calibration was solved against the
            // currently-active target; a matrix from a different reference would
            // silently mis-correct every photo.
            if cardMatrix == nil,
               let data = UserDefaults.standard.data(forKey: cardCalDefaultsKey),
               let record = (try? JSONDecoder().decode(StoredCardCalibration.self, from: data))?
                   .restorable(for: scanTarget),
               let matrix = record.colorMatrix {
                cardMatrix = matrix
                camera.setCalibrationExposureBias(Float(record.exposureBiasEV))
                calibrationWarmth = record.calibrationWarmth
            }
            // Stamp each "before" reference so the AFTER can match its light
            // and its framing.
            if referenceStamps.isEmpty, !referenceURLs.isEmpty {
                await loadReferenceStamps()
            }
            // Trending shot packs for this service (server-driven; silent
            // failure → the standard guides carry the shoot).
            if trendingPacks.isEmpty,
               let response = try? await session.client.proCamera.shotPacks() {
                trendingPacks = ShotGuide.matchingPacks(response.packs, serviceName: serviceName)
            }
            // Re-queue clips stranded by a crash/offline exit for this booking.
            // (.task re-fires after every fullScreenCover round-trip, so skip
            // anything already queued or in flight.)
            let queued = Set(failedClips.map(\.url))
            let stranded = ClipVault.strandedClips(bookingId: custodyScope)
                .filter { !queued.contains($0.url) }
            if !stranded.isEmpty { failedClips.append(contentsOf: stranded) }

            // Photos are NOT swept here any more — the durable queue rebuilds
            // itself from the byte vault and does not need this view to exist.
            // Just nudge it: it drains on its own from the app root, but
            // entering the camera is a natural moment to try again (the pro has
            // often just walked somewhere with signal).
            Task { await uploads.drain() }

            #if DEBUG
            // Screenshot-only hooks for verifying the offline-queue UI on a
            // simulator with no camera and no tap automation (same reasoning as
            // `TOVIS_DEBUG_OPEN_PRACTICE_CAMERA` in `ProMainTabView`): seed a
            // pending-sync thumbnail, and/or force the tools drawer open — neither
            // is otherwise reachable here without a live capture or a tap.
            if ProcessInfo.processInfo.environment["TOVIS_DEBUG_SEED_PENDING_PHOTO"] == "1",
               let placeholder = UIImage(systemName: "photo.fill") {
                captured.insert(
                    CapturedShot(image: placeholder,
                                 custodyURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                     .appendingPathComponent("debug-pending.jpg")),
                    at: 0
                )
            }
            if ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_TOOLS"] == "1" {
                showTools = true
            }
            #endif
        }
        // Drop the pending-sync badge from any thumbnail whose bytes the queue
        // has since released. The queue confirms uploads long after this view
        // stopped driving them (and sometimes while it isn't on screen at all),
        // so the badge follows the byte vault — the actual source of truth for
        // "does the server still owe this photo" — rather than a callback.
        // Keep the coach judging "ready for THIS shot" — expectations follow the
        // current guided step (and clear for freeform / all-done shooting).
        .onChange(of: activeExpectations) { _, expectations in
            coach?.analyzer.setExpectations(expectations)
        }
        // Watch for the room's light drifting away from the card calibration.
        .onChange(of: coach?.frameWarmth ?? 0) { _, warmth in
            updateDrift(warmth)
        }
        // A picked "match a look" photo → measure it on-device into the brief.
        .onChange(of: lookPickerItem) { _, item in
            guard let item else { return }
            lookPickerItem = nil
            Task {
                analyzingLook = true
                defer { analyzingLook = false }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let look = await ReferenceLookAnalyzer.analyze(data) else {
                    errorMessage = "Couldn’t read that photo — try a different one."
                    return
                }
                selectMatchLook(look)
                maybeEnhanceLook(look)
            }
        }
        .onDisappear {
            camera.stop(); coach?.stop()
            // Deliberately NOT stopping any upload machinery: leaving this
            // screen must not stop photos uploading. That was the bug.
        }
        // (Clip files are owned by the ClipVault from the moment recording
        // stops — nothing here may delete them; the vault releases each file
        // only after its upload is confirmed.)
        // Pause the live camera while the pro is reviewing/picking shots or in
        // settings — otherwise it keeps capturing, scoring, and auto-harvesting
        // behind the sheet. Resume when they return to shooting. A rolling
        // recording is stopped AND SAVED — interrupting a take must never
        // discard it.
        .onChange(of: isReviewing) { _, reviewing in
            if reviewing {
                if camera.isRecording { Task { await stopRecordingAndSave(review: false) } }
                // A stopped session kills the torch at the OS level; dropping
                // the flag re-fires the torch onChange so the button tells the
                // truth (and the write itself is an idempotent no-op).
                torchOn = false
                camera.stop()
            } else {
                camera.resume()
                retryGuidedIfReady()
            }
        }
        // A transient gate that blocked a queued auto-capture just cleared — if
        // the subject is still held steady, take the shot now instead of waiting
        // for a fresh stabilization edge that may never come.
        .onChange(of: uploading) { _, busy in if !busy { retryGuidedIfReady() } }
        .onChange(of: calibrating) { _, active in if !active { retryGuidedIfReady() } }
        .onChange(of: camera.isRecording) { _, recording in if !recording { retryGuidedIfReady() } }
        .onChange(of: camera.status) { _, status in if status == .ready { retryGuidedIfReady() } }
        // Ghost the "before" that matches the current guided shot (before/after
        // were shot in the same order), so the pair lines up. Manual cycle overrides.
        .onChange(of: currentStepID) {
            if !referenceURLs.isEmpty {
                referenceIndex = min(currentStepIndex, referenceURLs.count - 1)
            }
            // The photographer calls the next shot.
            if settings.speak, !allStepsDone, let step = currentStep {
                let voice = settings.personality.voice
                let renderedHint = CoachVoiceRenderer.render(
                    .shotStepHint, fallback: step.hint,
                    ctx: CoachPhraseContext(subjectNoun: step.title, detail: step.hint), voice: voice) ?? step.hint
                let fallback = "Next, the \(step.title). \(step.hint)"
                let line = CoachVoiceRenderer.render(
                    .shotStepAnnounce, fallback: fallback,
                    ctx: CoachPhraseContext(subjectNoun: step.title, detail: renderedHint), voice: voice) ?? fallback
                coach?.announce(line)
            }
            // …and the lane says it for a beat before handing back to the coach.
            announceStepInLane()
        }
        // The before/after verdict changed — confirm it (or name the fix)
        // briefly, then get out of the coach tip's way. `BeforePairAnnouncer`
        // owns WHEN: the light half on a change of its verdict, and the PAIR
        // once, on the transition into parity. A steady state never
        // re-announces itself, and dropping out of parity says nothing.
        //
        // ONE handler on the whole verdict rather than two on its parts: the
        // light half and the framing half can land on the same frame, and two
        // handlers racing to speak about it is how the lane ends up saying the
        // good news twice.
        .onChange(of: beforePair) { _, verdict in
            guard let verdict,
                  let announce = pairAnnouncer.announcement(for: verdict, now: Date())
            else { return }
            let voice = settings.personality.voice
            let rendered = CoachVoiceRenderer.render(
                announce.moment, fallback: announce.label,
                ctx: CoachPhraseContext(subjectNoun: announce.noun),
                voice: voice) ?? announce.label
            announceLightInLane(rendered, ok: announce.ok)
        }
        // A different BEFORE is a different pair, so recognition re-arms — the
        // guided set moving to the next step, or the pro cycling the
        // references by hand. It does NOT re-arm the re-crossing floor, so
        // cycling cannot be used to fire the line over and over.
        .onChange(of: currentReferenceURL) { _, _ in pairAnnouncer.newPairing() }
        // An error line used to have its own permanent row, so it could sit there
        // forever harmlessly. In the lane it outranks the coach, so it has to let
        // go — otherwise one failed capture silences coaching for the rest of the
        // shoot.
        //
        // Safe to expire because every message here is either transient advice
        // ("try again", "holding for another try") or SHADOWED by a durable
        // queue row that outranks it and doesn't expire — a failed upload is
        // still counted by `SessionUploadQueue`, a failed library save still has
        // its refused photos. The one exception sets `errorSticky` (see
        // `finalize`'s vault-write failure branch): that photo is genuinely
        // gone, and nothing else on screen says so.
        .onChange(of: errorMessage) { _, message in
            guard message != nil else { errorSticky = false; return }
            guard !errorSticky else { return }
            errorToken += 1
            let token = errorToken
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if errorToken == token, !errorSticky { errorMessage = nil }
            }
        }
        // Guided auto-capture: re-arm when the shot drops out of "ready", and shoot
        // once it has held good + steady (isSteadyReady) while armed.
        .onChange(of: coach?.isReady ?? false) { _, ready in
            autoArm.readinessChanged(ready: ready)
        }
        .onChange(of: coach?.isSteadyReady ?? false) { _, steady in
            if autoArm.shouldFire(steady: steady) { attemptGuidedCapture() }
        }
        // Judge composition inside the crop the pro is composing to, so the
        // frame the coach approves is the frame that ships.
        .onChange(of: settings.showCropGuide) { _, on in
            coach?.analyzer.setCropGuide(on ? PublishCrop.feedRect : nil)
        }
    }

    /// Sheets, covers, and dialogs over the live camera.
    private var presentationLayer: some View {
        lifecycleLayer
        // "Match a look": pick any photo (screenshot of a viral post, a shot
        // they admire) — measured on-device into a guided brief.
        .photosPicker(isPresented: $showLookPicker, selection: $lookPickerItem, matching: .images)
        // Phase D first-use consent — the ONE place a reference photo leaves
        // the device. Declining turns the enhance setting off (re-enable in
        // coaching settings); the measured on-device brief keeps working.
        .confirmationDialog("Enhance with AI?", isPresented: Binding(
            get: { pendingEnhanceLook != nil },
            set: { if !$0 { pendingEnhanceLook = nil } }
        ), titleVisibility: .visible) {
            Button("Enhance photo") {
                CameraVisionConsent.granted = true
                if let look = pendingEnhanceLook { runEnhanceLook(look) }
                pendingEnhanceLook = nil
            }
            Button("Not now", role: .cancel) {
                settings.aiEnhanceLooks = false
                pendingEnhanceLook = nil
            }
        } message: {
            Text(CameraVisionConsent.lookDisclosure)
        }
        // "Choose from library instead" — the dead-end states' second door.
        // Multi-select: a pro rescuing a session usually has more than one shot
        // to add, and re-opening the picker per photo is its own dead end.
        .photosPicker(isPresented: $showLibraryPicker, selection: $libraryItems,
                      maxSelectionCount: 10, matching: .images)
        .onChange(of: libraryItems) { _, items in
            guard !items.isEmpty else { return }
            libraryItems = []
            Task { await importFromLibrary(items) }
        }
        .onChange(of: torchOn) { _, on in
            camera.setTorch(on)
        }
        .sheet(isPresented: $showSettings) {
            #if DEBUG
            CoachSettingsSheet(settings: settings, onOpenTuning: { showTuning = true })
            #else
            CoachSettingsSheet(settings: settings)
            #endif
        }
        // Drawer 1 — the seven dimensions, live behind the coach line.
        .sheet(isPresented: $showDimensions) {
            DimensionsDrawer(headline: laneMessage?.text ?? "Reading the frame…",
                             headlineTone: laneMessage?.tone ?? .neutral,
                             statuses: coach?.statuses ?? [],
                             voice: settings.personality.voice)
        }
        // Drawer 2 — the tools tray.
        .sheet(isPresented: $showTools) {
            CameraToolsDrawer(
                settings: settings,
                whiteBalanceCalibrated: camera.whiteBalanceCalibrated,
                cardCalibrated: cardMatrix != nil,
                aeAfLocked: camera.aeAfLocked,
                onionEnabled: $onionEnabled,
                onionOpacity: $onionOpacity,
                ghostAvailable: matchLook != nil || !referenceURLs.isEmpty,
                referenceChoice: matchLook == nil && referenceURLs.count > 1
                    ? (index: referenceIndex, count: referenceURLs.count) : nil,
                onCycleReference: {
                    referenceIndex = (referenceIndex + 1) % referenceURLs.count
                },
                onCalibrate: { calibrating = true; calibrationStatus = nil },
                onToggleAEAF: { camera.setAEAFLock(!camera.aeAfLocked) },
                onOpenAllSettings: { presentAfterDrawer { showSettings = true } },
                onOpenPracticeLibrary: destination.isPractice
                    ? { presentAfterDrawer { showPracticeLibrary = true } }
                    : nil,
                saveToPhotos: destination.isPractice ? $savePracticeToPhotos : nil,
                torchAvailable: camera.torchAvailable,
                torchOn: $torchOn,
                onImportFromLibrary: { presentAfterDrawer { showLibraryPicker = true } }
            )
        }
        // Drawer 3 — the guide + packs + the matched look's direction lines.
        .sheet(isPresented: $showGuideSheet) {
            ShotGuideDrawer(
                guide: guide,
                currentStepID: currentStepID,
                completedStepIDs: completedStepIDs,
                requirementNote: destination.guideNote(requirementMet: requirementMet, voice: settings.personality.voice),
                standardGuideName: standardGuide.name,
                trendingPacks: trendingPacks,
                activePackID: activePackID,
                matchLookActive: matchLook != nil,
                aiSummary: matchLook?.aiSummary,
                directionLines: matchLook?.directionLines ?? [],
                directionIndex: lookDirectionIndex,
                onSelectStep: { currentStepID = $0 },
                onSelectPack: selectPack,
                onMatchAPhoto: { presentAfterDrawer { showLookPicker = true } },
                onAdvanceDirection: advanceLookDirection,
                voice: settings.personality.voice
            )
        }
        #if DEBUG
        // The tuning console rides a half-height sheet over the LIVE camera —
        // preview on top, sliders below, signals streaming (not in isReviewing).
        .sheet(isPresented: $showTuning) {
            if let coach {
                CoachTuningHUD(coach: coach)
                    .presentationDetents([.fraction(0.45), .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .large))
            }
        }
        #endif
        .sheet(isPresented: $showPracticeLibrary) {
            NavigationStack {
                // No `onShoot`: the camera is already open behind this sheet.
                ProPracticeLibraryView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showPracticeLibrary = false }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .sheet(isPresented: $showBestShots) {
            if let coach {
                BestShotsReviewView(coach: coach, destination: destination,
                                    correction: cardMatrix)
            }
        }
        .fullScreenCover(item: $scrubClip) { clip in
            FrameScrubberView(videoURL: clip.url, destination: destination,
                              correction: cardMatrix)
        }
        .mediaFullscreenCover($viewingMedia)
        .modifier(RetakeDialog(pendingRetake: $pendingRetake, keep: { retake in
            Task {
                uploading = true
                await finalize(retake.data, advanceGuide: retake.advanceGuide, focal: retake.focal,
                               capturedAt: retake.capturedAt)
                uploading = false
            }
        }, voice: settings.personality.voice))
        .modifier(TerminalUploadDialog(
            isPresented: $showTerminalDecision,
            count: uploads.blockedCount,
            reason: uploads.statusMessage,
            save: { Task { await saveTerminalUploadsToLibrary() } },
            discard: discardRefusedPhotos
        ))
        .confirmationDialog(
            exitDialogTitle,
            isPresented: $showExitConfirm,
            titleVisibility: .visible
        ) {
            if uploads.blockedCount > 0 {
                Button("Decide on refused photos") { showTerminalDecision = true }
            }
            if coach?.harvested.isEmpty == false {
                Button("Review best shots") { showBestShots = true }
            }
            // Only destructive when something is genuinely discarded by leaving:
            // owed uploads survive in custody and resume next time; the harvest
            // tray does not.
            Button("Leave", role: coach?.harvested.isEmpty == false ? .destructive : nil) {
                dismiss()
            }
            Button("Keep shooting", role: .cancel) {}
        } message: {
            Text(exitWarningMessage)
        }
    }

    /// Honest about what leaving actually costs — the three outcomes differ, and
    /// telling the pro everything is "discarded" would be as wrong as the old
    /// silence. Best shots are swept; owed uploads resume; refusals never will.
    private var exitWarningMessage: String {
        var lines: [String] = []
        // The requirement, when it's outstanding — said once, plainly, with the
        // way out named. Extras are never mentioned: they are not owed.
        if destination.owesAPhoto && !requirementMet {
            lines.append(destination.outstandingSentence(voice: settings.personality.voice))
            lines.append("You can come back and take it any time.")
        }
        if hasUnsavedWork { lines.append("You still have \(unsavedWorkSummary).") }
        if coach?.harvested.isEmpty == false {
            lines.append("Best shots aren’t saved until you review them — leaving discards those.")
        }
        if uploads.pendingCount > 0 || !failedClips.isEmpty {
            lines.append("Anything still uploading keeps going in the background — you can close the camera and finish the session.")
        }
        if uploads.blockedCount > 0 {
            lines.append("The refused photos won’t upload on their own — save them to your phone first, or they’re gone.")
        }
        return lines.joined(separator: " ")
    }

    /// The keep-or-drop decision for photos the server refused, as a modifier for
    /// the same reason as `RetakeDialog`: the body's modifier chain is already at
    /// the edge of what the type-checker resolves quickly.
    private struct TerminalUploadDialog: ViewModifier {
        @Binding var isPresented: Bool
        let count: Int
        let reason: String?
        let save: () -> Void
        let discard: () -> Void

        func body(content: Content) -> some View {
            // ⚠️ Nothing here may `.disabled(…)` — a modifier applies to `content`,
            // which is the whole camera. Re-entry is already prevented by the
            // dialog dismissing on tap plus the guard in the save itself.
            content.confirmationDialog(
                count == 1 ? "This photo can’t be saved here"
                           : "\(count) photos can’t be saved here",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button("Save to my photos") { save() }
                Button("Discard", role: .destructive) { discard() }
                Button("Decide later", role: .cancel) {}
            } message: {
                Text(
                    [reason,
                     "The server won’t accept \(count == 1 ? "it" : "them"), so trying again won’t help. Save to your photos to keep \(count == 1 ? "it" : "them")."]
                        .compactMap { $0 }
                        .joined(separator: " ")
                )
            }
        }
    }

    /// The photographer-check keep-or-retake dialog, extracted as a modifier —
    /// inlining it pushed the body's modifier chain past what the type-checker
    /// resolves in reasonable time.
    private struct RetakeDialog: ViewModifier {
        @Binding var pendingRetake: PendingRetake?
        let keep: (PendingRetake) -> Void
        /// The active coaching voice — renders the dialog's wrapping sentence
        /// (`.retakeConfirm`) around the canonical QC reason. Defaults to Calm
        /// Mentor so any caller that doesn't pass one keeps seeing today's
        /// text unchanged.
        var voice: CoachVoice = CalmMentorVoice()

        func body(content: Content) -> some View {
            content.confirmationDialog(
                "Photographer check",
                isPresented: Binding(
                    get: { pendingRetake != nil },
                    set: { if !$0 { pendingRetake = nil } }   // dismiss = retake
                ),
                titleVisibility: .visible,
                presenting: pendingRetake
            ) { shot in
                Button("Retake") { pendingRetake = nil }
                Button("Keep it anyway") {
                    let retake = shot
                    pendingRetake = nil
                    keep(retake)
                }
            } message: { shot in
                Text(message(shot))
            }
        }

        private func message(_ shot: PendingRetake) -> String {
            // The CANONICAL reason, not a pack-rendered one — `.retakeConfirm`'s
            // own copy already does the one flourish this sentence gets.
            // Rendering `shot.reason` through its own QC moment first and THEN
            // splicing that already-flourished line into another flourished
            // wrapper was the original approach here, and it reads exactly as
            // bad out loud as it sounds on paper — "It came out too dark,
            // bestie — one more! — retake while they're right there, bestie?".
            // One flourish per utterance, not two stacked.
            let fallback = "\(shot.reason). Retake it while they’re still in position?"
            return CoachVoiceRenderer.render(
                .retakeConfirm, fallback: fallback, ctx: CoachPhraseContext(detail: shot.reason), voice: voice) ?? fallback
        }
    }

    /// Leave the camera — but never silently, if anything would be lost by going.
    /// A rolling recording is stopped + saved first (the upload finishes in the
    /// background; a failure lands in the ClipVault and is swept up next time).
    ///
    /// 🔴 This used to check ONLY the harvest tray, on the assumption that
    /// "manually captured photos already uploaded". They hadn't: a refused photo
    /// sat in the retry queue, exit dismissed without a word, and the bytes were
    /// wiped on the next camera start. Owed photos and clips now hold the door
    /// too — anything the server hasn't taken is work the pro can still lose.
    ///
    /// It has never counted guide steps and must not start: an unfinished shot
    /// list costs nothing. The ONE count it now names is the phase requirement —
    /// leaving with no photo at all is the only shortfall the session will feel,
    /// and even that is a sentence, not a locked door.
    private func requestExit() {
        if camera.isRecording { Task { await stopRecordingAndSave(review: false) } }
        // Leaving the camera kills the torch at the OS level — drop the flag
        // so a fresh session starts with the button dark, matching the device.
        torchOn = false
        if hasUnsavedWork || (destination.owesAPhoto && !requirementMet) {
            showExitConfirm = true
        } else {
            dismiss()
        }
    }

    /// Anything that leaving would strand: unreviewed auto-harvested shots, photos
    /// the server hasn't accepted, or clips still owed.
    ///
    /// ⚠️ Photos merely still UPLOADING are deliberately not in here any more:
    /// they finish in the background whether or not this screen exists, so
    /// calling them "unfinished work" would be telling the pro to wait for
    /// something they no longer have to wait for. Only a REFUSED photo — which
    /// will never upload on its own — is genuinely at risk.
    private var hasUnsavedWork: Bool {
        coach?.harvested.isEmpty == false || uploads.blockedCount > 0 || !failedClips.isEmpty
    }

    /// The exit dialog names whichever problem is actually true — bytes at risk,
    /// or the one photo the session still needs.
    private var exitDialogTitle: String {
        hasUnsavedWork
            ? "Leave with work unfinished?"
            : destination.leavingWithoutTitle(voice: settings.personality.voice)
    }

    /// Plain-language list of what's at risk, for the exit dialog. Refused photos
    /// are called out separately — they're the ones that will never upload on
    /// their own, so "come back later" is not a real answer for them.
    private var unsavedWorkSummary: String {
        var parts: [String] = []
        if let harvested = coach?.harvested.count, harvested > 0 {
            parts.append("\(harvested) best shot\(harvested == 1 ? "" : "s") to review")
        }
        if uploads.blockedCount > 0 {
            parts.append("\(uploads.blockedCount) photo\(uploads.blockedCount == 1 ? "" : "s") the server refused")
        }
        if !failedClips.isEmpty {
            parts.append("\(failedClips.count) clip\(failedClips.count == 1 ? "" : "s") still uploading")
        }
        return parts.formatted(.list(type: .and))
    }

    // MARK: - Camera UI

    private var cameraUI: some View {
        VStack(spacing: 0) {
            // Live preview + coaching overlays
            ZStack(alignment: .top) {
                if camera.status == .ready {
                    CameraPreview(session: camera.session) { camera.previewLayer = $0 }
                        .ignoresSafeArea(edges: .top)
                        .overlay { focusReticleOverlay }
                        #if DEBUG
                        // Face-metering verification crosshair: draws the point
                        // ACTUALLY WRITTEN to exposurePointOfInterest, converted
                        // back through the layer's own inverse mapping. Dot on
                        // face ⇒ the (y, 1−x) transform is right; mirrored dot
                        // ⇒ wrong. See `faceMeterCrosshair`.
                        .overlay {
                            if let p = faceMeterCrosshair {
                                ZStack {
                                    Circle().stroke(BrandColor.emerald, lineWidth: 1.5)
                                        .frame(width: 44, height: 44)
                                    Circle().fill(BrandColor.emerald)
                                        .frame(width: 4, height: 4)
                                }
                                .position(p)
                                .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if faceMeterCrosshair != nil {
                                Text("FACE METER — dot must sit on the face")
                                    .font(BrandFont.mono(9)).tracking(0.8)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(.bottom, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        #endif
                        // Drawn as preview overlays so they share the preview
                        // layer's coordinate space (boxes map sensor regions
                        // exactly).
                        .overlay { if calibrating { calibrationTarget } }
                        .overlay { if settings.showCropGuide { cropSafeOverlay } }
                        .gesture(
                            SpatialTapGesture().onEnded { handleFocusTap($0.location) }
                        )
                        // Pinch-to-zoom: the photographer's second framing tool
                        // after moving their feet. The gesture OWNS the zoom:
                        // each update feeds the controller directly, and
                        // `.onEnded` does bookkeeping ONLY — no reset value is
                        // sent through the zoom channel (a reset here would
                        // write gesture-start zoom back over the held framing).
                        // Zoom persists between gestures by design.
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if !pinchActive {
                                        pinchActive = true
                                        camera.beginPinchZoom()
                                    }
                                    camera.setPinchZoom(value)
                                }
                                .onEnded { _ in
                                    pinchActive = false
                                }
                        )
                        // Swipe the preview sideways to move a shot without
                        // opening anything — the guide bar's Prev/Next chevrons,
                        // as a gesture. Simultaneous so tap-to-focus still wins
                        // a stationary touch.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 44)
                                .onEnded { value in handlePreviewSwipe(value.translation) }
                        )
                } else {
                    Color.black
                    ProgressView().tint(.white)
                }

                if showOnion {
                    Group {
                        if let look = matchLook {
                            Image(uiImage: look.image).resizable().scaledToFill()
                        } else if let url = currentReferenceURL {
                            // Bounded decode — AsyncImage would pin the ORIGINAL
                            // "before" upload's full-resolution bitmap for the
                            // whole AFTER shoot.
                            DownsampledRemoteImage(url: url) { Color.clear }
                        }
                    }
                    .opacity(onionOpacity)
                    .allowsHitTesting(false)
                    .clipped()
                    .ignoresSafeArea(edges: .top)
                }

                if settings.showGrid { thirdsGrid }
                // The level draws itself when the camera is more than a couple of
                // degrees out even with the setting off, then disappears again —
                // it's only information while it's a problem.
                if let roll = coach?.deviceRoll,
                   settings.showLevel || abs(roll) > CoachTuning.tiltLevelDegrees {
                    levelIndicator(roll)
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                }
            }

            controls
        }
    }

    // MARK: - Top bar (three items, one row)

    /// Close · the step chip · ⋯. The eight-part guide bar collapsed into the
    /// chip; the eyedropper, AE/AF lock and gear collapsed into the ⋯ tray.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { requestExit() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(BrandColor.bgPrimary.opacity(0.62), in: Circle())
            }
            .accessibilityLabel("Close the camera")

            Spacer(minLength: 0)
            stepChip
            Spacer(minLength: 0)

            Button { showTools = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(BrandColor.bgPrimary.opacity(0.62), in: Circle())
            }
            .accessibilityLabel("Tools")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Progress dots + the shot you're on + a disclosure. Falls back to the
    /// phase label when there's no guide to be on.
    @ViewBuilder private var stepChip: some View {
        if guidedShooting {
            Button { showGuideSheet = true } label: {
                HStack(spacing: 9) {
                    HStack(spacing: 4) {
                        ForEach(guide.steps) { step in
                            Circle()
                                .fill(completedStepIDs.contains(step.id) ? BrandColor.accent
                                      : (step.id == currentStepID
                                         ? BrandColor.textPrimary
                                         : BrandColor.textPrimary.opacity(0.32)))
                                .frame(width: 5, height: 5)
                        }
                    }
                    Text(allStepsDone ? guide.name : (currentStep?.title ?? guide.name))
                        .font(BrandFont.display(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BrandColor.textPrimary.opacity(0.55))
                }
                .padding(.horizontal, 15)
                .frame(height: 38)
                .background(BrandColor.bgPrimary.opacity(0.62), in: Capsule())
            }
            .accessibilityLabel("Shot \(currentStepIndex + 1) of \(guide.steps.count), \(currentStep?.title ?? guide.name)")
            // "1 of 5" spoken alone is a quota. The value says what the count
            // actually means: one photo is owed, the set is a suggestion.
            .accessibilityValue(destination.guideNote(requirementMet: requirementMet, voice: settings.personality.voice))
            .accessibilityHint("Opens the shot guide")
        } else {
            Text("\(phaseLabel) photos".uppercased())
                .font(BrandFont.mono(12))
                .tracking(1.2)
                .foregroundStyle(BrandColor.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(BrandColor.bgPrimary.opacity(0.62), in: Capsule())
        }
    }

    /// Whether the directed shoot is actually driving right now.
    private var guidedShooting: Bool { settings.showGuides && !guide.steps.isEmpty }

    /// Sideways swipe on the preview = Prev/Next shot. Vertical drags are left
    /// alone so a scroll-ish gesture never jumps the guide.
    private func handlePreviewSwipe(_ translation: CGSize) {
        guard guidedShooting, abs(translation.width) > abs(translation.height) else { return }
        selectStep(translation.width < 0 ? 1 : -1)
    }

    /// Rule-of-thirds guide.
    private var thirdsGrid: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - White balance (gray-card calibration)

    /// The calibration target. Towel mode: the EXACT region the analyzer
    /// samples for white balance (center 40% of the sensor frame). Card mode:
    /// a card-shaped (CR-80) alignment box — the scanner samples the swatch
    /// grid inside it. Both mapped through the preview layer's aspect-fill so
    /// the box on screen is the area being measured.
    private var calibrationTarget: some View {
        GeometryReader { geo in
            let box = cardMode
                ? previewRect(uprightNormalized: cardRegion, in: geo.size)
                : sampledRegionRect(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandColor.gold, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .frame(width: box.width, height: box.height)
                Text(cardMode ? "Line the calibration card up with this box"
                              : "Fill this with a white towel or gray card")
                    .font(BrandFont.body(12, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .offset(y: -box.height / 2 - 24)
            }
            .position(x: box.midX, y: box.midY)
        }
        .allowsHitTesting(false)
    }

    /// Upright-normalized frame region the card alignment box covers: 80% of
    /// the frame width, height from the card's physical CR-80 aspect. Centered
    /// (required by `previewRect`'s axis-swap mapping).
    private var cardRegion: CGRect {
        let width = 0.8
        let height = width * (3.0 / 4.0) / scanTarget.aspect   // frame is 3:4 (w/h)
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    /// Preview-space rect of the analyzer's white-balance sample region (the
    /// center 40% of the frame in both dimensions).
    private func sampledRegionRect(in size: CGSize) -> CGRect {
        previewRect(uprightNormalized: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), in: size)
    }

    /// Map a CENTERED upright-normalized frame rect into the preview layer's
    /// coordinate space (aspect-fill aware). Centered rects survive the
    /// upright→sensor rotation by swapping axes, so this stays exact without
    /// caring about the rotation direction. Falls back to a naive screen-space
    /// box before the layer has geometry.
    private func previewRect(uprightNormalized r: CGRect, in size: CGSize) -> CGRect {
        if let layer = camera.previewLayer, layer.bounds.width > 0 {
            let metadata = CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
            return layer.layerRectConverted(fromMetadataOutputRect: metadata)
        }
        return CGRect(x: size.width * r.minX, y: size.height * r.minY,
                      width: size.width * r.width, height: size.height * r.height)
    }

    #if DEBUG
    /// The crosshair's position: the DEVICE-space point `setFaceExposure`
    /// actually wrote to `exposurePointOfInterest`, converted BACK to layer
    /// space with `layerPointConverted(fromCaptureDevicePoint:)` — the exact
    /// inverse of the conversion tap-to-focus uses. Drawing this point is what
    /// makes dot-on-face a test OF THE TRANSFORM: a mirrored (y, 1−x) puts the
    /// dot somewhere off the face even though detection and preview mapping
    /// are both correct.
    ///
    /// ⚠️ `layerPointConverted` answers for the point captured in the CURRENT
    /// frame; the crosshair lags the live face by one analysis frame (~160ms
    /// at 6fps). Fine for an eye-check, which is all this overlay claims to be.
    var faceMeterCrosshair: CGPoint? {
        guard let devicePoint = camera.lastFaceMeterDevicePoint,
              let layer = camera.previewLayer else { return nil }
        return layer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
    }
    #endif

    // MARK: - Crop-safe guide (publish crops)

    /// Publishing crops beauty work actually ships in. The PRIMARY box is 9:16
    /// — the Tovis Looks feed is a full-screen cover-cropped pager, so a 3:4
    /// capture loses a quarter of its width there; whatever must survive the feed
    /// stays inside the bright box. 4:5 (Instagram feed) rides along dimmer.
    /// Drawn from the sensor frame through the preview layer so what's inside
    /// the lines is exactly what survives each crop.
    private var cropSafeOverlay: some View {
        GeometryReader { geo in
            ZStack {
                cropBox(aspect: PublishCrop.instagramFeed, label: "4:5", primary: false, in: geo.size)
                cropBox(aspect: PublishCrop.feed, label: "9:16 · feed", primary: true, in: geo.size)
                coverSafeBand(in: geo.size)
            }
        }
        .allowsHitTesting(false)
    }

    /// The band inside the 9:16 box that survives a Reel COVER — the platform
    /// lays its own chrome over the top ~220 px and bottom ~450 px of a
    /// 1080×1920 cover, and the cover is what stops the scroll. Published,
    /// fixed numbers; drawn dashed rather than as a third solid box so it reads
    /// as a warning zone and not another crop to compose to.
    ///
    /// Insetting the ALREADY-MAPPED 9:16 box rather than mapping a frame-space
    /// rect is deliberate: `previewRect` is only exact for rects centered in
    /// both axes (its own note says so — the upright→sensor axis swap hides the
    /// flip when they are), and this band is deliberately off-centre vertically.
    /// The preview shows the upright image, so a vertical fraction of the drawn
    /// box is the same vertical fraction of the published cover.
    private func coverSafeBand(in size: CGSize) -> some View {
        let feedBox = previewRect(uprightNormalized: PublishCrop.rect(aspect: PublishCrop.feed),
                                  in: size)
        let box = PublishCrop.coverSafeRect(in: feedBox)
        return Rectangle()
            .strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .frame(width: box.width, height: box.height)
            .overlay(alignment: .bottomLeading) {
                Text("cover safe")
                    .font(BrandFont.mono(9)).tracking(0.5)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(4)
            }
            .position(x: box.midX, y: box.midY)
    }

    /// A centered crop of `aspect` (w/h) within the upright 3:4 capture frame,
    /// mapped to preview space. `primary` = the crop the Tovis feed itself uses.
    /// The geometry comes from `PublishCrop`, which is the same source
    /// `CompositionCoach` judges inside — so what the lines promise and what the
    /// coach approves cannot drift apart.
    private func cropBox(aspect: CGFloat, label: String, primary: Bool, in size: CGSize) -> some View {
        let box = previewRect(uprightNormalized: PublishCrop.rect(aspect: aspect), in: size)
        return Rectangle()
            .strokeBorder(.white.opacity(primary ? 0.6 : 0.22), lineWidth: primary ? 1.5 : 1)
            .frame(width: box.width, height: box.height)
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(BrandFont.mono(9)).tracking(0.5)
                    .foregroundStyle(.white.opacity(primary ? 0.85 : 0.45))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(4)
            }
            .position(x: box.midX, y: box.midY)
    }

    /// The calibration action row (shown in the controls while calibrating):
    /// a Towel/Card mode switch, the mode's action, Auto (reset), Done.
    private var calibrationControls: some View {
        VStack(spacing: 8) {
            Text(calibrationStatusText)
                .font(BrandFont.body(12)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                calibrationModeChip("Towel", active: !cardMode) { cardMode = false }
                calibrationModeChip("Card", active: cardMode) { cardMode = true }

                if cardMode {
                    Button { Task { await scanCard() } } label: {
                        Text(scanningCard ? "Scanning…" : "Scan card")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.onAccent)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(BrandColor.accent, in: Capsule())
                    }
                    .disabled(scanningCard || camera.status != .ready)
                } else {
                    Button { setWhiteBalance() } label: {
                        Text("Set white balance").font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.onAccent)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(BrandColor.accent, in: Capsule())
                    }
                }
                if camera.whiteBalanceCalibrated || cardMatrix != nil {
                    Button { resetCalibration() } label: {
                        Text("Auto").font(BrandFont.body(14, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                Button { calibrating = false } label: {
                    Text("Done").font(BrandFont.body(14, .semibold)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 10)
                }
            }
            #if DEBUG
            // Dev-only: pick the physical reference the scan targets. Lets the
            // color pipeline be validated against a real ColorChecker (factory
            // reference, no printing) before the measured-Tovis-card path exists.
            if cardMode {
                HStack(spacing: 6) {
                    Text("Ref").font(BrandFont.body(11)).foregroundStyle(.white.opacity(0.5))
                    ForEach(CalibrationTarget.all, id: \.id) { t in
                        calibrationModeChip(t.displayName, active: scanTarget.id == t.id) {
                            guard scanTarget.id != t.id else { return }
                            scanTarget = t
                            calibrationStatus = nil   // stale read state for the old target
                            lastDiagnostics = nil     // and its diagnostics
                        }
                    }
                    // Read-out of the last scan (pass or fail) — the tight-loop
                    // signal for tuning a target's geometry constants.
                    if lastDiagnostics != nil {
                        Button { showingDiagnostics = true } label: {
                            Label("Diagnostics", systemImage: "scope")
                                .font(BrandFont.body(12, .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            #endif
        }
        .padding(.horizontal, 20)
        #if DEBUG
        .sheet(isPresented: $showingDiagnostics) {
            if let lastDiagnostics {
                CalibrationDiagnosticsView(diagnostics: lastDiagnostics)
                    .presentationDetents([.medium, .large])
            }
        }
        #endif
    }

    private func calibrationModeChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(BrandFont.body(13, .semibold))
                .foregroundStyle(active ? BrandColor.onAccent : .white)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(active ? BrandColor.gold : .white.opacity(0.12), in: Capsule())
        }
    }

    private var calibrationStatusText: String {
        if let calibrationStatus { return calibrationStatus }
        if cardMode {
            return cardMatrix != nil
                ? "Card locked — color & exposure are calibrated"
                : "Line the card up in the box, then scan"
        }
        return camera.whiteBalanceCalibrated
            ? "White balance locked — colors are true now"
            : "Point at a neutral surface, then set"
    }

    /// Drop every calibration (WB, card matrix, exposure anchor) for this booking.
    private func resetCalibration() {
        camera.resetWhiteBalance()
        cardMatrix = nil
        calibrationStatus = nil
        calibrationWarmth = nil
        driftSince = nil
        driftDismissed = false
        UserDefaults.standard.removeObject(forKey: wbDefaultsKey)
        UserDefaults.standard.removeObject(forKey: cardCalDefaultsKey)
    }

    /// The two-shot card scan. Shot 1 reads the neutral band → locks white
    /// balance. Shot 2 (under the locked WB) reads the swatch grid → solves the
    /// chromatic matrix (residual print/spectrum error only — WB is already
    /// handled, so no double-correction) + the exposure anchor. The gray-ramp
    /// check gates a misaligned/glared read before anything is applied.
    private func scanCard() async {
        guard !scanningCard, !uploading, camera.status == .ready else { return }
        scanningCard = true
        defer { scanningCard = false }
        #if DEBUG
        lastDiagnostics = nil   // stale read state until this scan reads a grid
        #endif
        calibrationStatus = "Reading the card…"

        let target = scanTarget
        guard let first = try? await camera.capturePhoto(),
              let firstRead = await CardScanner.read(jpeg: first, cardRegion: cardRegion, target: target) else {
            calibrationStatus = "Couldn’t read the card — line it up with the box."
            return
        }
        camera.lockWhiteBalance(sampleR: firstRead.neutralBand.r,
                                sampleG: firstRead.neutralBand.g,
                                sampleB: firstRead.neutralBand.b)
        // Let the locked gains settle before the swatch shot.
        try? await Task.sleep(nanoseconds: 400_000_000)

        guard let second = try? await camera.capturePhoto(),
              let read = await CardScanner.read(jpeg: second, cardRegion: cardRegion, target: target) else {
            calibrationStatus = "Couldn’t read the card — avoid glare and fill the box."
            return
        }
        #if DEBUG
        // Read out everything this scan learned (pass OR fail) so a failed read
        // says WHY — the gray-ramp lumas, the solved matrix even when the gate
        // rejects it, the EV bias, and per-patch measured-vs-reference. This is
        // what makes tuning a ColorChecker's geometry constants a tight loop.
        lastDiagnostics = CameraCalibration.diagnose(
            measuredSRGB: read.swatches, neutralBand: read.neutralBand, target: target)
        #endif
        guard CameraCalibration.looksLikeGrayRamp(measuredSRGB: read.swatches) else {
            calibrationStatus = "Couldn’t read the card — avoid glare and fill the box."
            return
        }
        guard let matrix = CameraCalibration.chromaticCorrection(
                  measuredSRGB: read.swatches,
                  profile: target.profile),
              let ev = CameraCalibration.exposureBiasEV(
                  measuredNeutralSRGB: read.neutralBand,
                  referenceNeutralSRGB: target.wbNominalSRGB) else {
            calibrationStatus = "Card read wasn’t clean — try again in steadier light."
            return
        }
        cardMatrix = matrix
        camera.setCalibrationExposureBias(Float(ev))
        // Remember the scan-moment warmth so the drift detector can notice the
        // room's light changing out from under the calibration.
        calibrationWarmth = coach?.frameWarmth
        driftSince = nil
        driftDismissed = false
        // Tag the cached calibration with the target it was solved against, so a
        // later restore only reuses it when the SAME reference is active — never
        // silently apply a ColorChecker (or stale-batch) matrix to a Tovis-card
        // session (see StoredCardCalibration.restorable).
        let record = StoredCardCalibration(
            target: target, matrix: matrix, exposureBiasEV: ev, calibrationWarmth: calibrationWarmth)
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: cardCalDefaultsKey)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        calibrationStatus = "Card locked — color & exposure are calibrated."
    }

    // MARK: - Calibration drift (the light changed since the card scan)

    /// Sustained warmth drift vs the scan moment → surface the re-scan nudge.
    private func updateDrift(_ warmth: Double) {
        guard cardMatrix != nil, let calibrated = calibrationWarmth else {
            driftSince = nil
            return
        }
        if abs(warmth - calibrated) <= CoachTuning.calibrationDriftWarmth {
            // Back within tolerance of the scan-moment light — clear any pending
            // drift AND release the dismissal latch, so a fresh drift later can
            // nudge again (one dismissal shouldn't silence drift for the whole
            // session).
            driftSince = nil
            driftDismissed = false
            return
        }
        // Drifting: stay quiet while the pro has already acted on/dismissed the
        // nudge (until the light returns above and drifts anew).
        guard !driftDismissed else {
            driftSince = nil
            return
        }
        if driftSince == nil { driftSince = Date() }
    }

    private var driftNudgeActive: Bool {
        guard let since = driftSince else { return false }
        return Date().timeIntervalSince(since) >= CoachTuning.calibrationDriftSeconds
    }

    // (The one-tap path back to the card scan is now the lane's FIX action —
    // see `handleLaneAction(.recalibrate)`. It kept its own pill for as long as
    // there was a stack to put one in.)

    /// Sample the center patch + lock white balance to neutralize the room's cast.
    private func setWhiteBalance() {
        let s = coach?.centerSample ?? (r: 0.5, g: 0.5, b: 0.5)
        camera.lockWhiteBalance(sampleR: s.r, sampleG: s.g, sampleB: s.b)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Tap to focus

    /// The focus/exposure reticle, drawn in the preview's coordinate space.
    @ViewBuilder private var focusReticleOverlay: some View {
        if let p = focusPoint {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(BrandColor.gold, lineWidth: 1.5)
                .frame(width: 74, height: 74)
                .position(p)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Tap-to-focus: meter + focus on the tapped point (the work), show the reticle,
    /// fade it after a beat. Releases any AE/AF lock (handled in the controller).
    private func handleFocusTap(_ point: CGPoint) {
        camera.focus(atLayerPoint: point)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.12)) { focusPoint = point }
        focusToken += 1
        let token = focusToken
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if focusToken == token { withAnimation(.easeIn(duration: 0.3)) { focusPoint = nil } }
        }
    }

    // MARK: - Guided auto-capture

    /// The photographer takes the shot: once the current guided shot has held good +
    /// steady, fire the full-quality capture, confirm, and advance. Disarms until the
    /// shot drops out of "ready" again so it shoots once per setup, not continuously.
    private func attemptGuidedCapture() {
        // Permanent-for-now gates: auto-capture simply isn't in play — nothing to
        // queue (it re-arms naturally when guides/auto come back on).
        guard settings.autoCapture, settings.showGuides, !guide.steps.isEmpty, !allStepsDone else {
            guidedCaptureQueued = false
            return
        }
        // Transient gates: remember we wanted the shot and take it once they clear
        // (see `retryGuidedIfReady`) rather than waiting for the next stabilization.
        guard !uploading, !isReviewing, !calibrating,
              !camera.isRecording,   // don't auto-fire stills mid-clip
              camera.status == .ready else {
            guidedCaptureQueued = true
            return
        }
        guidedCaptureQueued = false
        autoArm.didFire()
        Task {
            let title = currentStep?.title
            let kept = await capture(trigger: .auto)   // burst + QC; advances only on a keeper
            coach?.resetHold()
            // A burst that kept NOTHING re-arms. Without this the lane says
            // "holding for another try" while auto-capture is dead until the
            // shot leaves the green ring — and a client holding perfectly still
            // is precisely the case where it never does. (See GuidedCaptureArm.)
            autoArm.captureFinished(kept: kept)
            if kept, settings.speak, let title {
                let voice = settings.personality.voice
                let fallback = "Got the \(title)."
                let line = CoachVoiceRenderer.render(
                    .shotCaptured, fallback: fallback,
                    ctx: CoachPhraseContext(subjectNoun: title), voice: voice) ?? fallback
                coach?.announce(line)
            }
        }
    }

    /// A transient gate that blocked a queued auto-capture just cleared — if the
    /// shot is still held steady and armed, take it now.
    private func retryGuidedIfReady() {
        guard guidedCaptureQueued,
              autoArm.shouldFire(steady: coach?.isSteadyReady ?? false) else { return }
        attemptGuidedCapture()
    }

    /// Camera level / horizon indicator — fixed reference ticks plus a line that
    /// rolls with the device and snaps green when the camera is level. Like the
    /// system camera's level, so "straighten up" is something the pro can *see*.
    private func levelIndicator(_ roll: Double) -> some View {
        let isLevel = abs(roll) <= CoachTuning.tiltLevelDegrees
        return GeometryReader { geo in
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            ZStack {
                // Fixed reference ticks (faint), centered.
                Rectangle().fill(.white.opacity(0.35)).frame(width: 26, height: 1.5)
                    .position(x: cx - 64, y: cy)
                Rectangle().fill(.white.opacity(0.35)).frame(width: 26, height: 1.5)
                    .position(x: cx + 64, y: cy)
                // Rolling line through the center.
                Rectangle()
                    .fill(isLevel ? BrandColor.emerald : .white.opacity(0.85))
                    .frame(width: 96, height: isLevel ? 2.5 : 1.5)
                    .shadow(color: isLevel ? BrandColor.emerald.opacity(0.7) : .clear, radius: 4)
                    .rotationEffect(.degrees(roll), anchor: .center)
                    .position(x: cx, y: cy)
                if isLevel {
                    Circle().fill(BrandColor.emerald).frame(width: 6, height: 6).position(x: cx, y: cy)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isLevel)
        }
        .allowsHitTesting(false)
    }

    // MARK: - ShotGuide (directed shoot)

    private var currentStep: ShotStep? {
        guide.steps.first { $0.id == currentStepID } ?? guide.steps.first
    }

    /// What the coach should expect of the frame right now — the current guided
    /// shot's expectations, or nil for freeform shooting (guides off / done).
    ///
    /// In an AFTER shoot the step's generic fill band is replaced by the
    /// booking's OWN before shot for this step: shooting the before tight and
    /// the after loose is the most-cited before/after mistake, and the target
    /// here is the before's measured number rather than a guess. A "match a
    /// look" reference already carries its own measured brief, so it wins.
    private var activeExpectations: ShotExpectations? {
        guard settings.showGuides, !guide.steps.isEmpty, !allStepsDone,
              let expects = currentStep?.expects else { return nil }
        guard matchLook == nil, let url = currentReferenceURL,
              let stamp = referenceStamps[url] else { return expects }
        return expects.matchingFraming(of: stamp)
    }
    private var currentStepIndex: Int {
        guide.steps.firstIndex { $0.id == currentStepID } ?? 0
    }
    /// The guide's whole shot list is captured. An ACHIEVEMENT, not a demand —
    /// see `requirementMet` for the only count this camera actually needs.
    private var allStepsDone: Bool {
        !guide.steps.isEmpty && completedStepIDs.count >= guide.steps.count
    }

    // MARK: - The requirement (one photo), vs the guide (a suggestion list)

    /// Photos this phase has: what the server already holds plus what's been shot
    /// here. Shots whose upload failed still count — the bytes are in custody and
    /// land on the next connection, so the pro isn't asked to redo them. Counted
    /// separately from the `captured` strip, which drops a shot whose thumbnail
    /// couldn't be decoded; a missing thumbnail must never re-open a met
    /// requirement.
    private var phasePhotoCount: Int { alreadyCaptured + keptThisSession }

    /// The one photo this phase owes is in hand.
    private var requirementMet: Bool {
        destination.requirementMet(captured: phasePhotoCount)
    }

    /// The moment the requirement is FIRST met, and only then: the card says the
    /// shoot is already sufficient. One more shot retires it on its own (the pro
    /// has answered by continuing), as does "Keep shooting".
    private var showRequirementCard: Bool {
        destination.owesAPhoto
            && !requirementCardDismissed
            && !allStepsDone
            && keptThisSession > 0   // not on reopening a phase that's already covered
            && phasePhotoCount == ProSessionPhotoRequirement.requiredPerPhase
    }

    /// Move the current-shot pointer (Prev/Next chevrons).
    private func selectStep(_ delta: Int) {
        let i = currentStepIndex + delta
        guard guide.steps.indices.contains(i) else { return }
        currentStepID = guide.steps[i].id
    }

    /// A successful capture completes the current guided shot and advances to the
    /// next one that hasn't been taken yet.
    private func markCurrentCaptured() {
        guard let id = currentStepID else { return }
        completedStepIDs.insert(id)
        if let next = guide.steps.first(where: { !completedStepIDs.contains($0.id) }) {
            currentStepID = next.id
        }
    }

    /// Switch the directed shoot between the standard set and a trending pack.
    /// Progress resets — a pack is a different shot list, not a reordering.
    /// Clears any active match-look (the sources are mutually exclusive).
    private func selectPack(_ pack: ProShotPack?) {
        let newID = pack?.id
        guard newID != activePackID || matchLook != nil else { return }
        matchLook = nil
        coach?.lookDirections = .empty   // the look's script leaves with the look
        activePackID = newID
        guide = pack.map(ShotGuide.init(pack:)) ?? standardGuide
        completedStepIDs = []
        setCompleteDismissed = false   // a new shot list gets its own completion moment
        currentStepID = guide.steps.first?.id
        if settings.speak, let pack {
            let voice = settings.personality.voice
            let fallback = "Trending set: \(pack.name). \(pack.tagline)"
            let line = CoachVoiceRenderer.render(
                .trendingSetIntro, fallback: fallback,
                ctx: CoachPhraseContext(subjectNoun: pack.name, detail: pack.tagline), voice: voice) ?? fallback
            coach?.announce(line)
        }
    }

    /// Drive the shoot from a measured reference look ("Match a look").
    private func selectMatchLook(_ look: ReferenceLook) {
        matchLook = look
        // A freshly measured look has no AI directions yet — enhance sets them.
        coach?.lookDirections = look.directions
        activePackID = nil
        guide = look.guide
        completedStepIDs = []
        setCompleteDismissed = false   // a new shot list gets its own completion moment
        currentStepID = guide.steps.first?.id
        lookDirectionIndex = 0
        onionEnabled = true   // the ghost is the point
        if settings.speak {
            coach?.announce(CoachVoiceRenderer.renderCanonical(
                .matchingReferenceLook, voice: settings.personality.voice))
        }
    }

    /// Phase D: optionally enrich the measured look with Claude vision — only
    /// the parts geometry can't measure. First use asks consent (the photo
    /// leaves the device); after that it runs automatically while the
    /// coaching-settings toggle is on.
    private func maybeEnhanceLook(_ look: ReferenceLook) {
        guard settings.aiEnhanceLooks else { return }
        if CameraVisionConsent.granted {
            runEnhanceLook(look)
        } else {
            pendingEnhanceLook = look
        }
    }

    private func runEnhanceLook(_ look: ReferenceLook) {
        enhancingLook = true
        Task {
            defer { enhancingLook = false }
            // Downscale + encode off the main actor; the live camera keeps running.
            let payload = await Task.detached(priority: .userInitiated) { [image = look.image] in
                CameraVisionPayload.imagePayload(image, maxDimension: 1568, quality: 0.7)
            }.value
            guard let payload else { return }
            do {
                let brief = try await session.client.proCamera.lookBrief(ProLookBriefRequest(
                    image: payload, serviceName: serviceName,
                    measuredSummary: look.measuredSummary))
                // Apply only if this look still drives the shoot (the pro may
                // have switched packs or picked another photo meanwhile).
                guard matchLook?.image === look.image else { return }
                let enhanced = look.enhanced(with: brief)
                matchLook = enhanced
                guide = enhanced.guide
                lookDirectionIndex = 0
                // From here the engine speaks the look's own line at the moment
                // the lens sees that state (tovis-app #974), in place of the
                // generic correction.
                coach?.lookDirections = enhanced.directions
                // The announce's ride-along line must be an OPENER, never a
                // corrective spoken out of context: the trigger script's
                // `opening` line, or the step's own hint when the model wrote
                // none. Only a legacy flat script (pre-trigger server) still
                // uses its first line, which was written to be read in order.
                let opener = enhanced.directions.isEmpty
                    ? enhanced.directionLines.first
                    : (enhanced.directions.line(for: .opening) ?? enhanced.guide.steps.first?.hint)
                if settings.speak, let first = opener {
                    let fallback = "AI direction ready. \(first)"
                    let line = CoachVoiceRenderer.render(
                        .aiDirectionReady, fallback: fallback,
                        ctx: CoachPhraseContext(detail: first), voice: settings.personality.voice) ?? fallback
                    coach?.announce(line)
                }
            } catch {
                // The measured on-device brief is already driving the shoot —
                // enhance failing costs nothing, so we degrade gracefully here
                // rather than block capture or push a mid-shoot upgrade prompt
                // (the membership route lives on the wrap-up critique instead).
                guard matchLook?.image === look.image else { return }
                switch ProCameraAIError.from(error) {
                case .quotaExceeded:
                    errorMessage = "AI enhance is out of images this month — shooting with the measured brief."
                case .dailyLimitReached:
                    errorMessage = "AI enhance hit today’s limit — shooting with the measured brief."
                case .other:
                    errorMessage = "AI enhance didn’t come through — shooting with the measured brief."
                }
            }
        }
    }

    /// Step through the matched look's AI direction lines (from the guide
    /// drawer) — each line is spoken when voice tips are on.
    private func advanceLookDirection() {
        guard let lines = matchLook?.directionLines, !lines.isEmpty else { return }
        let next = (min(max(lookDirectionIndex, 0), lines.count - 1) + 1) % lines.count
        lookDirectionIndex = next
        if settings.speak { coach?.announce(lines[next]) }
    }

    // MARK: - Light matching (before/after)

    /// Where this booking's locked white-balance gains persist (before + after
    /// share one calibration).
    private var wbDefaultsKey: String { "tovis.camera.wb.\(custodyScope)" }
    /// Where this booking's card calibration persists (9 matrix values + EV).
    private var cardCalDefaultsKey: String { "tovis.camera.cardcal.\(custodyScope)" }

    /// Measure each before-reference once — light AND framing, with the same
    /// eyes the live coach judges with (`BeforeShotMeasure`).
    private func loadReferenceStamps() async {
        for url in referenceURLs where referenceStamps[url] == nil {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let stamp = await BeforeShotMeasure.measure(data) else { continue }
            referenceStamps[url] = stamp
        }
    }

    /// This frame against the active target (a match-look reference wins over
    /// the before shot): the single biggest light mismatch phrased as a fix,
    /// the light matched, or — for the booking's own before, and only there —
    /// the PAIR matched, light AND framing (P5.3). Nil when there's nothing to
    /// match.
    ///
    /// Compared on the segmented BACKGROUND when both sides have one. On the
    /// whole frame, a dark-to-blonde colour service legitimately moves the
    /// luma — that *is* the work — and the coach would say "Brighter than the
    /// before — dim a touch" about a transformation that had succeeded. The
    /// background is the part of the picture that is supposed to be unchanged,
    /// which is exactly what "did the light change?" means.
    private var beforePair: BeforePair.Verdict? {
        guard showOnion, let coach else { return nil }
        let target: LightMatch.Reading
        let noun: String
        // The framing half of the pair exists only for the booking's OWN
        // before. A "match a look" reference is a picture the pro admired,
        // not the other half of this booking's comparison, and its brief
        // carries its own framing target — so it stays a light-only verdict,
        // byte-for-byte what ships today.
        let pairing: BeforeShotStamp?
        if let look = matchLook {
            target = LightMatch.Reading(luma: look.luma, warmth: look.warmth,
                                        backgroundLuma: look.backgroundLuma,
                                        backgroundWarmth: look.backgroundWarmth)
            noun = "reference"
            pairing = nil
        } else if let url = currentReferenceURL, let stamp = referenceStamps[url] {
            target = stamp.lightReading
            noun = "before"
            pairing = stamp
        } else {
            return nil
        }
        // The live frame's colour signal is already background-scoped when a
        // person is segmented (see `ColorSignal`), so its warmth serves both
        // slots; the comparison itself decides which pair to use.
        let live = LightMatch.Reading(luma: coach.frameLuma, warmth: coach.frameWarmth,
                                      backgroundLuma: coach.frameBackgroundLuma,
                                      backgroundWarmth: coach.frameWarmth)
        // `isDetail` is read off the expectations the coach is ACTUALLY
        // judging, so recognition and coaching agree about when the before's
        // framing is the target at all: a detail/macro close-up of the work
        // has no framing pair, and `matchingFraming` already declines to
        // re-target it.
        return BeforePair.verdict(
            live: live, target: target, noun: noun, pairing: pairing,
            liveFill: coach.frameJudgedFill,
            isDetail: activeExpectations?.isDetail ?? false)
    }

    // MARK: - The lane

    /// Everything the lane arbitrates between, gathered once per render.
    private var laneInputs: CameraLane.Inputs {
        var inputs = CameraLane.Inputs()
        inputs.terminalCount = uploads.blockedCount
        // Only uploads that actually FAILED an attempt raise the lane's alert —
        // healthy in-flight uploads are `backgroundBusy`'s hairline (and the
        // thumbnail's own "still saving" badge), never words. The session hub
        // makes the same distinction (`uploadStatusRow`).
        inputs.retryableCount = uploads.stalledPendingCount
        inputs.failedClipCount = failedClips.count
        inputs.bestShotCount = coach?.harvested.count ?? 0
        inputs.lightDrifted = driftNudgeActive
        inputs.lightTransient = lightTransient
        inputs.roomTipDismissed = roomDismissTransient
        inputs.roomTipDismissalUndoable = roomDismissUndoable
        inputs.stepTransient = stepTransient
        if guidedShooting {
            inputs.stepProgress = (index: currentStepIndex, total: guide.steps.count)
        }
        // The card owns the moment the set completes; the lane carries it after.
        inputs.setComplete = guidedShooting && allStepsDone && setCompleteDismissed
        inputs.isReady = isReady
        // Keep the standing disclosure on screen for as long as it's true.
        inputs.aiDisclosure = enhancingLook ? CameraVisionConsent.lookDisclosure : nil
        // Instructions, never scores — the coach's own phrasing, unprefixed.
        // (The step chip already says which shot this is.) "On-screen tips" off
        // now silences exactly this tier: failures and the shot's own name still
        // reach the lane, because those aren't coaching.
        let liveNudge = (allStepsDone || !settings.showNudge) ? nil : coach?.nudge
        inputs.coachTip = liveNudge?.message
        inputs.coachTipMoment = liveNudge?.moment
        inputs.coachTipPhraseCtx = liveNudge?.phraseCtx
        // The room-memory offer rides on the coach's own line and only on it:
        // no tip on the lane (tips off, set finished, look line in charge)
        // means no offer, by construction rather than by a second rule.
        inputs.coachTipDismissible = liveNudge?.moment != nil
            && coach?.dismissalOffer == liveNudge?.moment
        inputs.stepHint = (guidedShooting && !allStepsDone) ? currentStep?.hint : nil
        inputs.stepPhraseCtx = (guidedShooting && !allStepsDone)
            ? currentStep.map { CoachPhraseContext(subjectNoun: $0.title, detail: $0.hint) } : nil
        inputs.errorText = errorMessage
        // "Fundamentals checklist" off now means the coach line doesn't offer to
        // expand into the seven — the pills' setting, following the pills.
        inputs.hasDimensions = settings.showChecklist && !(coach?.statuses.isEmpty ?? true)
        return inputs
    }

    private var laneMessage: LaneMessage? { CameraLane.message(laneInputs, voice: settings.personality.voice) }

    /// Work the pro can't act on — a hairline on the lane, never words.
    private var backgroundBusy: Bool {
        uploading || analyzingLook || enhancingLook || savingClips > 0 || uploads.pendingCount > 0
    }

    /// Say what the new shot is for a beat, then hand the lane back to the coach.
    private func announceStepInLane() {
        guard guidedShooting, !allStepsDone, let step = currentStep else { return }
        stepTransient = step.hint
        stepTransientToken += 1
        let token = stepTransientToken
        Task {
            try? await Task.sleep(nanoseconds: UInt64(CameraLane.transientSeconds * 1_000_000_000))
            // A newer transient superseded this one — its own timer owns the lane.
            if stepTransientToken == token { stepTransient = nil }
        }
    }

    /// Same, for the coach's answer when the pro retires a room tip.
    private func announceRoomDismissInLane(_ text: String, undoable: Bool) {
        roomDismissTransient = text
        roomDismissUndoable = undoable
        roomDismissToken += 1
        let token = roomDismissToken
        Task {
            try? await Task.sleep(nanoseconds: UInt64(CameraLane.transientSeconds * 1_000_000_000))
            if roomDismissToken == token {
                roomDismissTransient = nil
                roomDismissUndoable = false
            }
        }
    }

    /// Same, for a light-match verdict.
    private func announceLightInLane(_ text: String, ok: Bool) {
        lightTransient = (text: text, ok: ok)
        lightTransientToken += 1
        let token = lightTransientToken
        Task {
            try? await Task.sleep(nanoseconds: UInt64(CameraLane.transientSeconds * 1_000_000_000))
            if lightTransientToken == token { lightTransient = nil }
        }
    }

    /// Present a sheet that a drawer just asked for. Raising the new flag in the
    /// same tick the drawer calls `dismiss()` loses the presentation entirely —
    /// SwiftUI is still tearing the old sheet down and drops the request — so the
    /// second one waits for the dismissal to land.
    private func presentAfterDrawer(_ present: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            present()
        }
    }

    /// The lane's action words, wired to what they already did as buttons.
    private func handleLaneAction(_ kind: LaneAction.Kind) {
        switch kind {
        case .retryUploads:
            if uploads.pendingCount > 0 || uploads.blockedCount > 0 {
                Task { await uploads.retryNow() }
            }
            if !failedClips.isEmpty { retryFailedClips() }
        case .terminalOptions:
            showTerminalDecision = true
        case .reviewBestShots:
            showBestShots = true
        case .recalibrate:
            driftDismissed = true
            calibrating = true
            cardMode = true
            calibrationStatus = nil
        case .dismissRoomTip:
            // The engine owns the record and the words; the lane only shows
            // the sentence it hands back.
            if let confirmation = coach?.dismissRoomTip() {
                announceRoomDismissInLane(confirmation, undoable: true)
            }
        case .undoRoomDismissal:
            if let confirmation = coach?.undoRoomDismissal() {
                announceRoomDismissInLane(confirmation, undoable: false)
            }
        }
    }

    // MARK: - Controls (the lane + the shutter row)

    private var controls: some View {
        VStack(spacing: 0) {
            if calibrating {
                // Calibration is a MODE, not a row: one job on screen, and the
                // coach + shutter step aside until it's set or skipped.
                calibrationControls.padding(.vertical, 16)
            } else {
                // The only states that earn a card instead of a lane — they're
                // decision points, and the shutter still works underneath them.
                // The requirement card comes FIRST in the shoot (one photo in),
                // the full-set card at the end; they can't both be true.
                if guidedShooting, allStepsDone, !setCompleteDismissed {
                    setCompleteCard
                } else if showRequirementCard {
                    requirementCard
                }

                CameraLaneView(
                    message: laneMessage,
                    backgroundBusy: backgroundBusy,
                    onAction: handleLaneAction,
                    onExpand: { showDimensions = true },
                    accessibilityValue: CameraLane.accessibilityValue(
                        message: laneMessage, statuses: coach?.statuses ?? [])
                )

                shutterRow
            }
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    /// "That's the one you need" — the shoot is already sufficient, one photo in.
    /// 🔴 This moment used to arrive only at the LAST step of a 4–5 shot guide,
    /// which is what made the whole set read as mandatory on a real client.
    private var requirementCard: some View {
        completionCard(
            headline: ProSessionPhotoRequirement.metHeadline,
            detail: ProSessionPhotoRequirement.metDetail(phase),
            dismiss: { requirementCardDismissed = true }
        )
    }

    /// "That's the full set" — finishing the whole guide is still a choice point
    /// (review what you have, or keep shooting extras). It was never required.
    private var setCompleteCard: some View {
        completionCard(
            headline: "That’s the full set",
            detail: "\(guide.steps.count) shots, all matched to the brief. Keep shooting if you want extras.",
            dismiss: { setCompleteDismissed = true }
        )
    }

    /// The shared shape of both "you can stop here" moments: what you have, then
    /// the two answers — finish, or carry on shooting extras.
    private func completionCard(
        headline: String,
        detail: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(BrandFont.display(19, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(detail)
                    .font(BrandFont.body(13.5))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            HStack(spacing: 8) {
                // "Review N" counts the shots the button actually OPENS — the
                // harvest tray. When there's nothing harvested, reviewing is not
                // the decision on offer; finishing is.
                let harvested = coach?.harvested.count ?? 0
                Button {
                    dismiss()
                    if harvested > 0 { showBestShots = true } else { requestExit() }
                } label: {
                    Text(harvested > 0 ? "Review \(harvested)" : "Done")
                        .font(BrandFont.display(14.5, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(BrandColor.accent,
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                Button { dismiss() } label: {
                    Text("Keep shooting")
                        .font(BrandFont.display(14.5, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(BrandColor.textPrimary.opacity(0.16), lineWidth: 1)
                        )
                }
            }
        }
        .padding(18)
        .background(BrandColor.bgPrimary.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(BrandColor.accent.opacity(0.42), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    /// Last frame + count · shutter · Done. Nothing above the shutter changes
    /// height, so this row never moves under a busy thumb.
    private var shutterRow: some View {
        HStack {
            HStack(spacing: 8) {
                // Record control — a silent clip → the frame scrubber. It keeps a
                // slot because it is the ONLY way to record, and recording is
                // capture; on hardware without it the slot collapses to the
                // thumbnail alone, which is the design's left slot exactly.
                // ⚠️ Practice is photos only for now. A PracticeShot has no
                // poster-frame columns, so a practice clip would land in the
                // library as a tile with nothing to show. Two nullable columns
                // and a poster copy on attach would fix it; that is a decision,
                // not a detail, so the control is hidden rather than half-built.
                if camera.recordingAvailable && !destination.isPractice {
                    Button { Task { await toggleRecording() } } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(BrandColor.textPrimary.opacity(0.7), lineWidth: 2)
                                .frame(width: 40, height: 40)
                            RoundedRectangle(cornerRadius: camera.isRecording ? 4 : 10, style: .continuous)
                                .fill(BrandColor.ember)
                                .frame(width: camera.isRecording ? 18 : 20,
                                       height: camera.isRecording ? 18 : 20)
                                .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
                        }
                    }
                    .accessibilityLabel(camera.isRecording ? "Stop recording" : "Record clip")
                }
                // Torch — the windowless-salon light. A per-shoot control, so it
                // lives on the shutter row, not in the tools tray.
                if camera.torchAvailable {
                    Button { torchOn.toggle() } label: {
                        Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(torchOn ? BrandColor.amber : BrandColor.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(BrandColor.bgPrimary.opacity(0.62), in: Circle())
                    }
                    .accessibilityLabel(torchOn ? "Turn the light off" : "Turn the light on")
                }
                lastFrameThumbnail
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            shutterButton

            // Accented once the phase HAS what it needs — one photo — not once
            // the guide's whole shot list is finished. "You're free to go" is a
            // fact about the requirement, not about the suggestions.
            Button("Done") { requestExit() }
                .font(BrandFont.display(15.5, .semibold))
                .foregroundStyle(requirementMet ? BrandColor.accent : BrandColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    /// The scrolling strip becomes one thumbnail with a count badge — proof the
    /// shot landed, and the door to reviewing it.
    @ViewBuilder private var lastFrameThumbnail: some View {
        if let shot = captured.first {
            Button {
                viewingMedia = FullscreenMedia.local(id: shot.id.uuidString, image: shot.image)
            } label: {
                Image(uiImage: shot.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(BrandColor.textPrimary.opacity(0.22), lineWidth: 1)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(captured.count)")
                            .font(BrandFont.mono(9))
                            .foregroundStyle(BrandColor.onAccent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(BrandColor.textPrimary, in: RoundedRectangle(cornerRadius: 5))
                            .padding(4)
                    }
                    // Unobtrusive proof the shot is safe but not server-side
                    // yet — never a blocker, just a small "still working on
                    // it" so a pro who glances down mid-service isn't left
                    // guessing. Clears itself the instant upload confirms.
                    .overlay(alignment: .topTrailing) {
                        if pendingSync(shot) {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(BrandColor.onAccent)
                                .padding(4)
                                .background(BrandColor.textPrimary.opacity(0.85), in: Circle())
                                .padding(3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(captured.count) captured this session")
            .accessibilityValue(pendingSync(shot) ? "still saving" : "")
            .accessibilityHint("Opens the last shot")
        }
    }

    /// Always full size, always tappable. The dim-and-shrink is gone: a ring that
    /// says "not yet" is guidance; a button that shrinks away is the app arguing
    /// with a professional.
    private var shutterButton: some View {
        Button {
            Task { await capture() }
        } label: {
            ZStack {
                if settings.showReadinessRing {
                    // Readiness ring, per the coach.
                    Circle()
                        .strokeBorder(readinessColor, lineWidth: 3)
                        .frame(width: 78, height: 78)
                        .animation(.easeInOut(duration: 0.3), value: readinessColor)
                    // Auto-capture "filling" ring — the photographer deciding,
                    // completing as the shot holds steady, then it fires. Gated
                    // by the same setting: the toggle used to silence the ring's
                    // COLOUR only, leaving this trim ring drawing regardless.
                    Circle()
                        .trim(from: 0, to: coach?.holdProgress ?? 0)
                        .stroke(BrandColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 78, height: 78)
                        .animation(.linear(duration: 0.12), value: coach?.holdProgress ?? 0)
                } else {
                    Circle()
                        .strokeBorder(BrandColor.textPrimary, lineWidth: 3)
                        .frame(width: 78, height: 78)
                }
                if uploading {
                    ProgressView().tint(BrandColor.textPrimary)
                } else {
                    Circle().fill(BrandColor.textPrimary).frame(width: 62, height: 62)
                }
            }
        }
        .disabled(uploading || scanningCard || camera.status != .ready)
        .accessibilityLabel("Take photo")
        .accessibilityValue(isReady ? "ready" : "not ready yet")
    }

    // MARK: - Dead-end states

    /// Permission denied and "the camera didn't start" — same template, different
    /// words, and both keep the session moving via the library.
    private func deadEnd(_ kind: CameraDeadEndView.Kind) -> some View {
        CameraDeadEndView(
            kind: kind,
            onPrimary: {
                switch kind {
                case .permissionDenied:
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                case .cameraFailed:
                    Task { await camera.start(frameDelegate: coach?.analyzer) }
                }
            },
            onChooseFromLibrary: { showLibraryPicker = true },
            onClose: { requestExit() },
            importing: importingLibrary,
            note: errorMessage
        )
    }

    // MARK: - "Choose from library instead"

    /// Push photos the pro already has through the SAME persist-then-upload
    /// pipeline a captured shot uses: durable on disk before anything
    /// network-shaped, then a background send. An import is no more losable
    /// than a shot, and no more able to block the camera than one either.
    private func importFromLibrary(_ items: [PhotosPickerItem]) async {
        guard !importingLibrary else { return }
        importingLibrary = true
        errorMessage = nil
        defer { importingLibrary = false }

        var added = 0
        var unreadable = 0
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let prepared = await CameraLibraryImport.prepare(raw) else {
                unreadable += 1
                continue
            }
            // Deliberately no card correction: that's a calibration of THIS
            // camera in THIS light, and a photo taken elsewhere must not have
            // it applied.
            //
            // capturedAt: deliberately nil, not import time. `PhotosPickerItem`'s
            // `loadTransferable(type: Data.self)` gives raw bytes with no reliable
            // access to the original photo's real capture date (that would need
            // parsing EXIF out of the JPEG itself, which this doesn't attempt) —
            // and claiming "when it was imported" AS "when it was captured" would
            // be exactly the kind of unverified claim this feature exists to be
            // honest about. No claim is more honest than a wrong one.
            guard let custody = SessionByteVault.writePendingUpload(
                prepared.jpeg, bookingId: custodyScope, phase: phase, focal: prepared.focal,
                capturedAt: nil
            ) else {
                errorSticky = true
                errorMessage = "Couldn’t save that photo, and it couldn’t be kept to retry."
                continue
            }
            if let thumb = await ImageDownsample.thumbnail(from: prepared.jpeg, maxPixel: 216) {
                captured.insert(CapturedShot(image: thumb, custodyURL: custody), at: 0)
            }
            // Custody is the app-level queue's now — it uploads in the
            // background and keeps going after this screen is gone.
            uploads.enqueue()
            added += 1
        }

        if unreadable > 0 {
            errorMessage = added == 0
                ? "Couldn’t read \(unreadable == 1 ? "that photo" : "those photos") — try different ones."
                : "Added \(added); couldn’t read \(unreadable)."
        }
    }

    // MARK: - Capture + upload

    private enum CaptureTrigger { case manual, auto }

    /// Take a shot. Manual = single capture, then the photographer check
    /// (post-capture QC on the real image) offers a retake if it failed.
    /// Auto = up to `autoCaptureAttempts` frames, keeping the first that
    /// passes QC — a photographer fires again; they don't keep the blink.
    /// Returns whether a shot was kept (uploaded + guide advanced).
    @discardableResult
    private func capture(trigger: CaptureTrigger = .manual) async -> Bool {
        // One capture at a time — the guided auto-shot and a manual shutter tap
        // can otherwise interleave (a second capturePhoto would be rejected by
        // the controller, but never let it get that far). Also stand off while a
        // card scan owns the capture pipeline (two in-flight captures collide →
        // "Couldn't take that photo.").
        guard !uploading, !scanningCard else { return false }
        // "Swipe down or SHOOT to dismiss" — the dimensions drawer is the only
        // surface the camera keeps running behind, so taking a shot has to close
        // it or the pro's confirmation lands under a sheet.
        showDimensions = false
        uploading = true
        errorMessage = nil
        errorSticky = false
        defer { uploading = false }

        if trigger == .auto { return await autoCaptureBest() }

        // A manual shutter press supersedes any auto-capture queued behind a
        // transient gate — clear it so releasing `uploading` here doesn't kick
        // off a redundant auto-shot right after this one. (Manual-path only:
        // the auto branch returned above.)
        defer { guidedCaptureQueued = false }

        // Whether this shot completes the current guided step — sampled at the
        // press, before the capture await moves the coach's readiness on.
        let advancesGuide = manualShotAdvancesGuide

        let data: Data
        // Sampled the instant the shutter actually fires — the truest "capture
        // time" available in this pipeline, ahead of QC evaluation (which runs a
        // blink-check model and can take a perceptible moment) and any retake
        // decision. Threaded through rather than resampled in `finalize`, so a
        // kept-anyway shot's claim reflects when it was taken, not decided on.
        let capturedAt: Date
        do {
            data = try await camera.capturePhoto()
            capturedAt = Date()
        } catch {
            errorMessage = "Couldn’t take that photo. Please try again."
            return false
        }
        shutterFeedback()
        let qc = await PhotoQC.evaluate(data, checkBlink: blinkCheckApplies)
        let focal = MediaFocalPoint(faceCenter: qc.focalPoint)
        if let reason = qc.retakeReason {
            pendingRetake = PendingRetake(data: data, reason: reason,
                                          advanceGuide: advancesGuide, focal: focal,
                                          capturedAt: capturedAt)
            return false
        }
        await finalize(data, advanceGuide: advancesGuide, focal: focal, capturedAt: capturedAt)
        return true
    }

    /// The auto-shot's burst: capture → QC → keep the first pass; if nothing
    /// passes, say why and let the hold re-arm (nothing uploads, the guide
    /// doesn't advance) — the subject is still in position for the next try.
    private func autoCaptureBest() async -> Bool {
        var best: (data: Data, qc: PhotoQCReport, capturedAt: Date)?
        for _ in 0..<CoachTuning.autoCaptureAttempts {
            guard let data = try? await camera.capturePhoto() else { break }
            // Sampled per-attempt, right at the shutter, so whichever frame wins
            // the burst carries ITS OWN true capture moment — not the moment the
            // whole burst finished.
            let capturedAt = Date()
            let qc = await PhotoQC.evaluate(data, checkBlink: blinkCheckApplies)
            if qc.passed { best = (data, qc, capturedAt); break }
            if best == nil || qc.sharpness > best!.qc.sharpness { best = (data, qc, capturedAt) }
        }
        guard let best else {
            errorMessage = "Couldn’t take that photo. Please try again."
            return false
        }
        guard best.qc.passed else {
            if let reason = best.qc.retakeReason {
                let voice = settings.personality.voice
                // The SPOKEN line gets exactly one flourish, from
                // `.retakeAnnounce` itself, around the canonical reason —
                // not a pack-rendered reason re-wrapped in another pack
                // flourish (that stacks two flourishes into one run-on).
                // A blink on a matched look speaks the look's own eyesClosed
                // line instead — the live stream has no blink signal, so the
                // retake IS the moment the lens saw that state (tovis-app
                // #974). Already a complete direction; no flourish stacked on.
                if settings.speak {
                    if best.qc.retakeMoment == .qcEyesClosed,
                       let lookLine = coach?.lookDirections.line(for: .eyesClosed) {
                        coach?.announce(lookLine)
                    } else {
                        let fallback = "\(reason) — let’s take that one again."
                        let line = CoachVoiceRenderer.render(
                            .retakeAnnounce, fallback: fallback,
                            ctx: CoachPhraseContext(detail: reason), voice: voice) ?? fallback
                        coach?.announce(line)
                    }
                }
                // The ON-SCREEN lane text stands alone — no wrapper moment
                // stacks on top of it — so rendering the QC moment directly
                // here is the correct single flourish for this string.
                let renderedReason = CoachVoiceRenderer.render(
                    best.qc.retakeMoment, fallback: reason,
                    ctx: best.qc.retakePhraseCtx ?? CoachPhraseContext(), voice: voice) ?? reason
                errorMessage = "\(renderedReason) — holding for another try."
            }
            return false
        }
        shutterFeedback()
        // auto only fires when ready for the step
        await finalize(best.data, advanceGuide: true,
                       focal: MediaFocalPoint(faceCenter: best.qc.focalPoint),
                       capturedAt: best.capturedAt)
        return true
    }

    /// Whether the blink check applies to the current shot (skipped when closed
    /// eyes are intended — lash work — or no face belongs in frame).
    private var blinkCheckApplies: Bool {
        guard let expects = activeExpectations else { return true }
        return expects.face != .absent && !expects.allowsClosedEyes
    }

    /// Shutter confirmation: a brief flash + a light tap.
    private func shutterFeedback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.18).delay(0.08)) { flash = false }
    }

    /// Whether a *manual* shot should count toward the current guided step. Only
    /// when the coach was actively judging THIS step and read the frame as ready
    /// — a freeform extra angle (no active step, or the coach not ready for it)
    /// must not skip the guide forward. Sampled at the shutter press.
    private var manualShotAdvancesGuide: Bool {
        activeExpectations != nil && isReady
    }

    /// Keep a shot: thumbnail, optionally complete the guided step, persist
    /// durably, then hand off to the background uploader. Returns once the
    /// photo is safely on disk — NEVER waits on the network, so `uploading`
    /// (which gates the shutter) clears again immediately regardless of
    /// connectivity. `advanceGuide` is decided at the capture site — always
    /// true for the guided auto-shot (it only fires when ready for the step),
    /// and gated on `manualShotAdvancesGuide` for a manual tap.
    private func finalize(
        _ data: Data, advanceGuide: Bool, focal: MediaFocalPoint?, capturedAt: Date
    ) async {
        // Card correction is baked in before persisting — a retry, or the
        // stranded-upload sweep after a relaunch, must resend exactly these
        // bytes rather than recompute a correction against whatever
        // `cardMatrix` happens to be by then.
        var payload = data
        if let cardMatrix, let corrected = await CardCorrection.apply(cardMatrix, to: data) {
            payload = corrected
        }
        // Durable BEFORE anything network-shaped. This is the one place a
        // session photo becomes safe — offline, a hung connection, a crash, a
        // kill, all the same from here on: the bytes are on disk. Everything
        // after this line is best-effort delivery, not the difference
        // between the shot existing or not. `capturedAt` persists here too —
        // it's the actual shutter moment, sampled by the caller, and must
        // survive a relaunch just like the bytes do (see SessionByteVault).
        // Bound the bytes BEFORE they are stored, so what the vault holds is
        // byte-for-byte what gets uploaded — the checksum claim, the retry after
        // a relaunch and the stranded sweep all read this same file. Full-sensor
        // captures are why uploads never landed (see `UploadImageBudget`); a
        // failed re-encode falls back to the original, since a photo that is too
        // big still beats no photo at all.
        let upload = await UploadImageBudget.prepare(payload) ?? payload

        let custody = SessionByteVault.writePendingUpload(
            upload, bookingId: custodyScope, phase: phase, focal: focal, capturedAt: capturedAt
        )

        // Strip-sized decode only — holding the full-sensor UIImage here pinned
        // ~100–200 MB per shot and jetsam-killed real sessions.
        if let thumb = await ImageDownsample.thumbnail(from: upload, maxPixel: 216) {
            captured.insert(CapturedShot(image: thumb, custodyURL: custody), at: 0)
        }
        keptThisSession += 1   // the phase requirement counts kept shots, not thumbnails
        if advanceGuide { markCurrentCaptured() }   // complete the guided shot + advance

        // A copy in the pro's own camera roll, when they asked for one. The
        // COLOUR-FINAL bytes, so what lands in Photos is what the library shows
        // — and add-only + raw-resource, so the original JPEG (EXIF orientation
        // and all) is preserved rather than re-encoded. A refusal here is
        // silent on purpose: the shot is already safe (or, on the branch below,
        // as safe as it's going to get), and an error line about a secondary
        // copy would outrank the shoot. Independent of the vault write below —
        // this is a copy on the DEVICE, nothing to do with server custody.
        //
        // Only on this path — a retry re-sends the vault file directly, and a
        // library import came FROM Photos, so neither double-saves.
        //
        // ⚠️ Saves `payload`, NOT the budgeted `upload`: the pro's own copy is
        // the full-resolution one. The budget exists to get bytes across a salon
        // connection, and there is no connection involved in writing to the
        // device's own library.
        if destination.isPractice && savePracticeToPhotos {
            _ = await PhotoLibrarySaver.save(payload)
        }

        guard custody != nil else {
            // Nothing is left holding this photo for the SERVER — no queue
            // row, no vault file, no retry. It is the ONE message in this
            // file not backed by state, so it must not time out of the lane
            // like the recoverable ones do.
            errorSticky = true
            errorMessage = "Couldn’t save that photo, and it couldn’t be kept to retry."
            return
        }

        // Custody is the app-level queue's from here. It uploads one photo at
        // a time, in the background, and keeps going after this view is gone,
        // after the session is closed out, and across a relaunch.
        uploads.enqueue()
    }

    /// Drop every refused photo currently queued — the pro's explicit choice.
    /// A method, not an inline closure at the call site: see `pendingSync`.
    private func discardRefusedPhotos() {
        uploads.discardBlocked()
    }

    /// Whether this thumbnail's bytes are still owed to the server.
    ///
    /// Asks the QUEUE, not the view's own state: the queue confirms uploads long
    /// after this view stopped driving them, and often while it isn't on screen
    /// at all, so a badge cleared by a callback would go stale the moment the
    /// camera was reopened.
    ///
    /// ⚠️ Deliberately a lookup and NOT a `.onChange` modifier keeping a local
    /// copy in step. This body's modifier chain is already at the edge of what
    /// the compiler type-checks in reasonable time (`TerminalUploadDialog` and
    /// `RetakeDialog` are ViewModifiers for that reason), and adding one more
    /// modifier failed the App target build on CI twice — reported against an
    /// unrelated expression ~100 lines away, which is how this presents.
    private func pendingSync(_ shot: CapturedShot) -> Bool {
        uploads.isPending(shot.custodyURL)
    }

    /// Write refused photos to the pro's own library, then let them go. This is
    /// the escape the retry loop never had: the server won't take these bytes, so
    /// the only honest options are "leave with the photo" or "drop it" — and the
    /// pro picks, rather than losing it silently on exit.
    private func saveTerminalUploadsToLibrary() async {
        let doomed = uploads.blockedPayloads()
        guard !doomed.isEmpty, !savingToLibrary else { return }
        savingToLibrary = true
        defer { savingToLibrary = false }

        var saved = 0
        for url in doomed {
            guard let data = await Task.detached(
                priority: .userInitiated,
                operation: { SessionByteVault.read(url) }
            ).value else { continue }
            if await PhotoLibrarySaver.save(data) { saved += 1 }
        }

        guard saved == doomed.count else {
            // Keep the bytes: a partial save must not discard what didn't land.
            errorMessage = saved == 0
                ? "Couldn’t save to your photos — check Tovis has photo access."
                : "Saved \(saved) of \(doomed.count). The rest are still here."
            return
        }
        // Everything the pro asked for is now in their library, so the queue may
        // let those bytes go. A refusal that arrived DURING the save isn't in
        // `doomed` and keeps its own custody.
        uploads.discardBlocked()
        errorMessage = nil
    }

    private func toggleRecording() async {
        if camera.isRecording {
            errorMessage = nil
            await stopRecordingAndSave(review: true)
        } else {
            camera.startRecording()
        }
    }

    /// Stop the rolling recording and SAVE it — recording is capture, not
    /// review. The clip moves into the ClipVault immediately (tmp is not safe
    /// custody), uploads in the background, and optionally opens the scrubber
    /// so the pro can pull a still while it saves.
    private func stopRecordingAndSave(review: Bool) async {
        let url: URL
        do {
            url = try await camera.stopRecording()
        } catch {
            // The controller owns recovery: every failure path in it (raise,
            // dropped callback → watchdog) rolls `isRecording` back itself, so
            // the button is usable again no matter which path failed.
            errorMessage = "Couldn’t finish that recording. Please try again."
            return
        }
        let stored = ClipVault.stash(url, bookingId: custodyScope, phase: phase)
        if review { scrubClip = ScrubClip(url: stored) }
        uploadClip(stored, phase: phase)
    }

    /// Upload one vaulted clip: bake the card correction in, attach a poster
    /// frame (so the gallery tile is a real image, not a spinner), confirm. On
    /// failure the clip stays in the vault and joins the retry pill — a flaky
    /// connection must never lose a take the pro already recorded.
    private func uploadClip(_ url: URL, phase: MediaPhase) {
        // Clips are a session-only feature for now — the record control is
        // hidden while practising (a PracticeShot has nowhere to keep a poster
        // frame). Guarded here as well so a stranded clip swept up under the
        // practice scope can never be posted to a booking that didn't shoot it.
        guard let clipBookingId = destination.bookingId else { return }
        guard ClipVault.beginUpload(url) else { return }
        savingClips += 1
        let matrix = cardMatrix
        let client = session.client
        Task {
            defer { savingClips -= 1 }
            var uploadURL = url
            if let matrix, let corrected = await CardCorrection.applyToVideo(matrix, at: url) {
                uploadURL = corrected
            }
            defer {
                if uploadURL != url { try? FileManager.default.removeItem(at: uploadURL) }
            }
            let poster = await ClipVault.poster(for: uploadURL)
            do {
                try await client.proMedia.uploadSessionVideo(
                    bookingId: clipBookingId, phase: phase,
                    fileURL: uploadURL, posterData: poster
                )
                ClipVault.remove(url)
                session.signalRefresh()   // the hub's gallery refreshes
            } catch {
                ClipVault.endUpload(url)
                failedClips.append((url: url, phase: phase))
                errorMessage = "Couldn’t save the clip — it’s kept here to retry."
            }
        }
    }

    /// Re-attempt every failed clip upload; whatever fails again re-queues.
    private func retryFailedClips() {
        guard savingClips == 0, !failedClips.isEmpty else { return }
        errorMessage = nil
        let pending = failedClips
        failedClips = []
        for clip in pending { uploadClip(clip.url, phase: clip.phase) }
    }

    private var phaseLabel: String {
        if destination.isPractice { return "Practice" }
        switch phase {
        case .before: return "Before"
        case .after: return "After"
        case .other: return "Session"
        }
    }

    /// Shutter ring colour from the coach's readiness — the same three meanings
    /// the lane uses: alert → warn → shooting.
    private var readinessColor: Color {
        guard let readiness = coach?.readiness else { return BrandColor.textPrimary }
        switch readiness {
        case ..<CoachTuning.readyWarnThreshold: return LaneTone.alert.color
        case ..<CoachTuning.readyThreshold: return LaneTone.warn.color
        default: return LaneTone.accent.color
        }
    }
}

/// How the AI photographer guides the pro — the toggle sheet (gear in the camera).
/// Not `private` — `RootView`'s `TOVIS_DEBUG_OPEN_COACH_SETTINGS` hook (DEBUG
/// only) presents this straight from the root, no camera/session/booking
/// required, for the same reason as `DebugExportSample`.
struct CoachSettingsSheet: View {
    @Bindable var settings: CoachSettings
    /// DEBUG tuning console entry — dismisses this sheet and opens the console
    /// over the LIVE camera (this sheet pauses it; tuning needs frames).
    var onOpenTuning: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Shot guide", isOn: $settings.showGuides)
                    Toggle("Swipe up for all seven", isOn: $settings.showChecklist)
                    Toggle("On-screen tips", isOn: $settings.showNudge)
                    Toggle("Speak tips aloud", isOn: $settings.speak)
                    Toggle("Haptic feedback", isOn: $settings.haptics)
                } header: {
                    Text("How it guides you")
                } footer: {
                    Text("The AI photographer coaches lighting and composition in real time, one instruction at a time. Swipe the coach line up to see all seven fundamentals at once.")
                }

                Section {
                    Picker("Coach personality", selection: $settings.personality) {
                        ForEach(CoachPersonality.allCases) { personality in
                            Text(personality.displayName).tag(personality)
                        }
                    }
                    Text(CoachVoiceRenderer.renderCanonical(
                        .laneSetComplete, voice: settings.personality.voice))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .italic()
                } header: {
                    Text("Coach voice")
                } footer: {
                    Text("Changes tone only — the same corrections, at the same moments, in a different voice.")
                }

                Section {
                    Toggle("Auto-capture each shot", isOn: $settings.autoCapture)
                    Toggle("Readiness ring", isOn: $settings.showReadinessRing)
                    Toggle("Level / horizon", isOn: $settings.showLevel)
                    Toggle("Rule-of-thirds grid", isOn: $settings.showGrid)
                    Toggle("Feed-crop guide (9:16 feed · 4:5)", isOn: $settings.showCropGuide)
                    Toggle("Extra best-shots (background)", isOn: $settings.autoHarvest)
                } header: {
                    Text("On the camera")
                } footer: {
                    Text("Auto-capture takes each guided shot for you once it looks great and holds steady — like a photographer pressing the shutter at the right moment. You can always tap the shutter yourself.")
                }

                Section {
                    Toggle("AI-enhance matched looks", isOn: $settings.aiEnhanceLooks)
                } header: {
                    Text("AI analysis")
                } footer: {
                    Text("When you match a photo, Claude also reads what geometry can't measure — expression, head angle, hands, light direction. \(CameraVisionConsent.lookDisclosure)")
                }

                #if DEBUG
                Section("Developer") {
                    Button("Coach tuning console") {
                        dismiss()
                        onOpenTuning?()
                    }
                    .disabled(onOpenTuning == nil)
                }
                #endif
            }
            .navigationTitle("Camera coaching")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(BrandColor.accent)
        .presentationDetents([.medium, .large])
    }
}
