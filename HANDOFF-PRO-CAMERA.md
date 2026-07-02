# Tovis iOS — PRO app + AI Photographer camera — RESUME HERE

> **Fresh-session entry point for the active workstream** (pro side + the AI camera).
> The big `HANDOFF.md` is the deep reference (client app history + full per-phase detail);
> this file is the short, current "where we are / what's next." Written 2026-06-28.
> Companion memory: `ios-pro-app-and-ai-camera` (auto-loaded via MEMORY.md).

## TL;DR

The **client** iOS app was already feature-complete (on TestFlight). This workstream added the
**PRO** side to the same app + an **"AI photographer" session camera**. All shipped work is committed
on `tovis-ios` `main`; the one backend change is **merged** (`tovis-app` PR #427).

---

## 🟢 RESUME HERE (2026-07-01, pass 6) — audit fixes + "photographer quality every time" build · next = DEVICE TUNE (now console-driven)

**Two passes on 2026-07-01 (all on `tovis-ios` main; 81 TovisKit tests + Debug/Release green; NONE device-verified):**

1. **Full camera audit → all 8 findings fixed (`0d7cf6f`)** — details in memory `ios-camera-audit-2026-07-01`.
   Highlights: `TovisConfig.local` LAN-IP revert (⚠️ never commit a device-test IP), level/horizon restarts after
   the scrubber round-trip (`CoachEngine.start()` from `.task`), tap-to-focus reverts to continuous AF via a
   subject-area-change observer, capture re-entry guard, harvest cap now bounds the UNREVIEWED tray, WB target box
   maps the exact sampled sensor region, failed-upload retry queue ("Retry N unsaved photos"), `.interrupted`
   status + auto-resume, spoken tips through the silent switch (`.playback` session), temp-clip cleanup.
2. **Quality-guarantee features (user-approved plan, 6 commits):**
   - `3178158` **Face-priority auto-exposure** — camera meters the coach-detected face + highlight-protect bias
     (`CoachTuning.faceExposureBias`); stands down for tap-to-focus/AE-AF-lock. ⚠️ upright→sensor point mapping
     `(x,y)→(y,1−x)` needs hardware verification (like the level sign).
   - `ceb05f4` **Post-capture QC + auto-burst** — `PhotoQC` verifies the ACTUAL capture (sharpness on subject,
     exposure band, CIDetector blink w/ both-eyes rule). Manual shot → "Photographer check" retake dialog;
     auto-shot → up to 3 frames, keeps first QC pass, else re-arms without advancing. Shared math extracted to
     `FrameMath` (analyzer + QC + light-match use ONE implementation).
   - `60b5a19` **Per-step ShotExpectations** — steps declare face required/absent, fill band, detail, closed-eyes-
     intended; coaches judge "ready for THIS shot" (back-of-cut ignores stray faces; detail shots demand more
     sharpness, skip background; lash eyes-closed steps skip the blink check).
   - `91ab9e5` **Before/after light matching + per-booking WB** — before-references stamped (luma+warmth), live
     "match the before" pill phrases the biggest mismatch; gray-card WB persists per booking (UserDefaults
     `tovis.camera.wb.{bookingId}`) and auto-re-applies on the AFTER shoot.
   - `bcfb9c3` **Crop-safe guides** — 4:5 feed + 9:16 reel boxes mapped through the preview layer (settings toggle).
   - `f0f5bdb` **DEBUG tuning console** — `CoachTuningHUD`: live raw signals + ~22 threshold sliders over the LIVE
     camera (half-height sheet, background interaction), "Copy values" → paste back into `CoachTuning.swift`.
     Tunable statics are now `nonisolated(unsafe) static var`. Entry: coaching settings → Developer.

3. **Card-applied color correction + card-anchored exposure (`cbc4d83`)** — the calibration card now changes the
   pixels (the per-room adaptation layer; user's stated goal). Two-shot scan (calibration → **Card** mode →
   Scan card): shot 1 neutral band → WB lock; shot 2 under locked WB → gain-normalized LINEAR-space chromatic 3×3
   (+ gray-ramp validity gate) + **exposure EV anchor** at the camera (composes w/ face-metering bias).
   `CardCorrection` bakes the matrix into EVERY uploaded JPEG (captures, retries-once-only, best shots, scrubber
   stills) via CIColorMatrix in linear working space. Persists per booking (`tovis.camera.cardcal.{bookingId}`).
   TovisKit: `CardGeometry` (mirrors `docs/calibration/generate_card.py`), sRGB↔linear, `chromaticCorrection`,
   `exposureBiasEV`, `isPlausible`, `looksLikeGrayRamp` — **90 tests green**. ⚠️ Still on the PLACEHOLDER nominal
   profile — measure a real print batch (incl. the band gray) before trusting fine color. Video clips uncorrected.
   **Design decision (user-confirmed): CoachTuning = the universal rubric (one-time device tune, ships for
   everyone); the CARD = the per-room/per-pro adaptation (WB + matrix + exposure at runtime).** Don't build
   per-salon tuning profiles.
   **+ `d35e7de` follow-ons:** card AUTO-DETECTION (Vision rectangle → CIPerspectiveCorrection warp, anywhere in
   frame; box = fallback; upside-down retried 180°-flipped via the ramp gate), LIGHT-DRIFT re-scan nudge
   (scan-time warmth persisted; sustained drift → one-tap "re-scan the card" pill; `calibrationDriftWarmth/
   Seconds`), and saved VIDEO clips now corrected too (AVMutableVideoComposition re-export, raw-clip fallback).
   **Batch-measurement workflow (user-confirmed): founder owns ONE real ColorChecker; per print batch,
   photograph Tovis card + ColorChecker side-by-side in the same light → derive the batch's true swatch values
   → new `CardReferenceProfile` keyed by NFC batch id. Pros only ever touch their Tovis card.**

4. **Trending shot packs + pose direction (`b895f64` + tovis-app PR #453 OPEN)** — the "smart/viral" camera.
   Server-driven pose/shot recipes (`lib/pro/cameraShotPacks.ts`, `GET /pro/camera/shot-packs`): trend CONTENT
   updates server-side weekly (later: generated from Looks engagement); the app ships the measurable pose-rule
   VOCABULARY (handNearFace/bothHandsVisible/shouldersTilted/shouldersLevel/faceNearShoulder) and drops unknown
   kinds (fixture proves forward-compat decode). `PoseSignal` now carries body joints; `PoseCoach` evaluates the
   step's rules with aspect-corrected geometry — first unmet rule = the spoken/shown directive, readiness held at
   0.45 until the subject is IN the pose (auto-capture waits for it). "Trending" flame menu in the guide bar
   switches standard set ↔ matching packs. v1 packs: The Reveal · Over-Shoulder Glance · Claw & Sparkle · Golden
   Glow. **MERGE #453 + deploy before the menu lights up** (camera falls back to standard guides silently).

5. **Match a look (`de241d4`)** — pro picks ANY photo (screenshot of a viral post) via the **Inspo menu**
   (formerly "Trending"; now always shown) → measured ON-DEVICE (nothing uploads) with the shared extraction
   (`VisionDetect` + `FrameMath.segmentation` + `PoseGeometry` w/ per-image aspect) → synthesized into the same
   brief vocabulary (pose rules from measured geometry, fill band ±0.12, detail heuristic, closed-eye reference
   skips blink QC) → one-step "Match the look" guide: the reference ghosts via onion-skin, the light-match pill
   targets the reference, auto-capture waits for the pose. `ReferenceLook.swift` + `ReferenceLookAnalyzer`.

6. **✅ PHASE D SHIPPED (2026-07-01) — Claude vision: AI-enhanced look briefs + wrap-up set critique.**
   Backend = **tovis-app PR #454 (OPEN)**, branch `feat/camera-claude-vision`: `POST /pro/camera/look-brief` +
   `POST /pro/camera/set-critique` — Anthropic key SERVER-SIDE only (`ANTHROPIC_API_KEY`; model default
   `claude-opus-4-8`, override `CAMERA_VISION_MODEL`), images analyzed in-flight, never stored/logged;
   `lib/pro/cameraVision.ts` owns prompts/structured-output schemas/sanitizers (unknown pose kinds filtered
   server-side too); **free w/ daily cap** (25 look-briefs, 10 critiques /pro/day, `lib/rateLimit` buckets).
   ⚠️ **MERGE #454 + set `ANTHROPIC_API_KEY` in Vercel + deploy** before the buttons work in prod (until then:
   look enhance fails silently to the measured brief; critique shows a retryable error). Native (this repo):
   - **Look enhance:** picking a Match-a-look photo ALSO sends it to Claude (after the measured brief is already
     live — enhance failing costs nothing): merged pose rules (measured wins conflicts incl. the shoulders
     level/tilted pair; unknown kinds dropped like packs) + a **tappable/spoken AI direction card**
     (`aiDirectionCard`: expression / head angle / hands / light lines). `ReferenceLook.enhanced(with:)` +
     `.measuredSummary`; coaching-settings toggle "AI-enhance matched looks" (`CoachSettings.aiEnhanceLooks`).
   - **Wrap-up critique:** "Photographer's review" card in the session-hub wrap-up (`critiqueSection`) —
     downloads the set from signed URLs (≤10, AFTERs prioritized), downscales client-side (1024px q0.6), POSTs;
     renders overall + strengths + per-photo verdict chips (portfolio/keep/retake + retake tip; unknown verdicts
     render neutrally) + "Review again".
   - **Consent (user-picked copy):** ONE persisted opt-in for both flows (`tovis.camera.ai.consented`,
     `CameraVisionConsent` in `Tovis/CameraVision.swift`), first-use confirmationDialog per flow: "This photo
     leaves your device for AI analysis by Claude (Anthropic). It isn't stored." (plural variant for the set) +
     standing caption lines (enhance progress row, critique card, settings footer). Declining the look dialog
     flips the settings toggle off.
   - TovisKit: `Models/ProCameraVision.swift` (pose rules REUSE `ProShotPackPoseRule`), `ProCameraService.
     lookBrief/setCritique`, fixtures `proLookBrief.json`/`proSetCritique.json` w/ unknown-kind + unknown-verdict
     forward-compat decode tests; endpoints documented in `docs/PRO-BACKEND-CONTRACTS.md` ("Camera" section).
     **93 TovisKit tests + Debug/Release green; contract 27. NOT sim-verified** (needs #454 deployed or a local
     dev server with `ANTHROPIC_API_KEY`).

**▶️ NEXT = the on-device tune pass** (now cheap: open the console, walk window/mixed/tungsten salon light, drag
sliders, copy values back into `CoachTuning.swift`). Verify on hardware: level sign, face-exposure point mapping,
onion-skin alignment, photo EXIF orientation in the web gallery, WB gains behavior, **and the card scan flow
(print the v0 PDF on any decent printer to smoke-test alignment/glare handling before the real Zebra batch)**.
Then (discussed, not built): directive per-step guidance language, torch-as-fill suggestion, publish
before/after → Looks funnel, NFC card identify + measured batch profiles (B4 remainder — blocked on physical
cards). (Phase D Claude vision = ✅ SHIPPED, item 6 above.)

> Corrections to the block below (pass 5 predates 2026-07-01 work): "AE/AF lock + tap-to-focus" and "color
> accuracy / white balance" are NOW BUILT (`e73e966` + pass-6 work); the OOM crash is fixed (`e3f88ae`).

---

## (prior) 🟢 RESUME (2026-06-30, pass 5) — CAMERA made photographer-grade (coach overhaul + before/after)

**The "AI photographer" camera went from a passive shutter to a directed, quality-gating coach.** Two commits on
`tovis-ios` main; Debug+Release + `swift test` 66 green. **NONE of it is device-verified** — the Simulator has no
camera, and every perception threshold was set from reasoning + the fundamentals doc, NOT hardware. **The single
highest-value next step is the on-device tune pass** (see "Make it FULLY FUNCTIONAL" below; all knobs live in
`Tovis/CoachTuning.swift`).

- **`104a8e2` — direct the shoot + fundamentals weighting.**
  - **Camera pauses while picking photos** (was still capturing + auto-harvesting behind the review sheet/scrubber/
    settings). New `CameraController.resume()` ↔ `stop()`; `ProCapturePhotosView.isReviewing` drives it.
  - **True camera level** via CoreMotion (`Tovis/DeviceLevel.swift` → `DeviceLevelProvider`, gravity→roll) + an
    on-screen **horizon line** that snaps green when level. New `LevelCoach`; `PoseCoach` trimmed to clipping-only
    (shoulder-tilt inference deleted — device gravity is far more reliable). `FrameContext.deviceTilt` threaded from
    the engine into the analyzer via a small lock.
  - **Fundamentals HUD** — live Light/Level/Frame/Focus/Clean pills (green/amber/red) so the pro SEES what's not
    photographer-worthy. `CoachResult.statuses` / `CoachEngine.statuses`.
  - **Capture quality-gate** — shutter dims/shrinks when the coach reads the shot as weak; **flash + haptic** confirm.
  - **ShotGuides** (`Tovis/ShotGuide.swift`) — directed per-service shot list (hair/nails/lashes-brows/face/generic),
    resolved from the booking's base service name, X-of-N progress, advanced by each capture. Bar in the camera top.
  - **Doc-driven tuning** (from `~/Downloads/photography-fundamentals-for-beauty.md`): readiness is now
    **importance-weighted** (`CoachCategory.weight` — light 1.6 / focus 1.4 > background/pose); the surfaced fix is
    the biggest *weighted* deficiency. Added **"fill the frame"** (subject-fill from the existing person
    segmentation; `segment()` now returns clutter + subjectFill from ONE Vision pass) + **highlight-protection**
    exposure bias (lumaIdeal 0.47, tooBright 0.78). Guide copy aligned to real money-shots (hair back-of-cut; makeup
    eyes/catchlights/lips).
- **`74a5daf` — before/after matching (the transformation payoff).**
  - **Onion-skin**: shooting AFTER ghosts the matching "before" over the live preview (opacity slider + cycle), auto-
    following the ShotGuide step. References = the booking's before IMAGE rows, passed from the hub (AFTER only).
  - **`Tovis/BeforeAfterCompareView.swift`** — interactive comparison slider (draggable divider), surfaced in the
    **wrap-up screen**, paged across matched before/after pairs.

### ⚠️ Camera open items (post-overhaul)
1. **DEVICE TUNE PASS (do first).** Watch the ring + nudges on a real iPhone; adjust `CoachTuning.swift`
   (sharpness/clutter references, luma bands, `tiltBadDegrees`, `minSubjectFill`, harvest/ready thresholds). The
   level-coach left/right sign may need flipping (commented in `LevelCoach`). Onion-skin scaledToFill alignment vs
   the AVCaptureVideoPreviewLayer gravity needs an eyeball check.
2. **Still TODO from the fundamentals doc** (real, not built): **color accuracy / white balance** — "sacred" for
   beauty, but needs a reference → this is exactly the planned **B4 ColorChecker + NFC card**; a lightweight
   "mixed-light / strong color-cast" warning is the only on-device approximation (false-positive risk). **Video as
   transformation** (hook→process→hold-the-reveal→loop, ASMR) — our video path is just silent-clip→scrubber; a
   guided "transformation reel" is unbuilt. **Catchlights** (makeup eye sharpness) — niche.
3. **Publish before/after → portfolio/Looks from the comparison slider** (consent-gated; B3b already unlocks it) —
   natural next funnel step; not built.

### 🎨 ColorCoach shipped + research-driven roadmap (`fcb7112`)
Two research docs in `~/Downloads/` (`photography-fundamentals-for-beauty.md` + `compass_artifact_*.md`) drove the
coach work. **`fcb7112` — ColorCoach**: flags **mixed light** (warm↔cool spread across vertical thirds — the named
#1 real-world killer), **green/fluorescent** cast, and **warm/yellow/incandescent** cast (daylight ~5000–5600K is the
beauty target); new COLOR pill in the HUD; thresholds in `CoachTuning`. **Durable, camera-relevant items still
UNBUILT** (from the 2nd doc, all buildable on-device — good next picks, in rough value order):
1. **AE/AF lock + tap-to-focus** — the doc calls "lock focus & exposure so the camera stops hunting" a durable best
   practice; we have neither. Add tap-to-focus/expose on the preview + an AE/AF-lock toggle (`AVCaptureDevice`
   focus/exposure modes + `setFocusPointOfInterest`). High value, self-contained.
2. **Crop-safe framing guide** — Reels crop to 4:5 (feed) / 3:4 (grid); keep the money shot centered. A toggleable
   4:5/3:4 safe-area overlay (sibling to the thirds grid).
3. **Macro hint on "Detail" guide steps** (nails/lashes) + "avoid Portrait mode on detail work" — copy/guide only.
4. **Before/after credibility = same LIGHT too** (not just angle, which onion-skin covers) — surface the before's
   measured warmth/luma so the after can be matched; ties ColorCoach + onion-skin together.
Non-camera (product) items from the research: photo/video **release in the intake form** (we have per-session B3b
consent; a stored signed release is broader), **portfolio→booking funnel** (bio keyword + one-tap booking + Highlights
funnel), **carousel/Reel content strategy** (3-step transformation carousel, save/send-optimized hooks). These are
web/product, not the native camera.

> Everything below this block predates the camera overhaul. The Phase-S / header / calendar status is unchanged.

---

## 🟢 RESUME HERE (2026-06-29, pass 4) — PHASE S: full booking/session flow ✅ DONE (S1–S4) · next = sim-verify + deferred bits

**Phase S (the native session/booking flow) is built + committed on `tovis-ios` main; `swift test` 65; Debug+Release
green; contract 26.** None of it is sim-verified yet (keychain wipe on reinstall → re-login each rebuild).

- **S1 — session state machine** (`a9eace2`): `ProSessionHubView` rebuilt into the web 4-step flow
  (`app/pro/bookings/[id]/session/page.tsx`). `ProSessionFlow.screenKey` (ported pure + unit-tested) maps the
  server's `effectiveSessionStep` → one of five screens with the persistent 4-step rail (`ProSessionStepRail`):
  Consultation → Waiting + Before photos → Service in progress → Wrap-up → Done/Terminal. `ProConsultationFormView`
  = 1:1 port of `ConsultationForm` (line items from booking services + add-from-catalog + edit price/duration/notes +
  send for approval + undeliverable notice). In-person fallback wired (`recordInPersonDecision`). New TovisKit:
  `ProSessionFlow` + `ProSessionCloseout` (pure) + `ProConsultationServices` model; `ProSessionState` extended with
  consultation + aftercare; `ProSessionService` consultationServices/sendConsultationProposal/recordInPersonDecision.
- **S2 — wrap-up Mark Paid** (`f30e447`): wrap-up closeout checklist (read in S1) + in-person "Mark as paid" control
  on the payment row (web `MarkPaidButton`) → `POST /checkout/mark-paid`. `ProBookingService.markPaid` + `waiveCheckout`
  (waive wired but web surfaces no button). `ProPaymentSettings.manualCollectableMethods` (ordered manual methods).
- **S3 — aftercare authoring** (`5339691`): `ProAftercareAuthorView` (web `/pro/bookings/[id]/aftercare`) — notes +
  recommended products (name/link/note) + rebook recommendation + Save draft / Send to client. `ProAftercareDetail`
  model + `ProAftercareSaveRequest`; `ProBookingService.aftercareDetail/saveAftercare`. Wrap-up + Done push to it;
  the **aftercare LIST card now deep-links here** (was booking detail).
- **S4 — create booking** (`c153479`): `ProNewBookingView` (web `/pro/bookings/new`) — pick existing client + salon
  service + salon location + date/time → `POST /pro/bookings`. `ProBookingService.createBooking`. A **`+` toolbar
  entry on the bookings list** opens it.

### ⚠️ Phase S deferred vs web (pick these up next)
- ✅ **New-booking open-slot picker — DONE 2026-06-30 (`3df5ebb`).** `ProNewBookingView` now fetches the pro's real
  open slots for the chosen service+location+date from **`GET /api/v1/availability/day`** (reused via the existing
  `BookingService.day` + `ProProfileService.myProfile().id`), rendered as tappable time chips in the location zone;
  a "custom time" toggle keeps the free date/time + overrides for off-grid. **No new endpoint/model — pure reuse.**
  ⚠️ The handoff's old "`GET /pro/openings`" reference was a misnomer (that route is the **last-minute openings
  manager**); the web new-booking form itself uses a plain `datetime-local`, so this is a native improvement. **This
  lays the `availability/day` groundwork the aftercare rebook slot mode needs (below).** NOT sim-verified yet.
