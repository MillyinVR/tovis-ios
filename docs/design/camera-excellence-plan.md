# Camera excellence — gap analysis against "a real photographer is holding my hand"

> ## 🟢 STATUS — §4 (B1–B17) SHIPPED. §3 and §5 still open.
>
> | Section | State |
> |---|---|
> | **§4 — buildable without guessing a threshold (B1–B17)** | ✅ **Built**, 2026-08-04. All seventeen. See `HANDOFF-camera-redesign.md` § "the pre-device-pass camera fixes". |
> | **§3 — what the on-device salon pass must measure** | ⏳ **Open.** This is now the agenda for that pass, and B17 made §3.1/§3.2 measurable offline first. Two items were ADDED by the build — see the ⚠️ notes in §2.1 and §2.5. |
> | **§5 — open product decisions (D1–D12)** | ⏳ **Open.** None built, deliberately: they change what gets built and they are not engineering calls. |
>
> Everything in §1 and §2 below describes the state **before** the §4 build, and
> is left as written so the reasoning can be checked against the diff. Where the
> build changed a claim, an inline note says so. Every `[BUILD]` line in §2 is
> now done; every `[PASS]` and `[DECIDE]` line still stands.
>
> Written 2026-08-04 against `main` @ `6af4954`; status updated on the branch
> that shipped §4. Companion docs: `HANDOFF-camera-redesign.md` (the redesign
> thread + device-feedback log), `docs/camera-tuning-bench.md` (the offline coach
> measurements — now reporting `faceLuma` and the background-scoped colour
> columns), `docs/calibration/README.md` (the card), `BACKLOG.md §1` (the owed
> device pass).

---

## 0. The bar, restated as things that can be checked

Tori's bar: *"a real photographer / social media expert is holding the pro's hand"*,
producing best-quality social + marketing images, **every time**.

A photographer standing behind the pro does six things. The whole analysis below is
organised around whether Tovis does them:

| # | What a photographer actually does | Tovis today |
|---|---|---|
| P1 | **Gets the exposure right on the subject's skin** — not on the room | ⚠️ meters the face, but *judges* the whole frame (§2.1) |
| P2 | **Gets the colour right** — neutral light, true tone | ⚠️ real WB + card machinery, mistuned + content-confounded coach (§2.2) |
| P3 | **Composes for where the picture will be seen** | ⚠️ draws the crop, never judges inside it (§2.4) |
| P4 | **Makes the pair comparable** — same framing, same light, before + after | ⚠️ ghost + light stamp, but both content-confounded and framing is unmeasured (§2.3) |
| P5 | **Teaches while shooting** — says *why*, once, then shuts up | ❌ one imperative line, re-ranked 6×/s, no dwell, no why (§2.5) |
| P6 | **Takes the shot at the right instant, reliably** | ⚠️ works, with a silent stall after a failed burst (§2.6) |

There is a seventh thing a *social media expert* does that a photographer doesn't:
**decides what ships and in what format.** Tovis currently ends at "the bytes are
uploaded." (§2.4, §2.8.)

---

## 1. Current-state inventory

### 1.1 Capture pipeline

| Concern | Where | What it does today |
|---|---|---|
| Session config | `Tovis/CameraController.swift:421-476` | `.photo` preset, `builtInWideAngleCamera` back only, photo + video-data + movie outputs |
| Still capture | `CameraController.swift:110-156` | Forced JPEG, `.quality` prioritization, capped at ~24 MP (`:406-409`), 10 s watchdog (`:50`) |
| Focus | `CameraController.swift:177-208` | Tap-to-focus + one-shot AE, auto-reverts on subject-area change |
| Face-priority exposure | `CameraController.swift:232-263` | Meters continuously on the coach's face rect, `-0.3 EV` bias (`CoachTuning.swift:66`). ⚠️ Coordinate mapping `(x,y)→(y,1−x)` is flagged **unverified on hardware** at `:240-241` |
| Card exposure anchor | `CameraController.swift:268-279` | EV bias from the card's neutral band, composed with the face bias |
| White balance | `CameraController.swift:308-365` | Lock from a neutral sample, re-apply persisted gains, reset to auto |
| Recording | `CameraController.swift:369-397` | `AVCaptureMovieFileOutput`, rotation forced to portrait, **no mic by design** (`:40-41`) |
| Interruption handling | `CameraController.swift:482-512` | Surfaces interrupted state, auto-restarts |

### 1.2 The coach

| Concern | Where | What it does today |
|---|---|---|
| Frame analyzer | `Tovis/CoachEngine.swift:15-318` | 6 fps light signals, 2.5 fps heavy Vision, all math at 480 px long side (`CoachTuning.swift:29`) |
| Seven coaches | `Tovis/ShotCoach.swift:219-506` | lighting · composition · sharpness · background · pose · level · colour |
| Weights | `ShotCoach.swift:18-28` | lighting 1.6, sharpness 1.4, colour 1.1, composition 1.0, level 1.0, background 0.8, pose 0.6 |
| Aggregation | `ShotCoach.swift:198-213` | Weighted mean → readiness; **single largest weighted deficit** wins the one on-screen line |
| Thresholds | `Tovis/CoachTuning.swift` | Every perception number, all set **without a device** (file header `:5-10`) |
| Publishing | `CoachEngine.swift:446-480` | Applies to UI; fires haptic + speech **on every nudge change** (`:457-463`) |
| Lane arbitration | `Tovis/CameraCoachLane.swift:157-246` | Pure 6-tier priority queue, unit-tested |
| Level source | `Tovis/DeviceLevel.swift:26-38` | CoreMotion gravity → roll; sign convention flagged unverified (`ShotCoach.swift:470`) |
| Signals | `Tovis/FrameMath.swift`, `Tovis/VisionDetect.swift` | One implementation shared by live coach, QC, and reference-look analysis |

### 1.3 Direction + guides

| Concern | Where |
|---|---|
| Built-in shot sets (hair / nails / lash-brow / face / generic) | `Tovis/ShotGuide.swift:147-183` |
| Server-driven trending packs | `ShotGuide.swift:104-127`, `:137-143` |
| "Match a look" — on-device reference analysis | `Tovis/ReferenceLook.swift:36-162` |
| Claude-vision enrichment (consent-gated) | `ReferenceLook.swift:167-230`, `Tovis/CameraVision.swift` |
| Wrap-up set critique (Claude vision) | `Tovis/ProSessionHubView.swift:627-790` |
| Pose-rule vocabulary + evaluators | `ShotCoach.swift:110-128`, `:421-453` |

### 1.4 Colour truth

| Concern | Where |
|---|---|
| Card scan (detect → rectify → sample → validate) | `Tovis/CardCorrection.swift:20-115` |
| Two-shot scan flow (WB first, then matrix) | `ProCapturePhotosView.swift:1183-1248` |
| Matrix baked into stills | `CardCorrection.swift:123-148` |
| Matrix baked into clips (full re-export) | `CardCorrection.swift:156-183` |
| Persistence per custody scope | `ProCapturePhotosView.swift:1549-1551`, `:327-345` |
| Drift detection (light changed since scan) | `ProCapturePhotosView.swift:1253-1279` |
| The physical card | `docs/calibration/` |

### 1.5 Output + custody