- ✅ **Aftercare "Next booking date" rebook mode — DONE 2026-06-30 (`52e59a5`).** `ProAftercareAuthorView` now offers
  all three web modes (None / Next booking date / Booking window). The slot picker was extracted to a shared
  **`ProOpenSlotPicker`** (used by both new-booking + aftercare; `ProNewBookingView` refactored onto it — no dup
  logic). Aftercare `load()` also pulls the booking detail (rebook service/location/duration) + the pro's id;
  `save()` sends `rebookedFor` + `rebookSlot {offeringId,locationId,locationType,startsAt,endsAt}` for BOOKED.
  ⚠️ MOBILE rebook may not return slots without a client address (SALON fully supported). NOT sim-verified yet.
- ✅ **Aftercare smart reminders — DONE 2026-06-30 (`d97d02e`).** "Smart reminders" section: rebook reminder
  (1/2/3/7 days before, gated to the Next-booking-date mode + a picked slot) + product follow-up (3/7/14/30 days
  after); wired into the save body. **Catalog product picker = N/A** — the web aftercare form has no catalog picker
  (always sends `productId: null`), so products stay external (name+link+note); the old "deferred catalog picker"
  note was speculative. NOT sim-verified yet.
- ✅ **Consultation proof card — DONE 2026-06-30 (`b22b40c`).** The "Consultation proof recorded" card (decision ·
  method · recorded-at) now renders on the consultation + waiting screens. 🔶 **Backend companion = tovis-app PR
  #441 (OPEN)** adds the proof to the `/session/state` payload (`consultationApproval.proof {decision,method,actedAt}`;
  audit-only destination/recordedByUserId excluded → PII-free). **MERGE + redeploy prod before Release shows the
  card** (the native model is backward-compatible — the card just stays hidden until the field arrives). The
  consultation **prefill** notes/proposedTotal still come only from booking serviceItems + subtotal/total (the
  proposal's *notes* aren't in the state payload) — minor, not surfaced.