| Concern | Where |
|---|---|
| Post-capture QC (sharpness / exposure / blink / focal) | `Tovis/PhotoQC.swift:41-125` |
| Crop-safe overlay (9:16 primary, 4:5 secondary) | `ProCapturePhotosView.swift:1017-1062` |
| Focal point → server cover-crop | `PhotoQC.swift:30-39`, `:119-122` |
| Auto-harvest "Session Reel" | `CoachEngine.swift:193-228`, `Tovis/BestShotsReviewView.swift` |
| Frame scrubber (pull a still from a clip) | `Tovis/FrameScrubberView.swift` |
| One upload fan-out | `Tovis/ProCameraUpload.swift:25-42` |
| Durable custody (photos / clips) | `Tovis/SessionByteVault.swift`, `Tovis/ClipVault.swift` |
| Before/after reveal | `Tovis/BeforeAfterCompareView.swift` |

### 1.6 Already known-broken, from the bench

From `docs/camera-tuning-bench.md` (23 real photographs, 2026-08-01):

- `mixedLightSpread = 0.13` sits **on the median of ordinary portraits** — it fires on
  9/17 of them, and at weight 1.1 × score 0.45 it outranks a soft frame and a tilted
  camera, so it wins the one coach line most of the time.
- `clutterReference = 0.18` is so forgiving that `BackgroundCoach` **fired on 0/17
  portraits**. One of seven coaches is dead weight.
- `readyThreshold 0.8` vs `harvestThreshold 0.85` leaves a band where the ring is green
  and the Session Reel harvests nothing — the reel can stay empty all session.
- `warmCastWarmth = 0.30` was never tripped by the corpus. Untested, not validated.

---

## 2. The gap list, ranked by impact on the bar

Classification per item:
**`[BUILD]`** = buildable now, no threshold guessing ·
**`[PASS]`** = needs Tori's on-device salon pass to set a number or confirm a sign ·
**`[DECIDE]`** = a product call, not an engineering one.

---

### 2.1 🔴 #1 — Exposure and skin-tone fidelity is judged on the *room*, not the *skin*

**This is the single biggest gap on the bar, and it is worst for the clients beauty
work most needs to serve well.**

**What the code does.** `LightingCoach` (`ShotCoach.swift:222-241`) makes its entire
"is this exposed correctly" judgement from **`ctx.avgLuma` — the whole-frame average**
against fixed bands (`lumaTooDark 0.22`, `lumaTooBright 0.78`, `lumaIdeal 0.47`,
`CoachTuning.swift:52-60`). `faceLuma` exists and is computed every frame
(`CoachEngine.swift:143`) but is used for **exactly one thing**: the backlit test.

Three consequences follow directly:

1. **A correctly-lit deep-complexion client against a light salon wall can be
   badly underexposed while the coach says nothing and the ring goes green.** Whole-frame
   luma is dominated by the wall. There is no coach anywhere in the stack that says
   "their *face* is dark." The frame passes; the photo is wrong.

2. **The backlit rule false-positives on deep skin.**
   `faceLuma < luma × 0.6 && faceLuma < 0.4` (`ShotCoach.swift:226-230`). Deeper skin
   reflects less light — that ratio is trippable in an evenly-lit room with no
   backlight at all. When it trips it scores **0.35 at weight 1.6 → deficit 1.04**,
   which outranks *every other coach including a soft frame*. The result for a
   deep-complexion client is the mixed-light failure mode all over again but worse:
   a permanently-stuck, wrong, unactionable line — *"Light's behind them — turn them to
   face the window"* — while the actual problem (the face is under-exposed) is never named.

3. **`faceExposureBias = -0.3 EV` is applied uniformly** whenever a face is metered
   (`CameraController.swift:257`, `CoachTuning.swift:66`). Its stated purpose is
   highlight protection. Metering *on* a deep-skin face already drives the meter to
   render that face near mid-grey, which brightens the whole scene; −0.3 EV on top then
   pulls the face back down. There is no complexion-adaptive term and no measurement
   that this bias is right across the range.

4. **Post-capture QC repeats the mistake.** `PhotoQC` gates on whole-image luma
   `0.14…0.88` (`PhotoQC.swift:110-116`, `CoachTuning.swift:147-149`) — so a
   correctly-exposed close-up of deep skin, or a shot on a dark backdrop, can be
   offered as a retake for being "too dark."

**Why it matters to the bar.** A photographer's first act is to expose for the skin. An
app that never measures whether the *face* is correctly exposed cannot claim to be one —
and the failure is not evenly distributed: it degrades for exactly the complexions the
industry has historically served worst ([Imatest], [Allure]).

**Also relevant:** the offline bench corpus is 23 Xcode sample photographs
(`docs/camera-tuning-bench.md`), which reports `luma` but **never reports `faceLuma`
and has no complexion coverage at all**. Nothing in the project has ever measured this.

**Classification: `[BUILD]` + `[PASS]`.**
- ✅ `[BUILD]` — restructure `LightingCoach` to judge the **face region** when a face is
  present, falling back to whole-frame only when there isn't one. Restructure the
  backlit test to compare face luma against the **segmented background** luma (the mask
  is already computed and thrown away, `CoachEngine.swift:287-310`) rather than the
  whole frame, which contains the face. Both are pure arithmetic, pinnable in
  `CoachReadinessTests` without a camera. **Done 2026-08-04**, and `PhotoQC`'s
  exposure gate was relocated onto the face for the same reason (point 4 above).
- `[PASS]` — the target face-luma band, per complexion, and whether `-0.3 EV` holds.
  See §3.1: this is the single most important measurement of the whole device pass.