- ✅ **New-booking new-client creation — DONE 2026-06-30 (`6f98898`).** `ProNewBookingView` has an Existing/New
  client toggle; New collects first+last name+email (required) + phone (optional) and creates the client inline
  (server sends a secure claim invite). No backend change — `POST /pro/bookings` already accepts an inline `client`
  object; `createBooking` now takes `clientId?` OR `client:ProNewBookingClient?`.
- ✅ **New-booking MOBILE — DONE 2026-06-30** (Workstream 1; 3 commits). `ProNewBookingView` now does SALON **and**
  MOBILE (pro mobile base + client service address; saved-address picker OR new address via the shared
  `PlacesAddressSearchField`). Details under **Workstream 1** below. NOT sim-verified yet.

### ▶️ NEXT WORKSTREAMS — start each in a FRESH session (in order)
> Phase S + all the small deferred items are DONE. **Workstream 1 (MOBILE) is now DONE** (2026-06-30). One larger item
> remains: **multiple co-equal base services** (a core backend invariant change — investigate + get sign-off first).

#### ✅ Workstream 1 — New-booking MOBILE — DONE 2026-06-30 (iOS only, no backend change)
`ProNewBookingView` now supports MOBILE bookings (was SALON-only). A MOBILE booking = the pro's `MOBILE_BASE` location
+ the client's service address. **3 commits on `tovis-ios` main; Debug+Release green; `swift test` 66.** NOT
sim-verified yet.
- **What shipped:** An **In-salon / Mobile** segmented toggle. MOBILE filters offerings to `offersMobile` (mobile
  price/duration in labels + scheduling) and locations to `type == "MOBILE_BASE"`. An **address sub-section** (MOBILE
  only): a **Saved/New** picker when the existing client has saved service addresses (`ProClientsService.serviceAddresses`),
  else a **new address** via the new shared `PlacesAddressSearchField` (+ optional label/apt). `clientAddressId` (saved)
  OR a Places-resolved `serviceAddress` (new) flows to **both** the slot picker and `createBooking`.
- **Plumbing (commit 1):** `BookingService.day` gained an optional `clientAddressId` query param; `ProOpenSlotPicker`
  threads `clientAddressId` (default nil) into the day fetch + fetchKey; `ProBookingService.createBooking` +
  `ProBookingCreateRequest` gained `clientAddressId?` + `serviceAddress?` (new `ProServiceAddressInput`, nil-dropped,
  mirrors `pickServiceAddressPayload`); `PlaceDetails` is now `Equatable` (for SwiftUI `onChange`).
- **No-dup (commit 2):** extracted `PlacesAddressSearchField` (autocomplete + resolve → bound `PlaceDetails?`) out of
  `AddServiceAddressSheet` and refactored that sheet onto it (identical behavior); the pro MOBILE flow reuses it.
- **Design notes for next time:** a **new (unsaved)** address has no `clientAddressId`, so its slot fetch falls back to
  **mobile-base availability** (the backend `availability/day` returns base slots when MOBILE + no address — it does
  NOT hard-fail). The inline `serviceAddress` is sent Places-resolved (placeId + exact lat/lng) so the server keeps the
  pin instead of re-geocoding. The aftercare rebook slot picker still passes `clientAddressId: nil` (unchanged) — if
  MOBILE-rebook slots ever need a real address, it can now thread one through the same param.

#### Workstream 2 — Multiple co-equal BASE services per booking (CORE backend invariant change — investigate + sign-off FIRST)
**Goal:** let pros (and clients at booking time) put **multiple full services** on one booking (e.g. cut + color as two
independent services, not add-ons). User confirmed they want this; it was deferred as the bigger change.
- ⚠️ **This relaxes a deliberate invariant — do NOT just flip the guard.** First **investigate every assumption**, write
  up an approach, and **get user sign-off before implementing.** The likely shape: keep ONE *primary* service (the
  booking's `serviceId`/`offeringId`, NOT NULL — drives title/scheduling-window/location rules) but allow multiple
  **billable BASE-or-co-equal line items**; OR a deeper model change. Investigation must cover the full lifecycle.
- **Known touch points (the `baseCount===1` / single-primary assumptions):**
  - `app/api/v1/pro/bookings/[id]/consultation-proposal/route.ts` — `parseProposalPayload` (`baseCount !== 1` → reject)
    + the in-tx validation loop (each BASE must map to a valid active offering).
  - `lib/booking/writeBoundary.ts:3247` — `assertValidFinalReviewLineItems` (`baseCount !== 1` → "exactly one main
    service") on the approval/finalize path; plus `approveConsultation`.
  - `lib/booking/serviceItems.ts` — `computeBookingItemLikeTotals` derives `primaryServiceId`/`primaryOfferingId` from
    the single BASE (sums durations/prices across all items already).
  - `Booking` model: single primary `serviceId` (NOT NULL) + `offeringId`.
  - Client approval surfaces/DTOs: `app/api/v1/public/consultation/[token]/route.ts`, `app/api/v1/client/bookings/*`,
    `lib/dto/clientBooking.ts` (they render/assume one main service).
  - Native: revert `ProConsultationFormView`'s base/add-on **mode switch** (commit `4c18ef1`) to allow adding multiple
    base services once the server accepts them; and the client iOS booking flow (`BookingFlowView`) for the
    client-side multi-service ask.
- Backend changes branch off `origin/main`, its own PR(s); re-run `gen:api-schema` after any DTO edit;
  typecheck+lint+static-guards+vitest before push.

**Standing reminders:** ⏳ **tovis-app PR #441 (consultation proof) is MERGED but NOT deployed** — deploy prod
(`npx vercel@latest --prod`) when the user says so, to light up the proof card. **NOTHING in Phase S or these two
workstreams is sim-verified yet** — a real-device/sim walkthrough as an APPROVED pro is the highest-value check.

### 🔧 Post-S1 fix — consultation "Add" picker is now base/add-on aware (`4c18ef1`)
**Sim-found bug:** adding a 2nd service in the consultation form failed with *"Invalid proposed services. Include
exactly one base service…"* The form tagged **every** picker-added service as `BASE`, but a booking is modeled as
**exactly one main (BASE) service + ADD_ONs** — enforced server-side in BOTH `consultation-proposal/route.ts`
(`parseProposalPayload` baseCount===1) AND `lib/booking/writeBoundary.ts` `assertValidFinalReviewLineItems` (3247),
and `computeBookingItemLikeTotals` derives the booking's single `primaryServiceId`/`primaryOfferingId` from that one
BASE. Fix: `ProConsultationFormView`'s picker now offers base services until a base exists, then that offering's
**add-ons** (from the `addOns` array the `consultation-services` GET already returns), tagged `ADD_ON` w/ the parent
offering id — which the route's `allowedAddOnServiceIds` + parent-offering checks accept. No-add-ons state is messaged.

> (The earlier standalone "multiple co-equal BASE services" deferred note is now **Workstream 2** above.)

**NEXT = Workstream 2 (multi-base, in a fresh session — investigate + sign-off first; Workstream 1 MOBILE is DONE)** + the standing
sim-verify of Phase S end-to-end (consult → send → approve → before → service → finish → after → wrap-up → mark paid →
aftercare → send; + create-booking). Camera device run+tune (below) + Phase C/B4 still open.

---

## (prior pass) PRO TOP-HEADER + OVERVIEW HOME (6 tabs) ✅ DONE

**What the user asked for:** the iOS pro app was missing (a) the **top header with tabs** the web has, and
(b) the **full booking/session flow**. This pass delivered the **entire header phase**; the session flow
is the remaining piece (Phase S below).

### ✅ Header phase — ALL DONE (committed on `tovis-ios` main; Debug+Release green; `swift test` **57**)
The web pro UI has TWO nav layers: the bottom `ProSessionFooter` (already ported as `ProTabBar`) AND a
global **top header** (`app/pro/ProHeader.tsx`) with 6 secondary tabs. iOS only had the footer. Now:

- **H1 — Overview home + header chrome** (`6a308e9`): new `ProOverviewHomeView` is the pro **launch
  surface**. `ProTopBar` = web ProHeader chrome (◆ PRO MODE kicker + italic page title + bell w/ unread
  dot + account "⋯" menu reusing `session.switchWorkspace`/`logout`). `ProHeaderTabsBar` = the swipeable
  6-tab strip (Overview · Reviews · Aftercare · Bookings · Last Minute · Locations) with active underline.
  `ProHeaderTab` enum. The strip swaps the body in place (like web routes).
  - **Placement decision (user-picked):** "dedicated Overview home" — footer KEEPS its 5 web slots
    (Looks · Calendar · session · Messages · Profile), so Overview is NOT a footer tab. Pro lands on it
    (`ProMainTabView` default `tab = .overview`, added `.overview` to `ProTab.ID` + the TabView); a
    **Home button** added to the Calendar nav bar (`ProCalendarView(onHome:)`) returns to it. Calendar
    otherwise untouched.
- **H2 — Locations** (`c9cf48b`): `ProLocationsView` read list (`GET /pro/locations`, reuses
  `ProCalendarService.locations()`). Create/edit/set-primary/publish editor deferred (needs Places picker).
- **H3 — Bookings** (`e52a49d` + tovis-app **PR #435 MERGED**): `ProBookingsListView` — stats + filter
  pills + Today/Upcoming/Past/Cancelled → detail. New `GET /api/v1/pro/bookings`.
- **H4 — Aftercare** (`tovis-ios` commit + **PR #436 MERGED**): `ProAftercareListView` — Drafts/Awaiting/
  Overdue tiles + Draft/Sent/Finished tabs + search + before/after thumbs. New `GET /api/v1/pro/aftercare`.
- **H5 — Overview/dashboard** (commit + **PR #437 MERGED**): `ProOverviewView` — month nav + revenue hero
  + stat cards + top services. New `GET /api/v1/pro/overview` (thin wrapper over `loadProOverviewPage`).
- **H7 — Reviews** (commit + **PR #438 MERGED**): `ProReviewsListView` — ratings + media grid. New
  `GET /api/v1/pro/reviews`.
- **H6 — Last Minute** (commit + **PR #439 MERGED**): `ProLastMinuteView` read summary (tiers, per-day
  availability, service rules, blocks). New `GET /api/v1/pro/last-minute/workspace`. The web editor
  (toggles/PATCH) deferred.

**ALL 5 backend PRs (#435–#439) MERGED** (2026-06-29).

### ⚠️ OPEN ACTION ITEMS (do these first next session)
1. ✅ **Prod redeployed 2026-06-30** (`npx vercel@latest --prod`; deploy `dpl_8ztVztGbGjWgoR5VEPrtCXMUKZYZ`,
   READY). `main` (all merged through #440) is live on prod; `/api/health` + `/api/health/ready` = 200; the native
   GET endpoints (overview/bookings/aftercare/reviews/clients) return 401 (deployed, auth-gated); Sentry clean (no
   new/regressed prod errors post-deploy). Auto-deploy stays OFF → future deploys are manual.
2. **Sim-verify** the header + all 6 tabs AND the full Phase-S flow as an APPROVED pro (re-login after each reinstall
   — keychain wipe). NONE of H1–H7 or S1–S4 is sim-verified yet — this is the next step.

### Backend pattern used (reuse for Phase S backend work if any)
Each list endpoint extracts a **shared loader** under `lib/pro/**` (query + mapping) that BOTH the web page
and the new GET call — refactor the page to consume it (no duplicate logic, CLAUDE.md). Pro routes return
**inline shapes** (`jsonOk(body)`); iOS ships a **decode-only fixture + test** (no ajv entry). ⚠️ Relocating
client `firstName/lastName/phone` reads into a loader trips `check:pii-plaintext-reads` → run
`node tools/check-pii-plaintext-reads.mjs --update-baseline` (net-neutral; same plaintext fields the
baselined `[id]` route reads). ⚠️ The **pre-push hook runs the FULL vitest suite** — a page that has a
`page.test.tsx` (e.g. bookings) mocks `prisma.findMany` in call order, so preserve the query ordering when
refactoring. New Swift files auto-build (`PBXFileSystemSynchronizedRootGroup`); fixtures auto-include
(`.process("Fixtures")`).

### ✅ DONE WORKSTREAM — Phase S: the full booking / session flow (S1–S4 shipped 2026-06-29 pass 4; see RESUME above)
The native `ProSessionHubView` is a v1 stub (status + photo capture + one "Finish session" button). The web
`app/pro/bookings/[id]/session/page.tsx` is a **4-step state machine** to port:
- **S1** — rebuild `ProSessionHubView` into the web screens, driven by `getSessionScreenKey`/
  `resolveEffectiveSessionStep`: **Consultation** (ConsultationForm: set services/price → send for approval;
  in-person fallback) → **Waiting + Before photos** (combined) → **Service in progress** (elapsed timer) →
  **Wrap-up** → **Done/Terminal**, with the persistent **4-step rail** (Consult · Before · Service ·
  Wrap-up). Endpoints (already wired in `ProSessionService`/`ProBookingService`): `POST .../session/start|
  finish`, `POST .../session/step {step}`, `GET .../session/state`, `POST .../consultation-proposal`,
  `POST .../consultation/in-person-decision`.
- **S2** — **Wrap-up closeout checklist** (after photos · aftercare sent · payment collected · checkout
  paid/waived · consultation approved) + **Mark Paid** (`PATCH .../checkout/mark-paid {paymentMethod}`) +
  waive (`PATCH .../checkout/waive`). See `buildProSessionCloseoutChecklist` + `listManualCollectable
  PaymentMethods`.
- **S3** — **Aftercare authoring screen** (web `/pro/bookings/[id]/aftercare`): write notes, recommend
  products, set rebook, send to client. `GET/POST /pro/bookings/[id]/aftercare` exist. (This is also the
  native destination the Aftercare-list "View full aftercare" should deep-link to instead of booking detail.)
- **S4** — **Create booking for client** (web `/pro/bookings/new`): `POST /pro/bookings` (idempotency-key) +
  `GET /pro/allowed-services` + `GET /pro/openings`. Wire from a "+ New booking" entry (bookings list /
  Overview).

**Files added this pass** (all on `tovis-ios` main): `Tovis/Pro{TopBar,HeaderTab,OverviewHome,Locations,
BookingsList,AftercareList,Overview,ReviewsList,LastMinute}View.swift` (+ `ProHeaderTab.swift`);
`TovisKit/.../Models/Pro{BookingsList,AftercareList,Overview,ReviewsList,LastMinute}.swift`;
`TovisKit/.../ProOverview/ProOverviewService.swift`; service methods on
`ProBookingService`/`ProProfileService`/`ProScheduleService`; 5 fixtures + 5 decode tests. tovis-app loaders:
`lib/pro/proBookingsList.ts` (+test), `lib/aftercare/loadProAftercareList.ts`, `lib/pro/loadProReviewsList.ts`,
`lib/pro/loadLastMinuteWorkspace.ts`; routes under `app/api/v1/pro/{bookings,aftercare,overview,reviews,
last-minute/workspace}/route.ts`.

## Repos & how to run / verify

| Repo | Path | Role |
|------|------|------|
| iOS app | `~/Dev/tovis-ios` | SwiftUI app + `TovisKit` package (this repo). **No git remote** — local commits only. |
| Backend | `~/Dev/tovis-app` | Next.js `/api/v1`. Branch per feature off `origin/main`; PRs. |

- **Run:** `docker start tovis-dev-postgres` → `cd ~/Dev/tovis-app && pnpm dev` (localhost:3000, local DB `:5434`). Open `~/Dev/tovis-ios/tovis-ios.xcodeproj`, iPhone sim, ⌘R (Debug→localhost). Sign in **as a PRO** to see the pro shell (a CLIENT lands on the client shell). Seed client: `client@tovis.app`/`password123` (CLIENT only — for a pro, use a real APPROVED pro account; role decides the shell).
- **Verify (run before committing):**
  - iOS: `cd ~/Dev/tovis-ios/TovisKit && swift test` (**50**); `cd ~/Dev/tovis-ios/scripts/contract && npm run validate` (**26 objects**); `cd ~/Dev/tovis-ios && xcodebuild build -scheme Tovis -project tovis-ios.xcodeproj -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO` (and `-configuration Release`).
  - Backend: `npm run typecheck && npm run lint && npm run check:static-guards` + `npx vitest run <paths>`.

## ✅ DONE (committed on `tovis-ios` `main`)

**Pro shell + footer** (`d2efa11`): role-based routing (`SessionToken.role` from JWT → `ProMainTabView`
vs client `MainTabView`); `ProTabBar` = web `ProSessionFooter` 1:1 (Looks · Calendar · live-session
center · Messages · Profile); `ProSessionModel` = native port of `useProSession` (GET `/pro/session`
+ poll, START/FINISH/PICK_BOOKING, session hub); `ProCalendarView` agenda (`GET /pro/calendar`);
`ProProfileTabView` (workspace switch via `POST /workspace/switch`). DRY: shared
`FooterNavItemLabel`/`FooterBadgeDot` + `BrandCoin` used by both bars.

**AI camera ladder:**
- **A** (`e9296b5`) — custom AVFoundation camera + before/after capture + upload pipeline
  (`ProMediaService`: presign→PUT→confirm) + hub gallery.
- **B1** (`ee494eb`) — on-device coach: `CoachEngine`/`CoachAnalyzer` (Vision face + CoreImage luma,
  ~6 fps) → one prioritized nudge + readiness ring; **Lighting + Composition** coaches; toggles
  (`CoachSettings`: tips/voice/haptics/grid/ring/auto-capture).
- **B2** (`48827d6`) — "Session Reel": auto-harvest best stills at readiness peaks (≥0.85, ≥1/2.5s,
  cap 24) → staged `BestShotsReviewView` (keep/upload).
- **B3a** (`11fe284`) — **silent** video clips (no mic) + `FrameScrubberView` (AVAssetImageGenerator)
  to extract the best still or save the whole clip (VIDEO) into session media.
- **B3b** (`1c4591c` iOS + `tovis-app` PR **#427 MERGED**) — client per-session **media-use consent**:
  `Booking.mediaUseConsentAt` + `publicShareGuard` honors it (3 call sites) + `POST
  /client/bookings/[id]/media-consent` + `ClientBookingDTO.mediaUseConsent`; iOS toggle in
  `BookingDetailView`. **Consent UNLOCKS the pro's publish action; never auto-publishes.**
- **More coaches** (this session) — `SharpnessCoach` (CoreImage edge energy on the subject
  region), `BackgroundCoach` (`VNGeneratePersonSegmentation` → background edge clutter),
  `PoseCoach` (`VNDetectHumanBodyPose` → level-shoulders / subject-clipping) added to
  `CoachEngine`'s coach list; the deferred **faceLuma backlit** signal is now computed so
  `LightingCoach`'s backlit branch is live. `FrameContext` gained `sharpness`/
  `backgroundClutter`/`pose`; the heavy Vision requests (segmentation + pose) run on a slower
  ~2–3 fps cadence (cached between runs) over a downscaled working image. Tuning divisors are
  hand-set heuristics (need on-device tuning). Builds Debug+Release; 26 TovisKit tests + 26
  contract objects green.
- **B4 calibration plan** (`7a7ef51`) — designed, NOT built (see below).

## ✅ PRO UI SUITE — Phases 3–5 (added 2026-06-28, committed on `tovis-ios` main)

The pro-side UI was built out beyond the shell. Each surface ships a TovisKit service +
wire models + fixture + decode test — all **decode-only** (like `proSession.json`: most
pro routes return inline shapes, so no ajv contract entry). Consolidated contract map =
**`docs/PRO-BACKEND-CONTRACTS.md`**. `swift test` **32** · contract **26** · `xcodebuild`
Debug **AND** Release green.

- **Phase 3 — booking detail** (`ProBookingDetailView`, `ProBookingService`): calendar
  agenda is the list (`GET /pro/bookings` doesn't exist); a row opens the detail
  (`GET /pro/bookings/[id]`) with **accept** / **cancel** (auto-refunds) / **propose next
  appt** (rebook) / contact tap-actions / **Open·Resume session** → hub.
- **Phase 4 — profile** (`ProProfileTabView` reworked + `ProProfileManageViews` +
  `ProProfileService`): header + stats + services + portfolio + reviews (read via existing
  `GET /professionals/{id}`, keyed by new **`GET /pro/profile`**), **Edit profile**
  (`PATCH /pro/profile`), **Manage services** (`GET/PATCH /pro/offerings` — toggle active +
  edit salon/mobile price+duration). 🔶 **Backend companion: tovis-app PR #428** adds
  `GET /api/v1/pro/profile` — **MERGE + redeploy prod before Release/TestFlight uses the
  profile tab** (Debug→localhost works once the branch is running).
- **Phase 5c — notification center** (`ProNotificationsView`, `ProNotificationsService`):
  web `/pro/notifications` parity (distinct shape: priority/seenAt/reviewId) — feed +
  icon/tint + unread dot + mark-read/all + pagination; a **bell w/ unread dot** on the
  Calendar nav bar (`GET /pro/notifications/summary`).
- **Phase 5b — working hours** (`ProWorkingHoursView`, `ProScheduleService`): per-day
  open/close + start/end pickers, save (`GET/POST /pro/working-hours`). Profile → Business.
- **Phase 5a — clients** (`ProClientsView`, `ProClientsService`): searchable directory
  (`GET /pro/clients/search`, view-gated) → detail (contact + service addresses + append-only
  **add note**). Profile → Business.

**🔲 Pro-UI sub-screens DEFERRED** (need backend aggregate GETs or lower-value): client
chart **HISTORY** read (server-rendered, no read API → needs `GET /pro/clients/[id]/chart`
DTO); aftercare **LIST** (per-booking `GET /pro/bookings/[id]/aftercare` exists; list needs
a DTO); pro **locations editor**, **payment-settings/membership**, **notification-preferences
editor** (prefs service methods already exist on `ProNotificationsService`); calendar
**day/week grid + block create/edit**; offering **CREATE/DELETE** (only toggle/edit shipped).
**Next pro step:** merge+redeploy PR #428 (✅ MERGED 2026-06-29), then live-verify the pro suite on the sim.

### 🔍 Web-parity — ✅ ALL 5 PAGES COMPLETE (2026-06-29 pass 2)

> **Full per-page detail = `docs/PRO-WEB-PARITY.md`** (status header updated). Every page now
> builds Debug+Release; `swift test` **38** green. The pass read the real web components and
> ported each 1:1 (copy quoted verbatim). Commit map (all on `tovis-ios` main):

- **Notification preferences** ✅ `f56697d` — `NotificationPreferencesView(surface:.pro)` reached
  from a gear in the pro notification center (DRY: one view serves client + pro).
- **Profile** ✅ — payment-settings sheet `94a2d9d`; fuller edit form (live handle check +
  suggestions, nameDisplay cards, profession type, avatar upload via AVATAR_PUBLIC) `26bd389`;
  tabbed shell (portfolio/services/reviews) + Your-link card (locked/reserve/live) + approval
  notice + stats + quick actions `71267fa`; services CRUD add(library picker)/delete/add-ons/
  image `93c3e08`.
- **Booking detail** ✅ `9ac2397` — rebuilt: header (Booking·#id + TOTAL + tap-for-directions),
  Timing timeline, Payment breakdown, Aftercare snapshot, Refund flow, web action set
  (PENDING→Accept/Cancel · ACCEPTED→Start booking/Cancel · IN_PROGRESS→Continue session). The
  **invented "propose next appointment" rebook card was REMOVED**.
- **Clients** ✅ — Add-a-client form `a74ddf3`; native **8-tab chart** + safety strip + do-not-rebook
  banner `a8066d0` (list now opens the chart for viewable clients).

**✅ DONE 2026-06-29 — backend PRs merged + first side-by-side sim walkthrough.**
The three additive backend PRs are **MERGED + prod redeployed**: **#431** `GET /pro/services/catalog`,
**#432** expanded `GET /pro/bookings/[id]`, **#433** aggregate `GET /pro/clients/[id]/chart`.
Did the first real Debug→localhost side-by-side walkthrough as a logged-in pro. Fixes (all on `tovis-ios` main):
- **Footer** — Looks tab renders the brand `TovisEye` mark (was `sparkles`) `41a5643`; center coin
  geometry matched to web `footers.css` 1:1 (bar 80 / coin 72 / raised ~20pt) `b7d146d`; **even 5-slot
  spacing** (reserved empty center slot — side buttons were crowding center), **brighter full-color ring**
  (thicker + blurred bloom + brightness lift), **readable cream START label** (was faint teal on the
  translucent coin), state-driven coin opacity (translucent idle / solid live), client `TovisTabBar`
  brought to the same geometry `b8244a0`.
- **CRITICAL notifications decode bug** `dd24af9` — `GET /pro/notifications` serializes `priority` as the
  enum NAME ("HIGH") but the native model had `priority: Int?` → the **whole feed threw** the moment a pro
  had any notification (empty feed + red "We couldn't read the server response."). The decode test passed
  only because the fixture used a numeric priority. Model→`String?` + fixture corrected; this also restored
  the `Unread(n)` chip + `Mark all read` button that the failed decode had suppressed.
- **Verified ✅:** booking-detail (verbatim copy, #432 data live), profile (Messages quick action
  **intentionally omitted** from a pro's view of their OWN profile per user), notifications.

**✅ RESOLVED — Clients list** (2026-06-29, vs `app/pro/clients/page.tsx`):
- **Root cause:** native loaded its directory via `GET /pro/clients/search` with empty `q`, but that route
  intentionally short-circuits to empty results when there's no query (anti-enumeration) → the list had no
  source and always showed "No clients yet." The web page has **no search**; it just renders the scoped
  visible set.
- **Fix (tovis-app PR #434, OPEN — merge+redeploy before sim-verify):** new **`GET /api/v1/pro/clients`**
  directory endpoint = 1:1 port of `page.tsx` (same `proClientVisibilityWhere` scope, ordered by name, per-
  client `lastBookingLabel`); shared `formatLastBookingLabel` helper extracted (web page switched to it).
- **Native:** `ProClientsService.directory()` + `ProClientDirectoryResponse`; `ProClientSummary` gains
  `lastBookingLabel`. `ProClientsView` now loads the directory + **filters client-side** (web has no server
  search), with web copy (header subtitle · "Client list" + `{n} visible` · full empty-state copy · per-row
  contact + "Last booking: …"). Fixture + decode test. `swift test` **52** · Debug+Release green.
- **Trade-offs:** empty-state "View profile" action omitted (cross-tab nav on native); header count shows
  the *filtered* count while searching (= total visible when not searching). ⚠️ NOT yet sim-verified
  (keychain wipe → re-login). Once #434 is live, this **unblocks live #433 chart verification** (a listed
  client opens the 8-tab chart).

**Deferred polish (unchanged):** pro **aftercare detail** screen (web "View full aftercare" link omitted —
no native destination); in-app **Message** deep-link from the clients list; per-tab chart **write forms**
beyond Add-a-note + technical-record encrypted-note **decryption** (web-only by design); **looks/followers**
profile stat tiles (web stat grid = 5: Rating·Reviews·Favs·Looks·Followers, native = 3; needs a small
`GET /pro/profile` stat add); contact/service-addresses view (`ProClientDetailView` is orphaned — re-link
or delete).

**⚠️ Sim-workflow gotchas (2026-06-29):** `xcrun simctl install` **wipes the Keychain session** every
reinstall → the pro is logged out after each rebuild (TokenStore = Keychain); batch fixes to minimize
rebuilds, and the user must re-login after each. Driving the sim via `osascript`/System Events is **blocked
by TCC** (`-25204`/`-25211`, even with Accessibility toggled on — the spawned osascript isn't the authorized
app) → fall back to user-navigates / `xcrun simctl io booted screenshot`. (A `simctl shutdown` mid-session
also logs out? No — reboot KEEPS the keychain; only reinstall wipes it.)

---

## ✅ DONE — CALENDAR full mobile parity (2026-06-29) — see the build-complete section below

> **This workstream is COMPLETE + sim-verified + polished.** Full detail is in the
> "🎉 CALENDAR full-mobile-parity build" section further down. The original plan/spec is kept below for
> reference. **The next session's pick is the un-exercised functional testing (block CRUD, approve/deny) or a
> new workstream — NOT the calendar build.**

**Decision (user-confirmed):** build the native pro Calendar out to **full web mobile parity**, not just polish.
This is the **biggest web↔native gap** of the pro pages and a **large, multi-step build** — do it incrementally,
commit per increment, `swift test` + `xcodebuild` Debug+Release each.

**Current native = agenda only** (`Tovis/ProCalendarView.swift`): stats tiles (Today / Requests / Open) →
"Pending requests" section → upcoming bookings+blocks grouped by day; tap a booking → `ProBookingDetailView`.
Bell → notifications sheet. Polls every 60s + refresh-tick. That's a *subset* of the web.

**Web mobile target = `app/pro/calendar/_components/CalendarMobileShell.tsx`**, which composes:
`MobileCalendarHeader` · `MobileCalendarControls` (Month/Week/Day **view switcher** + prev/next/**Today**) ·
`MobileMonthGrid` · `DayWeekGrid` (time-slot columns) · `MobilePendingRequestBar` · `MobileAutoAcceptBar` ·
`MobileCalendarFab` (+ block-time create) · `CalendarStatsPanel` · location bar. Modals:
`BlockTimeModal` (create), `EditBlockModal` (edit/delete), `BookingModal`. View state: `view: 'month'|'week'|'day'`,
`currentDate`, `onPrev/onNext/onToday`. Quote copy verbatim from these files.

**Backend — READY (verified 2026-06-29):**
- `GET /api/v1/pro/calendar` — returns `events[]` (BookingEvent|BlockEvent) + `stats` + `management`
  buckets `{todaysBookings, pendingRequests, waitlistToday, blockedToday}` + `timeZone`/`viewportTimeZone`.
  Uses `DEFAULT_CALENDAR_RANGE_DAYS` window. **✅ RESOLVED (inc.1): the route accepts `from`/`to` ISO query
  params** (`route.ts:437-452`, clamped to `MAX_CALENDAR_RANGE_DAYS`) — month nav needs **no** backend
  change; the native client just passes the view's range. Native model in `TovisKit/.../Models/*alendar*.swift`
  (`ProCalendarResponse/Event/Stats/Management`), service = `session.client.proCalendar.calendar(from:to:)`.
- **Block CRUD endpoints EXIST:** `POST/GET /pro/calendar/blocked` (create/list), `…/blocked/[id]`
  (edit/delete) → wire a native `ProCalendarBlockService` (or extend the calendar service) for the FAB +
  BlockTime/EditBlock modals.
- Availability: `GET /pro/availability/busy-days` (month dots), `…/availability`.

**Suggested increments (each its own commit, web copy verbatim, decode fixture + test per new DTO):**
1. ✅ **DONE 2026-06-29 (`c97b027`)** — **Month grid + view switcher.** `ProCalendarControls` (Day/Week/Month
   toggle + prev/Today/next + range label) + `ProCalendarMonthGrid` (6×7 Monday-start, per-day event dots);
   tap a day → that day's agenda. The visible range now drives the fetch (`calendar(from:to:)`). Pure date
   math (range/cells/header/step) in `TovisKit/.../ProCalendar/ProCalendarGrid.swift` + 6 unit tests
   (`ProCalendarGridTests`). Day/Week reuse the existing agenda rows. `swift test` **43** · Debug+Release green.
   ⚠️ NOT yet sim-verified (keychain wipe on reinstall → re-login needed). Default view = `.day` (web parity).
2. ✅ **DONE 2026-06-29 (`d33c20b`)** — **Block-time CRUD.** A "+" FAB (web `MobileCalendarFab`) opens
   `ProBlockTimeSheet` create; tapping a BLOCK row opens the same sheet in edit mode (fetches `GET
   …/blocked/[id]` for the note) with Save + Delete (confirm). Start/End pickers render in the calendar zone,
   client-side 15min–24h guard mirrors the server; server conflict/validation messages surface inline.
   New `ProCalendarBlock` + `ProLocationSummary` models, `ProCalendarService.{locations,createBlock,block,
   updateBlock,deleteBlock}`, 2 fixtures + 3 decode/encode tests. Create pins to a bookable location
   (`GET /pro/locations`, primary default, picker when >1); FAB hidden if none. `swift test` **46** ·
   contract **26** · Debug+Release green. ⚠️ NOT yet sim-verified.
3. ✅ **DONE 2026-06-29 (`1b1e18d`)** — **Day/Week time-grid.** `ProCalendarTimeGrid` ports the web
   `DayWeekGrid` (+ `_grid/TimeGutter`/`DayColumn`/`DayHeaderRow`/`EventCard`): a 24h vertical timeline at
   `PX_PER_MINUTE=1.5`, time gutter, 1 col (day) / 7 cols Mon-start (week), hour rules, a now-line on today,
   and event tiles positioned by their minutes-since-midnight window. Auto-scrolls to 8am. Tiles tap →
   booking detail (programmatic push) or block editor; **replaced the inc.1 agenda fallback for Day/Week**.
   Pure layout math (`eventDayMinutes`/`snap`/`minutesSinceMidnight`/`timelineDays`) added to
   `ProCalendarGrid` + 4 tests (`swift test` **50**). Contract **26** · Debug+Release green. ⚠️ NOT sim-verified.
   **Web parity gaps (deferred to polish):** working-hours shading (needs per-location `workingHours`), event
   drag/resize + tap-to-create (mouse-oriented; native uses the FAB + detail screen), side-by-side overlap
   columns (web also stacks full-width), sticky header inside the scroll.
4. ✅ **DONE 2026-06-29 (`892a16d`)** — **Bars/panels.** `ProCalendarBars` adds the web `MobileAutoAcceptBar`
   (toggle → `PATCH /pro/settings {autoAcceptBookings}`, optimistic + revert; seeded from the calendar
   response's new `autoAcceptBookings`), `MobilePendingRequestBar` (top pending request → quick **Approve**
   `proBookings.accept` / **Deny** `proBookings.decline` [base PATCH status CANCELLED] / open-detail /
   dismiss; "+N more" advances on action — **replaced the inline pending list**), and `MobileLocationBar`
   (multi-location pros → `activeLocationId` re-fetches `calendar(locationId:)`). New `setAutoAccept` +
   `decline` service methods, `ProSettingsResponse`, 1 fixture + decode test. `swift test` **51** · contract
   **26** · Debug+Release green. ⚠️ NOT sim-verified.
   **Deferred:** the web `ManagementModal` (full pending/waitlist/blocked management list) has no native
   destination — the bar surfaces only the top pending request, and booking-override prompts
   (`BookingOverrideRequiredError`) just surface the server error inline rather than a retry dialog.

### 🎉 CALENDAR full-mobile-parity build — ✅ ALL 4 INCREMENTS DONE + SIM-VERIFIED + POLISHED (2026-06-29)
The native pro Calendar matches the web mobile shell: view switcher + month grid (inc.1), block-time
CRUD (inc.2), Day/Week time-grid (inc.3), and bars/panels (inc.4). **First full sim walkthrough done**
(`pro@tovis.app`/`password123` on the local stack — Docker `:5434` + `pnpm dev`; dark mode), which surfaced +
fixed a batch of layout/UX issues (commits `8ca6134`→`95ad9f7`):
- **Time-grid 2× offset bug** (`8ca6134`): the day-column ZStack had no intrinsic height, so `.frame(height:)`
  centered its content — a 10am booking rendered at ~8:30pm + the now-line at the bottom. Fixed with a
  full-height `Color.clear` spacer; verified the 10am booking lands on 10am.
- **Stat labels → web copy** (`8ca6134`): Booked / Pending / Free (today / review / "Nh blocked").
- **Layout rework** (`0b89f64`,`29364c8`,`3ae44e5`): un-nested the grid's scroll, pinned the stats/controls
  chrome, grid fills the remaining height + opens at "now" (iOS-17 `.scrollPosition(id:)` on an hour anchor
  ladder — offset views aren't `scrollTo` targets); inline nav title + compact date nav; grid extends to the
  footer bar (the transparent START coin overlaps it).
- **Giant header band bug** (`7ec86dd`): the in-grid day header ballooned to ~400pt because the gutter spacer
  was a bare `Color.clear.frame(width:)` — a `Color` is greedy on BOTH axes. Swapped for a fixed-width
  `Spacer`; header is now a thin strip and the timeline starts right under the date. ⚠️ **Lesson: never use a
  bare `Color.clear` as a one-axis spacer — constrain the other axis or use `Spacer`.**
- **Collapsible chrome + long date** (`79e0f15`,`95ad9f7`): a nav-bar chevron collapses stats/location/
  auto-accept (view switcher + date nav stay) to maximize the grid, re-snapping to "now" on toggle; the Day
  header shows the long date ("Monday, June 29"), Week keeps per-column weekday+number.

`swift test` **51** · contract **26** · Debug+Release green. **Remaining deferred parity** (unbuilt, lower
value): working-hours shading, drag/resize + tap-to-create, the `ManagementModal` (full pending/waitlist list),
the booking-override retry dialog, and side-by-side overlap columns. The two deferred copy gaps from the web
compare (the big "Your day." title + defaulting LOC to the active location) were **not** taken (user picked
stat-labels only). **Functional bits still un-exercised on the sim:** block create/edit/delete via the ＋ FAB,
and the pending-request bar's Approve/Deny (needs a PENDING booking in range — both seed bookings are ACCEPTED).

**House rules carry over:** web-parity 1:1 · no dup logic (reuse BrandSurface/Section/Pill/Avatar + the
agenda row) · decode-only fixtures unless an ajv contract entry is warranted · `requirePro` · backend changes
(if month-param needed) branch off `origin/main`, re-run `gen:api-schema` after DTO edits, typecheck+lint+
static-guards+vitest before push. Re-login after every reinstall (keychain wipe).

**Why booking-detail + clients weren't done this pass:** both need backend route work, and the
`tovis-app` checkout was on another active session's branch — branch-switching + `prisma generate`
during typecheck would clobber the sibling. Do these when the checkout is free (or in an isolated
worktree with its own node_modules to avoid the shared-prisma-client clobber).

## ⚠️ Make it FULLY FUNCTIONAL — device run + tune pass (do this FIRST)

The whole camera ladder **builds + unit-tests green but has never run against a real camera** — the
iOS Simulator has no camera, so `CameraController.start()` just lands in `.failed` there. Signing is
already set up (`DEVELOPMENT_TEAM SB3J675LNU`, automatic), so this is a device run, not more code.

**0a. End-to-end loop on a physical iPhone** (the functional proof). `docker start tovis-dev-postgres`
   + `pnpm dev`; build to a real device (Debug → localhost; the Mac + phone on the same network, or
   point at prod with Release). Sign in as a **real APPROVED pro** with an active session → session hub
   → camera. Walk: **shutter** → presign→PUT→confirm → photo lands in session media + shows in the hub
   gallery; **silent video** → frame scrubber → save still/clip; **auto-harvest** → best-shots review →
   upload. The upload contract + publish guard are live (#427 merged), so the backend is ready.

**0b. Tune the coach against real salon light.** Every perception threshold now lives in ONE file —
   **`Tovis/CoachTuning.swift`** — so tuning is edit-one-file → rebuild → re-watch. Watch the readiness
   ring + nudges on device and adjust: `sharpnessReference` (is everything called "soft"?),
   `clutterReference` (is a clean wall called "busy"?), `lumaTooDark/Bright/Ideal`, `shoulderTiltDegrees`,
   `harvestThreshold`/`readyThreshold`. Per-coach SCORE weights stay inline in `ShotCoach.swift` (design,
   not calibration). Defaults were set without a device — expect to move several.

## ▶️ NEXT (after it's functional)

1. **Web-client consent toggle** (closes B3b) — backend is **live on main** now (#427 merged); just add
   the same toggle to the web client aftercare/booking-detail surface (`app/client/(gated)/aftercare`
   + booking detail) calling `POST /client/bookings/[id]/media-consent { granted }`.
2. ~~**More coaches**~~ ✅ DONE this session (Sharpness/Background/Pose + faceLuma backlit). Still
   open from the original idea: a **HandPose** coach (`VNDetectHumanHandPose`). Extension point is the
   `ShotCoach` protocol — pure, Sendable, one per aspect; heavy per-frame Vision goes in `CoachAnalyzer`
   (throttled) and lands on `FrameContext`. **On-device tuning is now item 0 below.**
3. **Phase C** — before/after **comparison slider** → **publish to portfolio** (now unlocked by B3b
   consent) + the pro-facing "client allowed sharing" indicator (expose consent on
   `ProBookingMediaItemDTO`). Plus service-aware **ShotGuides** (curated shot lists/pose templates per
   profession/service) + onion-skin before/after alignment.
4. **B4 — NFC-card ColorChecker calibration** — full design + printable card spec in `HANDOFF.md`
   ("NFC card camera calibration"). Decided: full ColorChecker swatches → WB + exposure + 3×3 color
   matrix; NFC (CoreNFC) triggers + identifies card version. ⚠️ **Blocked on the physical card**: each
   print batch's swatch values must be measured + keyed by NFC card-version id.
5. **Phase D** — Claude vision critique (consent-gated; latest vision model; check the `claude-api`
   skill when implementing).

## Key contracts / recipes

- **Media upload (A):** sign `POST /pro/uploads {kind:"CONSULT_PRIVATE",bookingId,phase,contentType,size}`
  → **PUT** `${SUPABASE_URL}/storage/v1/object/upload/sign/{bucket}/{path}?token=` (headers `apikey`
  + `Content-Type` + `x-upsert:false` — ⚠️ **MUST be PUT**, POST → RLS 403) → confirm `POST
  /pro/bookings/{id}/media {uploadSessionId,phase,mediaType,caption?}`. Photos=IMAGE, clips=VIDEO.
- **Publish guard (B3b):** `lib/media/publicShareGuard.ts` — pro may make session media public iff
  public-bucket **OR** `reviewId` **OR** `Booking.mediaUseConsentAt`. All publish call sites must select
  `booking.mediaUseConsentAt` and pass it as the candidate's `clientUseConsentAt`.
- **Coach extension:** implement `ShotCoach { category; evaluate(FrameContext) -> CoachSignal }`, add to
  the `CoachEngine` init coach list. `FrameContext` carries pre-computed signals (extend it as needed).
- **Camera:** `CameraController` (AVFoundation; photo + video-data + movie outputs) — frame delegate =
  `CoachAnalyzer`. Video is **silent by design** (no mic input → no salon audio, no mic permission).

## Decisions log (user-confirmed 2026-06-28)

On-device coaching first (Claude critique later, consent-gated) · curated ShotGuides now (learn from
Looks engagement later) · custom AVFoundation camera · **video records silent** · best shots **staged
for review** (not auto-uploaded) · B3b consent = **per-session, client-granted, unlock-not-auto-publish**
· calibration card = **full ColorChecker + NFC trigger/identify**, built as Phase B4.

## House rules (carry over — from `tovis-app/CLAUDE.md`)

Web parity 1:1 · **no duplicated logic** (reuse brand/components/services) · contract fixture + decode
test + ajv entry per new screen/DTO · pro screens are `requirePro` (CLIENT 403s them) · backend: branch
off `origin/main`, no stacked PRs, re-run `gen:api-schema` after any DTO edit, run typecheck+lint+
static-guards+vitest before push. End of session: `tovis-app` local `main` level with `origin/main` +
clean tree.