> ### ⚠️ Added by the build — read before §3.1
>
> **Relocating the backlit test made it MORE sensitive at the current
> `backlitFaceRatio = 0.6`, not less.** The segmented background is brighter than
> a whole-frame average that the darker subject was dragging down, so
> `background × 0.6` is a *higher* bar to clear than `frame × 0.6`.
>
> The relocation is still the right comparison — face-vs-background is what "the
> light is behind them" actually means — but this document's point 2 above
> over-claimed: relocation alone does **not** remove the deep-skin false
> positive. No ratio of skin *reflectance* to background *illumination* can
> separate "less light on their face" from "less light coming back off their
> face". Only §3.1's per-complexion measurement can, and `backlitFaceMaxLuma =
> 0.4` is what bounds the damage until it lands.
>
> Pinned as `CoachReadinessTests.relocatingTheBacklitTestMakesItMoreSensitiveNotLess`,
> and the bench now prints a per-image `backlit?` column flagging any image the
> relocation newly fires on.
>
> **Second finding, also new:** an outright lighting failure *alone* does not
> drop a frame out of the green ring — and does not even fall short of the
> harvest gate. Lighting is the heaviest coach and still only 1.6 of 7.5 total
> weight, so scoring it 0.3 lands at **0.851**, over `readyThreshold` (0.80) and
> over `harvestThreshold` (0.85). So the coach now correctly says "their face is
> too dark" while auto-capture fires anyway and the reel keeps the frame.
> Fixing it means moving `readyThreshold`, the lighting weight, or the failure
> score — all `[PASS]`. Pinned as
> `aLightingFailureAloneStillClearsBothTheRingAndTheHarvestGate`.

---

### 2.2 🔴 #2 — Every colour signal is measured on content, so skin and clothes read as light

**What the code does.** `colorSignal` (`CoachEngine.swift:244-256`) computes:
- `mixed` = spread of warmth across the frame's **left / middle / right thirds**
- `warmth` = `(r−b)/(r+b)` of the **whole frame** (`FrameMath.swift:43-45`)
- `greenTint` = green excess of the **whole frame**

None of these exclude the subject. The bench already documented the confound
(`docs/camera-tuning-bench.md`, "The finding that matters"): a red top on one side and a
cool wall on the other reads as mixed light under perfectly uniform illumination.

**The sharpening the bench didn't make:** the confound **scales with how much of the
frame is skin**. It is therefore worst on exactly the shots that matter most — a tight
beauty close-up, a detail shot, a deep-complexion subject filling the frame — because
warm-toned skin *is* a warm cast to a whole-frame average. `warmCastWarmth = 0.30` was
never tripped by the bench corpus and is completely unvalidated
(`CoachTuning.swift:121-123`).

**The pipeline it feeds is real and good.** The card path is genuinely serious work:
rectangle detection + perspective rectification + gray-ramp validation + 180° retry
(`CardCorrection.swift:48-115`), WB-then-matrix ordering so the correction can't
double-apply (`ProCapturePhotosView.swift:1183-1248`), persistence per custody scope so
before and after share one calibration, and drift detection. The problem is not the
plumbing; it's the signals and two unfinished pieces:

- **The matrix is solved against colours the card does not have.**
  `docs/calibration/README.md:39-54` states it plainly: a dye-sub printer is not colour
  accurate, so until each print batch is measured, *"the matrix built from nominal values
  is illustrative only."* Today the card path **locks a real white balance (good) and
  then applies a decorative matrix.** `BACKLOG.md §3` tracks this as **B4**, blocked on
  physical cards.
- **Corrected and uncorrected photos may ship in different colour spaces.** The capture
  session leaves `automaticallyConfiguresCaptureDeviceForWideColor` at its default
  (`CameraController.swift:421-476` sets it nowhere), so captures are likely Display P3
  tagged; `CardCorrection.applySync` re-encodes explicitly to **sRGB**
  (`CardCorrection.swift:143-147`). So whether a card was scanned changes the colour
  space of the shipped JPEG — within one shoot, if the pro scans mid-session.

**Classification:**
- ✅ `[BUILD]` — measure `mixed`, `warmth`, `greenTint` on the **segmented background only**.
  The person mask is already computed at 2.5 fps and currently used for one scalar.
  This is a pure relocation of an existing measurement; it kills the content confound
  without touching a single threshold. **Done.** The bench measured the result:
  `mixed` median 0.120 → **0.086**, false fires 17/35 → **11/35**. The August 1
  finding is fixed by the relocation alone, with the threshold untouched.
- ✅ `[BUILD]` — pin the output colour space so corrected and uncorrected bytes agree.
  **Done** — sRGB on both paths (`automaticallyConfiguresCaptureDeviceForWideColor
  = false` plus an explicit `activeColorSpace`). That it holds on real formats is §3.7.
- `[PASS]` — re-measure `mixedLightSpread`, `warmCastWarmth`, `greenCastTint` against
  real salon light *after* the background-only change lands, per the bench's own
  recommendation #1.
- `[DECIDE]` — do we ship a measured card batch (unblocking B4) or drop the matrix and
  keep the WB lock, which already works and needs no card at all?
- `[DECIDE]` — should `ColorCoach`'s weight of 1.1 survive? A low-confidence,
  frequently-unactionable signal currently outranks focus and tilt for the one line
  (bench recommendation #3). See also §2.5.

---

### 2.3 🟠 #3 — Before/after consistency: the two most important axes are unmeasured

Before/after *is* the product. Three of the four things that make a pair read as true
are handled; the fourth and most-cited one is not.

**What exists.**
- **Angle** — onion-skin ghost of the matching before shot, indexed to the guide step
  (`ProCapturePhotosView.swift:821-836`, `:432-435`).
- **Light** — each before is stamped with luma + warmth and the live frame is compared
  against it (`:1553-1568`, `:1573-1597`), with tolerances in `CoachTuning.swift:128-130`.
- **Colour** — WB gains and the card matrix persist per booking, so the after inherits
  the before's calibration (`:327-345`, `:1549-1551`). This is genuinely excellent.

**What's missing.**

1. **Framing parity is never measured.** The industry's most-cited before/after mistake
   is *shooting the before tight and the after loose* — the brain then reads "the after
   looks bigger because it *is* bigger," not because the work is better ([Goldie]).
   Tovis ghosts the before for visual alignment, but nothing measures the **face rect and
   subject fill of the before** and coaches the after toward the same numbers. Every
   ingredient is already computed: `PhotoQC` produces the before's face rect
   (`PhotoQC.swift:96-103`), `ReferenceLookAnalyzer` already derives a `fillBand` from a
   picked photo (`ReferenceLook.swift:149-154`), and `CompositionCoach` already enforces a
   `fillBand` (`ShotCoach.swift:260-271`). Nothing connects them for the *booking's own
   before shot*.

2. **The light-match signal punishes the transformation.** `lightMatch`
   (`ProCapturePhotosView.swift:1573-1597`) compares whole-frame luma and warmth. A
   dark-to-blonde colour service **legitimately changes whole-frame luma** — that's the
   work. The coach will say *"Brighter than the before — dim a touch"* about a
   transformation that succeeded. Same content confound as §2.2, same fix: compare the
   **background** light of before vs after, not the whole frame.

3. **Exposure is re-metered between phases.** WB is locked and carried; AE is not. The
   after is metered fresh (`CameraController.swift:232-263`), so an identical scene can
   render at a different brightness across the pair.

4. **No distance / lens record.** Nothing captures how far away the before was shot. A
   pro who shoots the before at arm's length and the after two feet back gets a
   mismatched pair even with the ghost lined up.

5. **Cape / drape is a pure coaching gap.** The standard advice is: before shot the
   moment they sit, *before the cape goes on*; after with the cape *off* ([Goldie]).
   Nothing in `ShotGuide.swift:147-183` says this.

**Classification:**
- ✅ `[BUILD]` — derive the after's `fillBand` and face-position target from the **measured
  before shot** and feed it through the existing `ShotExpectations` machinery. Threshold-free:
  the target *is* the before's own number. **Done** — `BeforeShotMeasure`, whose
  band derivation "match a look" now shares rather than duplicating.
- ✅ `[BUILD]` — move the light-match comparison onto the segmented background. **Done**,
  on both sides: the live frame and the before's stamp. It falls back to whole-frame
  when either side has no mask, rather than comparing two different quantities.
- ✅ `[BUILD]` — add cape/drape lines to the hair + face guides. Pure copy. **Done.**
- `[PASS]` — whether carrying the before's AE lock into the after helps or hurts in a real
  room with the client moving.
- `[DECIDE]` — should the after phase *offer* to lock exposure to the before's, or just do it?

---

### 2.4 🟠 #4 — The camera composes for a 3:4 sensor and publishes to 9:16

**What the code does.** The crop-safe overlay draws a bright 9:16 box (the Tovis Looks
feed's own crop) and a dim 4:5 box (`ProCapturePhotosView.swift:1017-1062`), on by
default (`CoachSettings.swift:20-24`). The comment is exactly right: a 3:4 capture loses
~40% of its width to a 9:16 feed crop.

**The gap:** the overlay is **advisory only**, and the coach is not aware of it.
`CompositionCoach` judges headroom, centering and subject fill against the **full 3:4
frame** (`ShotCoach.swift:252-307`). So the coach can call a frame perfectly composed —
green ring, auto-capture fires — while the published 9:16 crop takes the sides off it. The
one part of the pipeline that *is* crop-aware is the focal point (`PhotoQC.swift:119-122`),
which centres the feed crop on the face; that fixes the *centre* of the crop, not what
falls outside it.

**Platform coverage is also incomplete** against what beauty content actually needs
([Somake], [Postplanify]):

| Format | Needed for | Tovis today |
|---|---|---|
| 9:16 (1080×1920) | Reels / TikTok / Shorts / the Tovis feed | ✅ primary box |
| 4:5 (1080×1350) | Instagram feed's tallest post | ⚠️ drawn dim, secondary |
| 1:1 | IG profile grid, many ad units | ❌ absent |
| Reels **cover** safe zone (clear top ~220 px, bottom ~450 px) | The cover is what stops the scroll | ❌ absent |
| Cross-platform safe zone (~900×1400 centred) | Posting the same clip everywhere | ❌ absent |

And nothing **produces** a platform-ready file: there is no 9:16 render, no cover
export, no share-to-Instagram path from the camera. `ShareLink` exists across the app
for *links* (`LooksView.swift:929`, `LookDetailView.swift:199`, …) — never for a rendered
asset.

**Why it matters to the bar.** "Social media expert" is half the promise. Right now the
app is a very good photographer and not yet a social media expert: it produces excellent
source material and hands the pro a 3:4 JPEG.

**Classification:**
- ✅ `[BUILD]` — when the crop guide is on, judge composition **inside the 9:16 box**
  (subject fill, headroom, centering) rather than the full frame. No new thresholds: the
  existing ones re-evaluated on a sub-rect. **Done** — and a subject that falls
  outside the crop entirely now gets its own line rather than a vague "center your
  subject". `PublishCrop` is the single source the overlay draws and the coach judges.
- ✅ `[BUILD]` — add the Reels-cover safe band to the overlay. Fixed, published numbers. **Done.**
- `[DECIDE]` — should 4:5 be co-primary with 9:16? Instagram's feed is where salon
  before/afters get saved and shared; the dim treatment says it's an afterthought.
- `[DECIDE]` — **does Tovis export platform-ready assets, or stop at upload?** This is the
  largest single scope question in this document. A "make me a Reel cover / a 9:16 export /
  a 4-up carousel" step is a different product surface from a camera.
  (Note: the built-in guides already *produce* the shot list a carousel wants — before,
  process, detail, full after — which is reported to outperform a single split-screen
  ~3:1 on saves and shares ([SalonSOS]). The assets exist; the assembly doesn't.)

---

### 2.5 🟠 #5 — The coach nags rather than teaches, and the mechanism is in the code

Tori's original complaint — *"so much going on… I feel overwhelmed instead of feeling
like it's helping me"* — plus the later *one wrong unchanging tip*. Step 2 fixed the
overwhelm by cutting 13 elements to 5. That subtraction made the remaining single line
carry the entire coaching experience, which exposed three separate defects.

**(a) There is no dwell time or hysteresis on the tip.**
`CoachAggregate.evaluate` recomputes the winner every analyzed frame by a plain `max`
over weighted deficits (`ShotCoach.swift:207-210`) — 6 times a second
(`CoachTuning.swift:22`). Two coaches with near-equal deficits will **alternate**. There
is no "this tip has been up for less than N seconds, leave it," and no margin a
challenger must beat.

**(b) Every alternation fires a warning haptic and restarts speech.**
`CoachEngine.swift:457-463`:
```
if result.nudge != nudge {
    nudge = result.nudge
    if settings.haptics { tap(.warning) }
    if settings.speak  { speak(nudge.message) }
}
```
and `speak` explicitly cancels any in-flight utterance (`:505`). Two tied coaches
therefore produce a **continuous warning buzz and a sentence that never finishes**. This
is a concrete, code-level mechanism for "it feels like nagging," independent of whether
the tips are correct.

**(c) The tips are imperatives with no *why* and no memory.**
Every message in `ShotCoach.swift` is a command: *"Move in closer,"* *"Hold steady,"*
*"Turn off the overheads."* There is no explanation, no escalation, no positive
confirmation when the pro fixes something (only a `.success` haptic on entering the green
ring, `CoachEngine.swift:466`), no "you've been 3° left all session," and no suppression
of tips the pro has demonstrably declined to act on. The `DimensionsDrawer`
(`CameraDrawers.swift:22-92`) shows all seven, but each row shows **the same imperative
string** — there is nowhere in the app that says *why* a busy background hurts a photo.

A photographer says "get closer — right now the hair is competing with the shelf, and
when this crops to 9:16 you'll lose the ends." Tovis says "Move in closer — fill the frame."

**(d) One of the seven coaches is mute, one is a permanent tax.**
`BackgroundCoach` fires on 0/17 portraits (bench). `PoseCoach` returns a hard `0.9` cap
whenever a body is detected (`ShotCoach.swift:416`) with **no message** — a permanent
0.06 readiness tax the pro can never clear and is never told about. In a portrait
session, that is always.

**Classification:**
- ✅ `[BUILD]` — minimum tip dwell (a tip holds the lane for N seconds) + a switching margin
  (a challenger must beat the incumbent's deficit by δ). Pure arithmetic in
  `CoachAggregate`, fully testable in `CoachReadinessTests` with no device. **This is the
  highest value-per-line change in the document.** **Done** — `CoachTipArbiter`,
  with its own suite.
- ✅ `[BUILD]` — rate-limit haptics and don't interrupt an in-flight utterance. **Done** —
  the buzz fires only when a *different dimension* takes the line, at most once per 2 s;
  coach tips never cut off a sentence in flight, and directives queue behind rather
  than cancelling.
- ✅ `[BUILD]` — give every `CoachSignal` an optional `why` string, surfaced in the
  dimensions drawer. Copy + one field. **Done**, all seven coaches.
- ✅ `[BUILD]` — a confirmation beat when a previously-failing dimension clears ("Focus —
  got it"), so the coach is heard being satisfied and not only dissatisfied. **Done** —
  the arbiter reports the hand-back on the one frame it happens.
- ⏳ `[BUILD]` — lower `clutterReference` so `BackgroundCoach` can speak at all
  (bench recommendation #2). *Note: the bench measured the direction; the exact value is
  `[PASS]`.* **Not done, on purpose:** there is no way to "lower it" without picking
  a number, and the number is reserved. It stays a §3.2 item. The bench re-confirms
  the direction: `BackgroundCoach` still fires on 0 portraits.

> ### ⚠️ Added by the build — the three new numbers
>
> The dwell, the switching margin and the haptic floor are new tunables
> (`tipDwellSeconds = 2.5`, `tipSwitchMargin = 0.15`,
> `nudgeHapticMinInterval = 2.0`), kept in their own `CoachTuning` section marked
> **behavioural, not perception**. They are set by how long a person takes to
> read a line and start acting — a stopwatch, not a sensor — so the salon pass
> does not invalidate them.
>
> But it should still *feel* them. "Does the coach still nag?" is the question
> that started this whole chain, and no bench can answer it. If 2.5 s reads as
> sluggish, or the margin makes a genuinely worse problem wait too long, those
> are the two dials — and both are live-tunable from the DEBUG HUD.
- `[DECIDE]` — what does the coach do about a tip the pro **cannot act on**? "Turn off the
  overheads" is not available to someone renting a chair. Options: rank unactionable tips
  down; offer the alternative (*"can't? then move them 3 feet toward the window"*); or let
  the pro mark a condition as fixed-for-this-room and stop mentioning it.
- `[DECIDE]` — does the coach get a memory across a shoot / across a pro's history? "Every
  shot you take is 3° left" is the single most photographer-like thing the app could say,
  and it needs a store.

---

### 2.6 🟠 #6 — Auto-capture stalls silently after a rejected burst

**Confirmed by reading; needs a device to see.**

The guided auto-shot arms and fires like this:
- `attemptGuidedCapture()` sets `autoArmed = false` before shooting
  (`ProCapturePhotosView.swift:1341`).
- It is re-armed **only** when readiness drops out of the green ring
  (`:474-476`: `if !ready { autoArmed = true }`).
- `autoCaptureBest()` takes up to 3 frames and keeps the first that passes QC. **If none
  pass, nothing uploads and the guide does not advance** (`:2045-2069`), and it sets
  `errorMessage = "<reason> — holding for another try."`

Now trace a QC rejection while the client holds perfectly still:
`resetHold()` clears the hold (`CoachEngine.swift:484-488`), the next frame re-establishes
it, `isSteadyReady` flips false → true, `.onChange` fires (`:477-479`) — and finds
`autoArmed == false`. `isReady` never changed, so the re-arm at `:474` never runs. The
`uploading` / `isReviewing` retry hooks (`:426-429`) require `guidedCaptureQueued`, which
`attemptGuidedCapture` set to `false` at `:1340`.

**Result: auto-capture is dead until something breaks the ready state**, while the lane
says "holding for another try." The success path self-heals (advancing the step changes
`activeExpectations`, which drops readiness), so this only bites on the rejection path —
which is precisely when the pro most needs the retry.

**Also unmeasured about auto-capture:**
- `autoCaptureHoldSeconds = 0.7` — guessed (`CoachTuning.swift:45`).
- `autoCaptureAttempts = 3` at `.quality` prioritization on 24 MP stills: three
  full-quality captures back-to-back is potentially multiple seconds of the subject
  holding a pose. Never timed.
- `analysisFPS 6` / `heavyFPS 2.5` — never thermal-tested. A long salon session with
  segmentation + pose at 2.5 fps on a warm phone is exactly where frame rate collapses.

**Classification:** ✅ `[BUILD]` the re-arm fix (one condition). `[PASS]` the hold time,
the burst timing, and the thermal behaviour.

**Done** — but not as one inline condition. The arming rule moved into
`GuidedCaptureArm`, a small state machine with its own tests, because this bug
was invisible in the UI and self-healing on the success path: it survived
precisely *because* it was a control-flow shape spread across two `.onChange`
handlers rather than a fact a test could assert. It is now the latter.

---

### 2.7 🟡 #7 — Sharpness is measured at a resolution where the failure is invisible

`FrameMath.sharpness` measures edge energy on a working image downscaled to
`workingMaxDim = 480` px on the long side (`FrameMath.swift:78-82`, `CoachTuning.swift:29`).
On a 3:4 frame that's 360×480; an expanded head-and-shoulders crop
(`FrameMath.swift:105-112`) is roughly 150×250 px.

For the **live coach** that's a defensible cost trade. But **`PhotoQC` does the same
thing** — it decodes the full-resolution capture and immediately downscales it to 480 px
before measuring (`PhotoQC.swift:83`, `:105`). The post-capture check whose entire job is
"verify the ACTUAL captured image" (`PhotoQC.swift:1-6`) therefore **cannot see softness
that only appears above 480 px** — which is most of the softness that ruins a 24 MP photo
on a phone screen at 100%.

The bench already found the divisor generous in the other direction: 14/23 photos score a
perfect 1.0 and 4 saturate the metric, while 2 well-focused photos are still called
"clearly soft."

**Related, and concrete:** the **nails guide asks for a shot the hardware cannot take.**
`ShotGuide.swift:166` — *"Detail — Macro on one nail — show the finish"* with
`expects: .detail`, which multiplies the sharpness bar by 1.25 (`CoachTuning.swift:92-93`).
But the session only ever uses `builtInWideAngleCamera` (`CameraController.swift:428`) —
**no macro switching, no ultra-wide, no lens or zoom control anywhere in the stack**. On a
device where macro requires the ultra-wide (auto-switch happens only via a virtual device
like `builtInTripleCamera`), a genuine one-nail macro is out of focus range. The coach
will then nag "Hold steady — shot looks soft" forever at a shot that is physically
impossible with the selected device.

**Classification:**
- ⏳ `[BUILD]` — measure QC sharpness at a materially higher resolution than the live coach
  (QC runs once per shot off the main actor; it can afford it). Requires a new QC-specific
  reference divisor → the *value* is `[PASS]`, the *split* is `[BUILD]`.
  **Not done, on purpose.** Splitting the resolution without the divisor to go with
  it changes every QC verdict by an unknown amount: raw edge energy is
  resolution-dependent, so QC would start rejecting shots it used to pass, with no
  measurement behind it. The split and the divisor have to land together, in §3.4.
  *(This is the one §4 item whose `[BUILD]` half turned out not to be separable.
  It is not in the B1–B17 list — B-numbers cover the seventeen that were.)*
- ✅ `[BUILD]` — offer the virtual multi-camera device (`builtInTripleCamera` /
  `builtInDualWideCamera`) with a wide-angle fallback, so macro auto-switch and zoom
  become available. This also unlocks a lens/zoom control the app has never had.
  **Done** — see the ⚠️ note on B14 in §4 about zoom factor 1.0 being the ultra-wide.
  The nails step's copy was made honest in the same change rather than left
  promising a macro that may still be out of range.
- `[PASS]` — `sharpnessReference` against live preview frames, and whether the coach's
  read tracks what the pro sees at 100%.

---

### 2.8 🟡 #8 — Video is the least-finished surface

Everything below is grounded in what `CameraController` does and does not do.

| Concern | Status |
|---|---|
| **Stabilization** | ❌ **Never set.** `startRecording` configures only the rotation angle (`CameraController.swift:374-378`). `preferredVideoStabilizationMode` defaults to off — handheld salon clips will be shaky. |
| **Resolution / frame rate** | ⚠️ Inherited from `sessionPreset = .photo` (`:426`), which is a *stills* preset. The recorded clip is 4:3 portrait, not 9:16, and the fps is whatever the photo format gives. Never measured. |
| **Clip length** | ❌ No cap. `movieOutput.maxRecordedDuration` is never set. |
| **Colour correction cost** | ⚠️ `CardCorrection.applyToVideo` re-exports the **entire clip** through a per-frame `CIColorMatrix` at `AVAssetExportPresetHighestQuality` (`CardCorrection.swift:156-183`). With no length cap, a long take means a long export, a large temp file, and a large upload — on a phone that is also running the coach. |
| **Audio** | ❌ None, by design (`CameraController.swift:40-41`). |
| **Bitrate / codec** | ❌ Never specified. |
| **Practice clips** | ❌ Deliberately hidden (`ProCapturePhotosView.swift:1815-1834`) — `PracticeShot` has no poster-frame columns. Flagged as a decision, not half-built. |

**On the no-audio decision.** For the in-app Looks feed (which autoplays muted) it costs
nothing and is a clean privacy posture: a salon is full of other people's conversations.
But a pro who wants that clip on Reels or TikTok gets a silent file, and both platforms'
ranking and creative conventions assume audio (or at minimum a sound the creator adds).
The decision is defensible; it should be *chosen* rather than inherited, and if it stands
the app should say so where the pro records.

**Classification:**
- `[BUILD]` — set `preferredVideoStabilizationMode` (with a support check), cap clip
  duration, and specify the recording format explicitly rather than inheriting the photo
  preset.
- `[PASS]` — measure what the clip actually is today (resolution, fps, size, correction
  export time for a 30 s take) before choosing targets.
- `[DECIDE]` — **audio: keep silent, or offer an opt-in with an on-screen indicator?**
- `[DECIDE]` — practice clips (two nullable columns + a poster copy on attach).

---

### 2.9 🟡 #9 — There is no post-capture enhancement policy, only an absence

**What happens to a captured photo today:** the card matrix is baked in when a card was
scanned, and the bytes are uploaded (`ProCapturePhotosView.swift:2113-2132`). That is
**all**. No tone curve, no shadow lift, no denoise, no sharpening, no skin work, no
straightening, no cropping.

This is an *honest* default and it should be defended — but the current state is an
absence, not a policy, and it has two costs:

1. **Even honest processing is missing.** A shadow lift on an under-exposed deep-skin
   subject, a lens-distortion correction on a close portrait, or a consistent tone curve
   are all things a photographer does and none of them touch the work.
2. **Nothing states the integrity rule**, so the first time anyone asks for "make it pop"
   there is no written line to point at.

**Proposed policy (for Tori's approval, not implemented):**

> **A. Calibration is always allowed.** White balance, exposure anchoring, and the card
> matrix make the photo *more* truthful. Always on.
>
> **B. Global finishing is allowed only if symmetric.** Any tone/contrast/sharpening
> adjustment must be applied **identically to the before and the after of the same
> booking**, from stored parameters, or not at all. An asymmetric finish is a lie about
> the work regardless of intent.
>
> **C. Nothing that alters the work.** No skin smoothing, no teeth or eye whitening, no
> hair-colour saturation, no nail-shine boost, no reshaping. These change the thing the
> client is being sold.
>
> **D. Whatever is applied is disclosed and reversible.** The pro can see what was done
> and turn it off; the original bytes are what's stored.

**Classification:** `[DECIDE]` first (the policy), then `[BUILD]` (symmetric finishing
infrastructure), then `[PASS]` (what a real salon photo actually needs lifted).

---

### 2.10 🟡 #10 — Background treatment is one dead scalar

The person-segmentation mask is computed at 2.5 fps (`CoachEngine.swift:287-310`), reduced
to **one number**, and discarded. That one number then fails to fire on any portrait
(bench). So the app's entire background capability is currently: nothing.

What the mask makes possible with no new perception work:
- Locating the clutter (*"the shelf on the left"*) instead of a general complaint.
- A background-only measurement basis for light and colour (§2.2, §2.3).
- A depth-free background blur / portrait finish (subject to §2.9's policy — likely
  allowed on marketing shots, likely **not** on a before/after pair, since it changes the
  scene between the two).

Salon-specific background problems the stack does not model at all — and which are, in
practice, the ones that ruin real salon photos:
- **The phone / the stylist visible in the salon mirror.** Pros shoot toward mirrors
  constantly. A rectangle detector already exists in the codebase
  (`CardCorrection.swift:73-99`) and could be pointed at this.
- Stray people, station clutter, product bottles, a cape still on the client (§2.3).

**Classification:** `[BUILD]` clutter localisation and the background-only measurement
basis. `[PASS]` any new detector's thresholds. `[DECIDE]` background blur (does it violate
before/after integrity?).

✅ **The background-only measurement basis is done** — it is the spine of B1–B3
and B8, and it is what §2.2's numbers above measure. ⏳ **Clutter LOCALISATION
("the shelf on the left") is not**, and it is not in B1–B17: naming a region
means choosing how much edge energy in a region counts as "the clutter", which
is a threshold. It belongs with `clutterReference` in §3.2.

---

### 2.11 Smaller items, for completeness

| Item | Evidence | Class |
|---|---|---|
| Level tilt **sign** ("tilted right" vs "left") never verified on hardware | `ShotCoach.swift:470-471`, `DeviceLevel.swift:31-34` | `[PASS]` |
| Face-exposure coordinate mapping `(x,y)→(y,1−x)` never verified | `CameraController.swift:240-241` | `[PASS]` |
| Green ring (0.80) and harvest gate (0.85) disagree; reel can stay empty all session | `CoachTuning.swift:40,47`; `CoachReadinessTests.aFrameCanBeGreenAndStillNeverHarvest` | `[PASS]` + `[DECIDE]` |
| "Best shots" are harvested from the **video** buffer, not the photo output — the app's own comment says "video-res" | `CoachEngine.swift:220-228`, `CoachSettings.swift:33-34` | `[PASS]` (measure the gap) + `[DECIDE]` (is video-res acceptable for the Looks feed?) |
| ✅ `PoseCoach` caps readiness at 0.9 with no message whenever a body is seen | `ShotCoach.swift:416` | `[BUILD]` — **done**, cap removed |
| No torch / fill-light control and no manual exposure compensation for the pro | absent from `CameraController` | `[DECIDE]` |
| No front camera (correct for shooting a client; worth confirming no pro wants a selfie mode) | `CameraController.swift:428` | `[DECIDE]` |
| Card matrix is nominal, not measured per print batch | `docs/calibration/README.md:39-54`, `BACKLOG.md §3 B4` | `[DECIDE]` |
| NFC card-version read not wired | `BACKLOG.md §3 B4` | `[DECIDE]` |
| ⚠️ Offline bench has no complexion coverage and never reports `faceLuma` | `docs/camera-tuning-bench.md` | `[BUILD]` — **`faceLuma` + background columns done; the CORPUS is still not complexion-diverse.** Point `run.sh` at one and §3.1 becomes a confirmation |
| Capture latency at `.quality` on 24 MP never timed | `CameraController.swift:135` | `[PASS]` |

---

## 3. What Tori's on-device salon pass must measure

This is a **measurement** pass, not a look-at-it pass. `CoachTuningHUD` streams the raw
signals live (`Tovis/CoachTuningHUD.swift`, DEBUG, reachable from camera settings →
Developer). Every row below should end in a written number.

> ⚠️ Environment notes from the memory log: the simulator MCP and computer-use both fail
> on this machine — drive `xcrun simctl` and DEBUG launch keys. None of that helps here:
> **every item below needs the physical phone in a real salon.**

### 3.1 🔴 The complexion sweep — the most important table in the pass

**Setup:** one room, one light, unchanged, for the whole sweep. At least three subjects
spanning clearly separated complexions (light / medium / deep). Same distance, same
framing, back-to-back.

Record, per subject, from the tuning HUD:

| Column | Why |
|---|---|
| `luma` (whole frame) | what `LightingCoach` actually judges today |
| `faceLuma` | what it *should* judge (§2.1) |
| `faceLuma / luma` | whether the backlit rule (`< 0.6`) false-positives |
| `warmth` | whether skin drives the warm-cast reading (§2.2) |
| `mixed` | whether a face on one side drives the mixed reading |
| **the coach's actual on-screen line** | the outcome that matters |
| `READY` | whether the ring agrees with your eyes |

Then repeat **with the subject against a light wall and against a dark wall**, because
that is the axis on which the whole-frame metric fails.

**Decision this table drives:** the face-luma target band, whether `-0.3 EV` holds across
complexions, and the new backlit ratio.

**Also shoot and keep the JPEGs.** Then look at them on a good screen: does the deepest
complexion render *true*, or lightened? That is a judgement no metric makes for you.

### 3.2 The salon-light sweep

Five conditions, same subject, same framing: window only · overheads only · window +
overheads (the real case) · ring light · evening/dim.

Record `luma`, `warmth`, `greenTint`, `mixed`, the coach's line, and `READY` for each.

**Decision this drives:** `mixedLightSpread`, `warmCastWarmth`, `greenCastTint`,
`lumaTooDark`/`lumaIdeal`. Per the bench's recommendation, **do this after the
background-only change lands** (§2.2) — otherwise you are tuning a confounded signal.

### 3.3 The two unverified mappings

- **Tilt sign.** Roll the phone clockwise. Does it say "tilted right"? (`ShotCoach.swift:470`)
- **Face-exposure point.** Put a face in each corner of the frame in turn against a bright
  background. Does the exposure track the face? (`CameraController.swift:240-241`)

Both are one-minute checks that unblock two `⚠️` comments in shipped code.

### 3.4 Sharpness reality check

Shoot the same subject three ways: tack sharp · slightly soft · clearly motion-blurred.
Record the live `sharpness` value **and** open each full-res JPEG at 100%.

**Question to answer:** at what live value does the photo stop being usable? And does QC
(which measures at 480 px, §2.7) catch the ones you'd reject?

Then: attempt the **nails macro shot** (`ShotGuide.swift:166`). Can the wide camera focus
on one nail at all? This single test settles §2.7's lens question.

### 3.5 Auto-capture behaviour

- Time the hold: does 0.7 s feel like a photographer, or like a trap?
- Time the burst: how long do 3 quality captures actually take?
- **Force a QC rejection** (blink, or shake at the moment it fires) and then hold
  perfectly still. **Does auto-capture ever fire again?** This confirms §2.6 on hardware.
- Over a real 30-minute session: how many auto-captures fired, and how many did you keep?

### 3.6 Video

Record 30 seconds handheld. Record: resolution, fps, file size, whether it is 4:3 or 9:16,
how shaky it looks, and — with a card scanned — how long `applyToVideo` takes before the
upload starts.

### 3.7 Calibration

Card scan with the printed card, and (DEBUG) with a ColorChecker if one is available —
the diagnostics sheet (`ProCapturePhotosView.swift:1104-1142`) reads out per-patch
measured-vs-reference. Then: shoot the same subject with and without the card applied and
compare. **Does the card visibly improve the photo, or only the white balance?** That
answers whether B4 is worth unblocking.

Also: leave the card scanned, then change the light (turn the overheads off). Does the
drift nudge appear after ~8 s? (`CoachTuning.swift:136-139`)

### 3.8 Thermal + endurance

Run the camera continuously for 10 minutes with the coach on. Does the preview stay
smooth? Does the phone throttle? Does the app get jetsam'd? (`analysisFPS`, `heavyFPS`.)

### 3.9 The device checks already owed

From `HANDOFF-camera-redesign.md`, still unverified and worth folding into the same pass:
the requirement card appearing on the first keeper and retiring on the second · the
**Done** accent flipping at one photo · the exit sentence when leaving a phase with
nothing shot · the practice camera actually shooting · a practice tile with a real
thumbnail · the attach sheet's two flows · the centre button flipping back mid-shoot
when a session starts · onion-skin alignment · EXIF orientation in the web gallery.

---

## 4. What can be built before the pass, without guessing a single threshold

> ✅ **ALL SEVENTEEN SHIPPED, 2026-08-04.** Two carry a caveat, marked in the
> table. `HANDOFF-camera-redesign.md` has the full account; the ⚠️ box in §2.1
> has the one finding that changes what §3.1 must do.

Ordered by value against the bar. Every item here either **relocates an existing
measurement**, **fixes arithmetic**, or **is copy** — none of them require a number the
device pass would invalidate.

| # | Change | Why it needs no threshold | Gap |
|---|---|---|---|
| ✅ **B1** | **Judge lighting on the face when a face is present.** Compare `faceLuma` to the target instead of `avgLuma`; keep whole-frame as the no-face fallback. | The *structure* change is threshold-free; the target band is set in §3.1. Ships behind the current value until measured, and immediately stops the whole-frame failure. | §2.1 |
| ✅ **B2** | **Measure the backlit test against the segmented background**, not the whole frame (which contains the face). | The mask already exists. Removes the deep-skin false positive at the source. | §2.1 |
| ✅ **B3** | **Move `mixed`, `warmth`, `greenTint` onto the segmented background.** | Pure relocation of an existing measurement. Kills the content confound the bench identified — before the pass re-measures the thresholds. | §2.2 |
| ✅ **B4** | **Tip dwell + switching margin in `CoachAggregate`.** A tip holds the lane for a minimum time; a challenger must beat it by a margin. | Arithmetic, fully pinnable in `CoachReadinessTests`. The single highest value-per-line fix for "it nags." | §2.5 |
| ✅ **B5** | **Rate-limit the haptic; don't interrupt an in-flight utterance.** | Behavioural, no perception involved. | §2.5 |
| ✅ **B6** | **Fix the auto-capture re-arm after a rejected burst.** | One condition. | §2.6 |
| ✅ **B7** | **Framing parity from the booking's own before shot** — measure the before's face rect + fill, feed it as the after's `fillBand` / position target through existing `ShotExpectations`. | The target *is* the before's measured number. Nothing is guessed. Addresses the most-cited before/after mistake. | §2.3 |
| ✅ **B8** | **Light-match on the background**, so a colour transformation doesn't read as a light change. | Same relocation as B3. | §2.3 |
| ✅ **B9** | **Judge composition inside the 9:16 box when the crop guide is on.** | Existing rules on a sub-rect. | §2.4 |
| ✅ **B10** | **Add the Reels-cover safe band to the crop overlay.** | Published, fixed numbers (top ~220 px / bottom ~450 px of 1080×1920). | §2.4 |
| ✅ **B11** | **Give `CoachSignal` an optional `why`**, shown in the dimensions drawer; add a confirmation beat when a dimension clears. | Copy + one field. Turns nagging into teaching. | §2.5 |
| ⚠️ **B12** | **Video: set stabilization, cap clip duration, specify the recording format explicitly.** | Stabilization is a mode, not a threshold; the cap is a product number, not a measurement. | §2.8 |
| | ⚠️ *Shipped as stabilization `.auto` + a 60 s cap. The FORMAT was deliberately left inherited:* *resolution and fps are `[PASS]` (§3.6) and cannot be targeted before they are measured, and changing the codec blind risks web playback — HEVC in a `.mov` does not play in Chrome. Measure first, then choose.* | |
| ✅ **B13** | **Pin the output colour space** so corrected and uncorrected captures agree. | Correctness, not tuning. | §2.2 |
| ⚠️ **B14** | **Offer the virtual multi-camera device** with a wide fallback, unlocking macro auto-switch + zoom. | Capability, not calibration. Makes the nails macro step possible before you test it in §3.4. | §2.7 |
| | ⚠️ *Shipped triple → dual-wide → dual → wide. On a triple camera zoom 1.0 is the ULTRA-WIDE, so the session is parked on the wide constituent to keep today's framing; that arithmetic is tested, but that it holds on real glass is a §3.4 check. The nails step's copy was made honest in the meantime rather than left promising an impossible macro.* | |
| ✅ **B15** | **Remove the silent `PoseCoach` 0.9 cap** (or give it a message). | An unexplained permanent penalty is a bug either way. | §2.11 |
| ✅ **B16** | **Guide copy: cape off before the after; before shot the moment they sit.** | Pure copy in `ShotGuide.swift`. | §2.3 |
| ✅ **B17** | **Extend the offline bench** to report `faceLuma`, `faceLuma/luma`, and the winning coach line per image — and point it at a complexion-diverse corpus. | Runs on the Mac, no device. **Do this first: it makes §3.1 a confirmation rather than a discovery.** | §2.1 |

**Suggested order:** B17 (so you can see the problem offline) → B1–B3 + B8 (fix what's
measured) → B4–B6 (fix how it speaks and fires) → B7, B9–B11 (the bar's remaining halves)
→ B12–B16.

**Built in that order.** B17 first paid off exactly as hoped: the bench now
reports both scopings side by side and shows that moving colour onto the
background drops the `mixed` median from 0.120 to 0.086 and the false-fire count
from 17/35 to 11/35 — the August 1 headline finding, fixed without touching the
threshold. It also surfaced the backlit-sensitivity direction in §2.1's ⚠️ box,
which no amount of reading the code would have made obvious.

---

## 5. Open product decisions

Each of these changes what gets built. None of them is an engineering call.

| # | Decision | Options | Note |
|---|---|---|---|
| **D1** | **Does Tovis produce platform-ready assets, or stop at upload?** | (a) stop at upload · (b) 9:16 + 4:5 exports with focal-aware crop · (c) full: cover frame, carousel assembly, share sheet | The biggest scope question here. "Social media expert" is half the promise, and today the app is only the photographer half. §2.4 |
| **D2** | **The enhancement policy** (§2.9). | (a) calibration only, forever · (b) + symmetric global finishing · (c) + optional beautification | Recommend (b). Before/after integrity is the product; (c) breaks it. |
| **D3** | **Clip audio.** | (a) stay silent · (b) opt-in with a visible indicator | Defensible either way; today it's inherited, not chosen. §2.8 |
| **D4** | **The card.** | (a) measure a print batch and unblock B4 · (b) drop the matrix, keep the WB lock (which already works with a white towel) | Today the matrix is decorative (`docs/calibration/README.md:54`). (b) is honest and free; (a) is real colour science and costs a spectrophotometer. |
| **D5** | **What the coach does with an unactionable tip.** | (a) rank down · (b) offer the alternative · (c) let the pro mark it fixed-for-this-room | This is the direct answer to "one wrong unchanging tip." §2.5 |
| **D6** | **Does the coach get memory?** | (a) per-shoot only (today) · (b) per-session patterns · (c) per-pro history | (c) is the most photographer-like thing the app could do and needs a store. §2.5 |
| **D7** | **Is 4:5 co-primary with 9:16?** | (a) keep 9:16 primary · (b) both bright | IG feed is where salon before/afters get saved. §2.4 |
| **D8** | **Are video-res "best shots" good enough for the Looks feed?** | (a) yes · (b) re-capture at photo res on a peak · (c) label them | §2.11 |
| **D9** | **Background blur / portrait finish.** | (a) never · (b) marketing shots only, never on a before/after pair · (c) anywhere | Falls out of D2. §2.10 |
| **D10** | **Practice clips.** | (a) stay photos-only · (b) two nullable poster columns + poster copy on attach | Already scoped in the handoff. §2.8 |
| **D11** | **Should auto-capture default ON?** | today: it's a setting | Depends entirely on §3.5's reliability numbers. |
| **D12** | **Front camera / torch / manual EV for the pro.** | (a) none (today) · (b) torch + EV slider | A dim salon has no fill-light affordance at all. §2.11 |

---

## 6. The shortest honest summary

The camera is **not** a thin veneer — the custody model, the card pipeline, the lane
arbitration and the pure-function testability are better than most shipping camera apps.
What's missing is narrower and sharper than "it needs polish":

1. **It measures the room where it should measure the subject.** Lighting, colour,
   before/after light matching and background clutter are all whole-frame averages. The
   person-segmentation mask that would fix every one of them is already computed and
   thrown away. This is one structural change, and it is the difference between a camera
   that works on some clients and one that works on every client.
2. **It speaks like a checklist, not a photographer.** Six-times-a-second re-ranking with
   no dwell, a haptic per change, an interrupted sentence, and imperatives with no *why*.
   All four are arithmetic and copy.
3. **It composes for the sensor and publishes to the feed**, and never bridges the two.
4. **It is a photographer, not yet a social media expert** — it ends at "uploaded."

Items 1, 2 and 3 are buildable **before** the device pass and would make the pass measure
signals worth tuning. Item 4 is a product decision, and it's the one that decides how big
this project actually is.

---

## Sources

Domain research supporting §2.3, §2.4 and §2.1:

- [How to take before and after photos in your salon like a pro — Goldie](https://heygoldie.com/blog/how-to-take-before-and-after-photos-in-your-salon)
- [Before-and-After Photos That Convert — SalonSOS](https://www.salonsos.ca/post/social-media-marketing-for-salons-before-after-photos)
- [Instagram Reel Size Guide 2026: Dimensions, Cover, Ratio & Safe Zone — Somake](https://www.somake.ai/blog/instagram-reel-size-guide)
- [Social Media Safe Zones: Full Guide for Creators (2026) — Postplanify](https://postplanify.com/blog/social-media-safe-zones-2026-complete-guide)
- [Equity in Camera Technologies: How Consumer Cameras Perform Across Skin Tones — Imatest](https://www.imatest.com/2024/02/equity-in-camera-technologies-how-consumer-cameras-perform-across-skin-tones/)
- [The Myth That Dark Skin Is Harder To Photograph — Allure](https://allure.ph/the-morena-manual/is-it-hard-to-photograph-dark-skin-tones/)
- [Best apps for hairstylists — GlossGenius](https://glossgenius.com/blog/best-apps-for-hairstylists) (what pros use today: Snapseed presets for consistency, split-screen before/after)
