# HANDOFF — Pro camera redesign

Running handoff for the **AI-photographer camera redesign** track. `BACKLOG.md`
stays the repo-wide index of open work; this file carries the redesign's own
thread — what shipped, what real-device use has said about it, and the decisions
that came out of that.

Design source of truth: Claude Design "Tovis Pro Camera Redesign.dc.html".

---

## Where the track stands

| Step | Shipped | What it did |
| --- | --- | --- |
| Refused-photo custody | #249 (`e079d9b`) | A photo the server refuses stops vanishing: terminal vs retryable uploads split, byte vault, exit holds the door on owed bytes. |
| Step 2 — subtraction | #250 (`d1b1012`) | Thirteen on-screen elements become five. One 56pt lane above the shutter with a six-tier priority queue (`CameraLane.message` — pure, unit-tested). Guide bar → one chip + a sheet; tools → one tray. |
| Coach tuning (offline) | #254 (`9efd7ac`) | `CoachAggregate` extracted pure; offline bench over real photographs. `mixedLightSpread` was firing on ~half of ordinary portraits and winning the single lane line. |
| One photo required | #255 (`9a42f0c`) | The camera stops reading as "shoot the whole set or you're not done". See below. |
| **Camera outside a session** | #261 (`85b6d9f`) | The footer's centre button stops being dead when no session is live. Same camera, same coach, no custody. See below. |
| Gap analysis vs the bar | 2026-08-04 | `docs/design/camera-excellence-plan.md` — the whole camera measured against "a real photographer is holding my hand", every claim cited to `file:line`, split into `[BUILD]` / `[PASS]` / `[DECIDE]`. |
| **Pre-device-pass fixes (B1–B17)** | #268 (`1089f2c`) | Everything the plan classified as buildable without guessing a threshold. See below. |
| **Save + social export pack (D1)** | #TBD | The camera stops at upload no longer. Save the original to Photos anywhere the pro sees their own work; make a signed 4:5 / 9:16 / before-after post from it. Plan D1 DECIDED. See below. |

Still owed: the on-device tune pass proper (`BACKLOG.md` §"Camera on-device tune
pass") — perception thresholds need the sensor, and the simulator has no camera.
The plan's §3 is now the agenda for that pass.

---

## Step: the camera outside a session (2026-08-04)

> Tori: "Can we have a way the pro can access the camera features when they
> aren't in a session? Maybe instead of the center button being disabled make it
> the camera button but when the pro is in session it stays the way we have it
> set up now?"

**Out of session the centre coin is a plain camera; in a session it is
byte-for-byte what it was.** When a session starts, the next poll takes the slot
back — session flow always wins it. The rule is
`ProSessionModel.isStandaloneCamera`, keyed on the server's `center.action`
being `NONE`/`UNKNOWN`, deliberately NOT on `centerDisabled`: the other disabled
states (a tap in flight, START with no booking id, a picker with nothing to
pick) are session states, and hijacking those would replace a Start button
mid-flow.

### One camera, not two

The whole difference between the two shoots is a value type,
`Tovis/ProCameraDestination.swift`:

| | `.session(bookingId:phase:)` | `.practice` |
| --- | --- | --- |
| Owes | one photo (`ProSessionPhotoRequirement`) | **nothing** |
| Uploads to | that booking's private session media | the practice library |
| Custody scope | the booking id | the literal `"practice"` |
| Requirement card / accented Done / exit sentence | as before | absent |

Everything that used to read `bookingId`/`phase` inside `ProCapturePhotosView`
now asks the destination, so the preview, coach, guide, auto-capture,
calibration, harvest tray and byte vault are **shared, not forked** — there is
no second camera to keep in sync, and the outstanding on-device tune reaches
both by construction. `Tovis/ProCameraUpload.swift` is the single upload
fan-out; the best-shots tray and the frame scrubber go through it too rather
than each knowing an endpoint.

🔴 **Practice has its OWN custody scope.** If it ever shared a booking's, a
stranded practice photo would be swept into that booking's owed-upload queue and
posted to a client who was never in it — and a white balance solved at home
would silently re-colour their before/after. Pinned by
`ProCameraDestinationTests`, red-proofed.

### The practice library + attach-later

Portfolio-shaped, none of the obligations. A shot can later become real media,
which is the moment a service is finally known:

- **To a client** → that booking's session media, private, phase `OTHER`.
- **As a look** → a public asset + a LookPost. "Post it now" defaults **off**
  and the footer says what off means; a draft is never a surprise post.

Attach **copies** the bytes rather than sharing them, so deleting a practice
shot can never pull the file out from under media promoted from it.

**"Also save to Photos"** (tools tray, off by default, remembered) keeps a copy
of each kept practice shot in the pro's own camera roll, through the existing
`PhotoLibrarySaver` — add-only authorization, raw-resource write, so the
original JPEG and its EXIF orientation survive rather than being re-encoded. It
saves the COLOUR-FINAL bytes, so the camera roll matches the library. Offered on
practice only: a client's before/after is their photo, and quietly copying it to
the pro's phone is not a toggle to slip into a tray. (The refused-photo escape
hatch is a different thing — there the alternative is losing the bytes.)

### Rode along

- **`tovis-app` #832** — the whole server half: `PracticeShot` (deliberately not
  a `MediaAsset` — every MediaAsset anchors to a bookable `primaryServiceId`, and
  a shot with no booking has no service), the four routes, the
  `pro_practice_disabled` kill switch, and migration
  `20260830120000_pro_practice_shots` (purely additive, starts empty).
  ⚠️ Renumbered off `20260830000000` mid-flight — a sibling session claimed that
  timestamp for `handle_global_namespace` after this one was numbered. **Check
  worktrees AND other sessions' working trees before numbering.**
  ⚠️ The repo's own privacy export-completeness guard caught `PracticeShot`
  missing from the export. The **delete** side has no such guard and was found by
  reading: `deleteUserData` *anonymizes* the ProfessionalProfile rather than
  deleting it, so `onDelete: Cascade` never fires and practice shots would have
  outlived a deletion request.

### Deliberate reductions (flagged, not half-built)

- **Practice records no clips.** A `PracticeShot` has no poster-frame columns, so
  a practice clip would land in the library as a tile with nothing to show. The
  record control is hidden while practising. Two nullable columns plus a poster
  copy on attach would fix it — that is a decision, not a detail.
- **Attaching to a client reaches ACTIVE work, not history.** The booking write
  boundary refuses media on a COMPLETED or cancelled booking (closeout
  integrity), so the picker only offers appointments that can still take one.
  Widening that means punching a hole in a deliberate lock — Tori's call.
- **The library is reached from the practice camera's tools tray.** A Profile-tab
  row would be more discoverable, but that file belonged to a live sibling
  session.

### Verified, and how

- The centre button was **looked at** in the simulator, signed in as a pro with
  no live session: a full-opacity camera glyph on the plume ring where the
  greyed-out session coin used to be.
- The **practice library was looked at too** — three shots, the attached one
  carrying its teal seal, placeholder tiles where no bytes sit behind the
  pointer. Reached via a new `TOVIS_DEBUG_OPEN_PRACTICE=1` launch key
  (`#if DEBUG`, mirroring `TOVIS_DEBUG_OPEN_SERIES`), because this machine still
  cannot drive the simulator with synthetic taps.
  🔴 **This is why it was worth looking.** The first attempt rendered
  `Internal server error`. It was NOT this code: the long-running dev server on
  :3000 had been booted before `PracticeShot` existed, so its in-memory Prisma
  client had no such model. A server started from a fresh checkout of merged
  `main` returned all three shots. Worth knowing — any sibling session's dev
  server will 500 on `/pro/practice` until it restarts.
- Every practice route was **driven end-to-end** against the local stack with a
  real pro bearer token: confirm (focal carried, no storage pointer on the
  wire), double-confirm refused, owner-scoped list, 401 unauthenticated, all four
  attach guards, delete. The Prisma layer was separately driven against real
  Postgres in an isolated shadow DB (10/10 — including the `(bucket, path)`
  unique index and the SetNull FK).
- Red-proofed by breaking the code and watching the right test fail: the
  storage-pointer leak guard, client-asserted pointers, the private-bucket
  refusal, byte-copying vs sharing, the another-pro 404, already-attached 409,
  the kill switch, the privacy delete wiring, the custody-scope split, and every
  centre-button state.

### Not verified — needs Tori's device

The simulator has no camera, and the simulator MCP needs a `sudo xcode-select`
this session could not run, so the screens below were compiled, unit-tested and
API-driven but never watched end to end:

- the practice camera actually **shooting** — every frame-path behaviour (coach
  lane, auto-capture, calibration) in standalone mode,
- a practice tile with a REAL signed thumbnail. The grid itself was watched, but
  every fixture had no bytes behind its pointer, so what rendered was the
  placeholder path. Writing real bytes needs the signing route, which correctly
  refuses a local database against remote storage — so this is a device or
  staging check, not something this machine can close.
- the attach sheet's two flows against real data,
- the button flipping back mid-shoot when a session starts.

Fold this into the same real-device pass as the outstanding on-device tune.

---

## Step: the pre-device-pass camera fixes (2026-08-04)

`docs/design/camera-excellence-plan.md` measured the whole camera against Tori's
bar and sorted every gap into `[BUILD]` (buildable now, no threshold guessing),
`[PASS]` (needs the salon device pass) and `[DECIDE]` (a product call). Tori
approved the `[BUILD]` set — **B1–B17**. #268 is all seventeen.

**Not in scope, deliberately:** no threshold the plan reserves for the device
pass was touched, and the platform-export (`D1`) and enhancement-policy (`D2`)
items were not built — they are open product decisions.

### The one structural idea

The plan's shortest summary: *"it measures the room where it should measure the
subject."* The person-segmentation mask was already being computed at 2.5 fps,
reduced to one clutter scalar, and thrown away. It now carries five judgements:

| judged on | before | now |
| --- | --- | --- |
| exposure | whole-frame `avgLuma` | **`faceLuma`** when there's a face, whole frame otherwise |
| backlit | face vs whole frame (which contains the face) | face vs **segmented background** |
| mixed light / warmth / green tint | whole frame | **segmented background** |
| before/after light match | whole frame | **segmented background**, both sides |
| composition (fill, headroom, centering) | full 3:4 sensor frame | **inside the 9:16 crop** the guide draws |
| post-capture QC exposure | whole image | **face region** when there's a face |

`FrameMath.backgroundAverageRGB` is the whole trick: `image × mask` and `mask`
are both area-averaged through the same transfer curve, so their ratio is the
background-only mean in the same domain the old numbers lived in. **The
thresholds keep meaning what they meant; only the pixels change.**

### What the bench says it bought — measured, not asserted

The offline bench (B17) now reports both scopings side by side over 35 images:

| | whole frame (before) | background (now) |
| --- | --- | --- |
| `mixed` median | 0.120 | **0.086** |
| images tripping `mixedLightSpread = 0.13` | **17/35** | **11/35** |

August 1's headline finding was that `mixedLightSpread` sat *on the median of
ordinary portraits* and therefore won the single coach line about half the time.
**The relocation moved the median below the threshold without touching the
threshold.** Details in `docs/camera-tuning-bench.md`.

### 🔴 The one thing to read before the device pass

**Moving the backlit test onto the background makes it MORE sensitive at the
current `backlitFaceRatio = 0.6`, not less.** The background is brighter than a
frame average the darker subject was dragging down, so `background × 0.6` is a
higher bar than `frame × 0.6`.

The relocation is still correct — face-vs-background is what "the light is
behind them" *means* — but it is a **structural** fix and **not** a fix for the
deep-complexion false positive the plan describes. No ratio of skin
*reflectance* to background *illumination* can separate "less light on their
face" from "less light coming back off their face". Only §3.1's per-complexion
measurement can. `backlitFaceMaxLuma = 0.4` is what caps the damage until then.

`CoachReadinessTests.relocatingTheBacklitTestMakesItMoreSensitiveNotLess` pins
this in a test so it cannot surprise anyone.

### A second finding the work surfaced

An outright lighting failure, **alone**, does not drop a frame out of the green
ring — and does not even fall short of the harvest gate. Lighting is the
heaviest coach and still only 1.6 of 7.5 total weight, so scoring it 0.3 lands
at **0.851**: over `readyThreshold` (0.80) *and* over `harvestThreshold` (0.85).

So the coach now correctly says *"their face is too dark"* while auto-capture
fires anyway and the Session Reel keeps the frame. Fixing that means moving
`readyThreshold`, the lighting weight, or the failure score — all three reserved
for the device pass. Pinned as
`CoachReadinessTests.aLightingFailureAloneStillClearsBothTheRingAndTheHarvestGate`
rather than quietly changed.

### The coach stops nagging

Three separate mechanisms, all arithmetic:

- **`CoachTipArbiter`** — the one line was re-ranked by a plain `max` six times a
  second, so two near-tied coaches alternated. A tip now holds the line for
  `tipDwellSeconds` (2.5 s) and a challenger must beat the incumbent's *current*
  deficit by `tipSwitchMargin` (0.15). The incumbent yields **immediately** when
  its own coach stops complaining — a fixed problem never keeps the line.
- **Haptics fire for news only** — a different dimension taking the line, at most
  once per `nudgeHapticMinInterval` (2 s). It used to buzz on every alternation.
- **Speech stops cancelling itself** — coach tips no longer interrupt an
  in-flight utterance (they're dropped; the line is on screen anyway), and
  deliberate directives queue behind rather than cutting off. The pro used to
  hear the first three words of everything and the whole of nothing.

Plus the coach can now be heard being *satisfied*: when the dimension holding the
line clears, it says "Focus — got it".

These three numbers are new to `CoachTuning`, in their own section marked
**behavioural, not perception** — they're set by how long a person takes to read
a line, so the salon pass doesn't invalidate them. A stopwatch would.

### Everything else in B1–B17

- **B6 — auto-capture stalled silently after a QC-rejected burst.** Re-armed only
  when readiness left the green ring, so a client holding perfectly still meant
  auto-capture was dead while the lane promised "holding for another try". The
  arming rule is now `GuidedCaptureArm`, a five-line state machine with its own
  test suite, because the bug was invisible in the UI and self-healing on the
  success path — which is why it survived.
- **B7 — framing parity.** The after's fill band is now the booking's **own
  before shot's measured fill** (`BeforeShotMeasure`), not the generic portrait
  band. Shooting the before tight and the after loose is the most-cited
  before/after mistake. Nothing is guessed: the target IS the before's number.
  "Match a look" now shares that derivation instead of keeping its own copy.
- **B10 — the Reels cover safe band** is drawn inside the 9:16 box (top 220 px,
  bottom 450 px of 1080×1920). Drawn by insetting the **already-mapped** box,
  not by mapping a frame-space rect: `previewRect` is only exact for rects
  centred in both axes, and this band is deliberately off-centre.
- **B11 — every tip now carries a `why`**, shown under it in the dimensions
  drawer. That drawer is the one surface the pro opens on purpose to ask "why
  won't it go green?", so it is where the coach explains itself.
- **B12 — video.** Stabilization was never set, so it defaulted to OFF and every
  handheld salon clip shipped shaky; it's `.auto` now. Clips are capped at 60 s.
  ⚠️ **Resolution, frame rate and codec are deliberately NOT changed** — the plan
  marks measuring them `[PASS]` (§3.6), and switching the codec blind risks web
  playback (HEVC in a `.mov` does not play in Chrome).
- **B13 — colour space pinned to sRGB.** Captures were tagged Display P3 by
  default while `CardCorrection` re-encoded to sRGB, so *whether a card had been
  scanned changed the colour space of the shipped JPEG* — within one shoot, if
  the pro scanned mid-session.
- **B14 — the virtual multi-camera device** (`builtInTripleCamera` →
  `builtInDualWideCamera` → `builtInDualCamera` → wide), unlocking macro
  auto-switch and zoom. ⚠️ On a triple camera **zoom factor 1.0 is the
  ultra-wide**, so the session is parked on the wide constituent to keep today's
  framing byte-for-byte. That arithmetic is pure and tested; that it *works on
  real glass* is a device check.
- **B15 — `PoseCoach`'s silent 0.9 cap is gone.** It fired whenever a body was
  detected — always, in a portrait session — with no message: a permanent 0.06
  readiness tax the pro could never clear and was never told about.
- **B16 — cape copy.** "Cape off" on the hair and face front shots. A cape in one
  frame and not the other makes a real transformation look staged.
- **The nails macro step is honest now.** It asked for "Macro on one nail", a
  shot a wide-angle-only session physically could not focus, and the coach would
  then nag "hold steady — shot looks soft" forever at something impossible. It
  asks for "as close as it'll focus" until §3.4 confirms the virtual camera's
  close-focus range on real hardware.

### One camera, no duplicate logic

`FrameMath` gained `segmentSignals` and `colorSignal`; the analyzer, the offline
bench, `ReferenceLookAnalyzer` and `BeforeShotMeasure` all call them. The bench
used to keep **its own copies** of the segmentation and colour math, which could
silently disagree with the camera — that's gone. `PublishCrop` is the single
source of the crop geometry that the overlay draws and the coach judges inside,
so the lines can't promise one thing while the ring approves another. Session and
practice modes share all of it by construction, as before.

### Verified, and how

- **195 unit tests green** (`xcodebuild test`, iPhone 17 Pro simulator), up from
  the previous suite by four new files: `CoachTipArbiterTests`,
  `GuidedCaptureArmTests`, `PublishCropTests`, `CameraCompositionTests`.
- **Red-proofed — eleven probes, each one reverting a fix in the production
  source and confirming the intended test goes red.** A test that stays green
  with the fix removed is not coverage, it is decoration. The ledger:

  | Probe | Reverting it turns these red |
  | --- | --- |
  | **B1** exposure judged on the face | `anUnderexposedFaceIsNamedEvenWhenTheRoomAverageLooksFine` (3 expectations), `withoutAMaskTheCoachDeclinesToCallBacklight`, `aLightingFailureAloneStillClearsBothTheRingAndTheHarvestGate` (2) |
  | **B2** backlit vs the segmented background | `relocatingTheBacklitTestMakesItMoreSensitiveNotLess` |
  | **B4a** tip dwell | `theDwellHoldsTheLineEvenAgainstAClearlyWorseProblem` |
  | **B4b** tip switching margin | `aChallengerMustBeatTheIncumbentByTheMarginNotMerelyBeatIt` |
  | **B6** auto-capture re-arm | `aRejectedBurstRearmsWithoutTheShotLeavingTheGreenRing` |
  | **B7** framing parity from the before shot | `theAfterInheritsTheBeforesMeasuredFraming`, `matchingFramingPreservesEverythingElseAboutTheStep` |
  | **B8** light match on the background | `aColourTransformationNoLongerReadsAsALightChange`, `theRoomGettingBrighterIsStillCaught`, `theRoomGoingWarmIsCaughtAndNamedSeparately` |
  | **B9** composition inside the feed crop | `aFrameThatFillsTheSensorButNotTheFeedCropIsCaught`, `aSubjectOutsideTheFeedCropIsNamedAsSuch`, `centeringIsMeasuredInTheCropsOwnSpace` |
  | **B10** cover-band asymmetry | `theCoverSafeBandReservesMoreRoomBelowThanAbove` |
  | **B14** parked on the wide constituent | `aTripleCameraIsParkedOnItsWideConstituent` |
  | **B15** the silent PoseCoach cap | `aFlawlessPortraitNowActuallyScoresOne`, `detectingABodyNoLongerCostsReadiness` |

  ⚠️ **B1's first run was not a red proof and was not counted as one.** The
  simulator refused the launch (`FBSOpenApplicationErrorDomain Code=6`,
  "Application failed preflight checks", reason `Busy`) — a red that came from
  the harness, not from the reverted code, which proves nothing about coverage.
  It was re-run cleanly on **2026-08-05** on a dedicated freshly-booted iPhone 17
  Pro (iOS 27.0), green baseline first, and the failures above are the second
  run's. A red proof only counts when the *test* fails, not the run.
- **The offline bench was run** over 35 real photographs and produced the
  before/after colour table above. It compiles the live sources every run, so it
  cannot drift from the camera.
- Two existing tests were **deliberately inverted** rather than deleted, because
  they pinned behaviour this branch changed on purpose:
  `aFlawlessPortraitClearsEveryGateButNeverScoresOne` →
  `aFlawlessPortraitNowActuallyScoresOne`, and
  `detectingABodyPermanentlyCostsReadiness` →
  `detectingABodyNoLongerCostsReadiness`.

### Not verified — needs Tori's device

**The simulator has no camera**, so nothing below could be watched. Every item
is compiled, unit-tested where it is pure, and reasoned to from the API
contracts — none of it has seen a photon.

| What | Why it needs the phone | Plan § |
| --- | --- | --- |
| 🔴 **`backlitFaceRatio` across complexions** | The relocation is more sensitive at 0.6. This is the single most important number in the pass. | §3.1 |
| 🔴 **The target face-luma band, per complexion**, and whether `faceExposureBias = −0.3 EV` holds | `faceLuma` is now what the coach judges; the bench has zero complexion coverage. | §3.1 |
| **`mixedLightSpread` / `warmCastWarmth` / `greenCastTint` re-measured** | Now on the de-confounded background signal — measure the right column. | §3.2 |
| **B14: does the virtual device actually give macro?** Does the nails detail shot focus? Is the default framing unchanged? | Lens behaviour is glass, not arithmetic. If framing shifted, `matchWideAngleFraming` is the one place to look. | §3.4 |
| **B13: are the shipped JPEGs actually sRGB** with and without a card scan? | `activeColorSpace` support varies by active format. | §3.7 |
| **B12: what a clip now IS** — resolution, fps, size, and whether stabilization visibly helps | Also settles the codec question the plan left open. | §3.6 |
| **B6 on hardware**: force a QC rejection, hold perfectly still, does it fire again? | The unit test proves the arm re-arms; only the phone proves the whole loop closes. | §3.5 |
| **Do the dwell + margin FEEL right?** 2.5 s / 0.15 are reasoned, not measured. | No bench can answer "does this nag". | §3.5 |
| **Does the confirmation beat land or annoy?** | Same. | — |
| **B9: the crop-aware coach against a real preview** — does judging inside 9:16 make it nag to get closer constantly? | The bench corpus is framed loose, so it can't distinguish the fix from the corpus. | §3.2 |
| **B7: does the after's inherited fill band hold** with a client who moves? | — | §3.1 |
| Everything already owed from the previous step (practice camera shooting, real thumbnails, attach flows, onion-skin alignment, tilt sign, face-exposure mapping) | Unchanged. | §3.9 |

---

## Step: save to phone + the social export pack (2026-08-05)

> The approved member perk from the membership review, decision 9 — and the
> answer to the plan's biggest open question, **D1**.

The camera has always been a very good photographer that **stopped at upload**:
excellent source material, handed over as a 3:4 JPEG. This is the other half of
"a real photographer *and social media expert*". Two ways out of the app with the
pro's own work, and they are deliberately different things:

| | What it produces | Watermark |
| --- | --- | --- |
| **Save to Photos** | the ORIGINAL file, byte for byte — EXIF, orientation, colour profile intact | **never**, on any tier, in any membership state |
| **Make a post** | a platform-ready render: 4:5 or 9:16, single shot or before/after diptych | **always** — the pro's own handle, corner-placed, photographer's-signature small |

**The signature is never a paid feature.** The work is theirs on every tier. What
the membership changes is the small platform mark that sits beside it.

### Where the affordances are

| Surface | Save | Export | Diptych |
| --- | --- | --- | --- |
| Session shots (`ProSessionHubView` → fullscreen) | ✅ | ✅ | ✅ — reuses `comparisonPairs`, the same pairing the wrap-up publishes |
| Media manager (`ProMediaEditSheet` → fullscreen) | ✅ | ✅ | ❌ — see follow-ups |
| Practice library (`ProPracticeShotDetail`) | ✅ | ✅ | n/a (a practice shot has no pair) |
| The in-camera captured strip | ❌ | ❌ | — |

The bar itself is **one component** (`ProMediaExportBar`), so "Save to Photos"
means the same thing and reads the same words everywhere. It hangs off
`FullscreenMedia.export`, which is `nil` by default — the shared viewer is used by
client surfaces too (chart photos, message attachments), and this is PRO-only.

**The in-camera strip is deliberately excluded.** `CapturedShot` holds a 216 px
thumbnail, not the capture — holding full-sensor decodes is what jetsam-killed
real sessions. A "save the original" built on a thumbnail would be a lie, and an
export from one would be visibly soft. The camera already saves the colour-final
ORIGINAL bytes where it honestly can: the practice auto-save toggle, and the
refused-photo escape hatch. Everything shot in-session reaches the session-shots
surface a moment later, where the real bytes are.

### 🔴 Why a save can't accidentally become an export

Three locks, in order of how hard they are to defeat:

1. **The type.** `SocialExportRenderer.render` takes a NON-optional
   `ExportWatermark`, and `SocialExportPolicy.watermark` returns `nil` for
   `.saveOriginal`. A save physically cannot be routed through the renderer.
2. **The intent, not the destination.** Both paths can end at the camera roll, so
   `MediaWriteIntent` — not "where is this going" — is what decides. An export
   saved to Photos IS signed; a save to the same place is not.
3. **The bytes.** `OriginalMediaBytes.fetch` exists to be the one named place that
   says "do not re-encode this". Anything that decodes and re-encodes silently
   strips the capture date, the orientation tag the web gallery reads, the lens and
   the colour profile — and the photo still looks fine, so nobody would notice for
   months.

### Geometry, and why it is where it is

`PublishCrop` **moved out of the app target into TovisKit**. It was already the
single source of the crop the overlay draws and the coach judges inside; it is now
also what the exporter cuts to, so the frame the coach approved while shooting is
the frame that gets posted. It moved because CI compiles and tests TovisKit and
**nothing compiles `Tovis/`** — this is arithmetic that decides whether the client
is in the picture the pro posts.

For the same reason the whole export engine lives in TovisKit and uses
CoreGraphics + CoreText + ImageIO with **no UIKit**, so it compiles and runs on the
macOS CI runner: `SocialExportPlan` (crop + layout), `SocialExportPolicy`
(the signature and the tier), `SocialExportRenderer` (the actual pixels).

Two decisions worth knowing:

- **The diptych arrangement is geometry, not taste.** Side-by-side inside a 9:16
  box leaves each half at ~0.28 w/h — a letterbox slot no face survives. So the
  tall canvas **stacks** (before on top) and 4:5 sits **side by side** (before on
  the left). Before is always first.
- **The subject anchor is 0.44 vertically, not 0.5.** Beauty work is judged on the
  head and the hair; the subject sits a little high and the room goes underneath.
  That is the live coach's headroom rule surviving the crop. The hint is the focal
  point the camera **already** found at capture (C6) — no new detection pass. Only
  practice shots surface a focal on read; everything else centres.

### ⚠️ One thing for Tori's eye

**The 9:16 signature sits at the cover-safe band, not the true corner** — about
three-quarters of the way down. A vertical post is covered by the platform's
caption, audio row and action rail across roughly its bottom 450 of 1920, so a
corner signature is a signature nobody sees. That is the reasoning, but the
position is a taste call. One line to change:
`SocialExportPlanner.signatureBox`, plus its test.

### The membership gate — and what actually renders today

`social_export_unbranded` (tovis-app #847, MERGED, **not deployed**) sits on
PRO/PREMIUM/STUDIO. The server resolves it to one boolean, `exportsUnbranded` on
`/api/v1/pro/membership/status` — same shape as the finance payload's
`canExportTaxDocs`. The render is on-device; the decision is not.

> 🔴 **With `ENABLE_MEMBERSHIP_ENFORCEMENT` off — production today — a free pro and
> a paying pro export the SAME unbranded image.** Every paid gate in tovis-app
> resolves as granted while that switch is off; this follows them rather than
> inventing a new rule. The perk is real in code and invisible in production until
> the flag flips. There is a live argument for gating this one on the entitlement
> ALONE (nothing is being taken away — the feature is new; and the mark is
> marketing, not a restriction). One line in `lib/pro/socialExportMark.ts` plus its
> test. **Tori's call** — recorded in `docs/design/camera-excellence-plan.md` §5.1.

A missing answer fails **generous** (unbranded): an older backend, an offline
launch or a 500 all resolve to the member treatment. A free pro's absent mark
costs a little reach; a paying pro whose export sprouts a mark because their signal
dropped is a broken promise they can point at.

### Verified, and how

- **51 new TovisKit tests**, all in CI. Crop invariants across 5 source shapes × 4
  subject positions × 5 nudges × both formats; the layout; the signature box; the
  watermark policy in both directions on every tier and both flag states; and the
  renderer on **real pixels** (a black|white split source proves the crop keeps its
  seam centred, a black/white pair proves before comes first, and the signature
  corner is diffed against an unsigned render to prove the mark is drawn there and
  **nowhere else**).
- **Nine mutants killed.** Watermark never drawn · perk ignored (mark always drawn)
  · a save watermarked · headroom bias removed · before/after swapped · 9:16
  signature under the action rail · destination not flipped · manual nudge ignored ·
  the save path re-encoding (EXIF stripped). Every one turns the suite red.
- **Looked at, in both modes**, on the simulator — which needs no camera to render
  and export. Free renders `@toristyles TOVIS`; member renders `@toristyles` and
  nothing else, with the picture itself byte-identical between them.
  `SIMCTL_CHILD_TOVIS_DEBUG_OPEN_EXPORT=1` +
  `TOVIS_DEBUG_EXPORT_TIER=free|member` opens the sheet on a synthetic before/after
  from the ROOT view — no session, no token, no local backend, so it stays reachable
  on a day when the debug token seed or the dev stack is unwell (which is exactly
  when someone reaches for it). The sample supplies only source pixels; the crop,
  layout and signature all come from the real renderer.

### Not verified — needs Tori's device

- **The share sheet handing a real file to Instagram / TikTok / Messages.** The
  simulator has no social apps installed, so the hand-off past `UIActivityView-
  Controller` is unexercised.
- **`PHPhotoLibrary` writing the original bytes into a real library**, and what
  Photos then reports for capture date / orientation. The byte-identity is proven in
  CI; the library write is not.
- **How the signature reads over real hair.** Every sample here is synthetic. The
  legibility pass (a light signature with a soft dark shadow, so it survives both a
  blonde balayage and dark hair) is reasoned and looked at, not judged on a real
  photograph.
- **Whether the 9:16 signature position is right** once she sees one posted.

### Follow-up cards (designed, deliberately not built)

1. **Client-side share treatment.** A client sharing their own before/after with
   their pro's handle on it — designed exactly the same way: the client's save is
   always their clean original, the export carries the PRO's handle (it is the
   pro's work), and the same entitlement decides the platform mark. Scope-guarded
   out of this session on purpose; it needs a client-side entitlement read and a
   consent question this session did not answer.
2. **Video / clip export.** Stills first. The clip machinery re-exports a whole take
   through a per-frame filter (`CardCorrection.swift:156-183`); adding a watermark
   pass and two crops on top of that is its own piece of work with its own length
   cap and its own thermal budget.
3. **1:1 (1080×1080).** The IG profile grid and most ad units. A real gap, left as a
   gap rather than guessed at.
4. **Carousel assembly.** Option (c) of D1. The guides already produce the shot list
   a carousel wants (before, process, detail, full after); the assembly doesn't
   exist.
5. **A full-resolution `beforeUrl` on `ProMediaBeforeOption`** (tovis-app). It
   carries only `thumbUrl` today, which is right for the pairing picker and the
   preview slider but would export a visibly soft half — so the media manager
   offers no diptych. One additive DTO field unlocks it.
6. **Save/export from the in-camera strip**, if the camera ever holds full bytes for
   a reviewed shot.

---

## Device feedback log

### 2026-08-05 — build 38 crashes AGAIN, same site; the app stops betting on validation

> 🔴 **Tori must archive BUILD 39.** Build 38 is dead on every multi-lens phone
> the same way 37 was — it opens, runs ~2s, and aborts. Do not ship or demo 38.
> No deploy implications: this is app-side only, nothing server changed.

**Round 2 was not enough, and this is why.** #275 (build 38) diagnosed a NaN
walking through a hand-rolled `min(max(…))` clamp, replaced every clamp in the
app with the NaN-safe `DeviceParameterGuard`, and red-proofed it. That diagnosis
was correct and that fix is still in. It just was not the whole bug — it fixed
*the value* and the crash was never really about the value. Build 38 aborts at
the same call, having gone through the new guard.

The honest version: rounds 1 and 2 both answered "what did we write that was
invalid?" Round 3's evidence says the better question was "what makes a write
that passed every check we can make still illegal by the time it lands?"

**The evidence.** `EXC_CRASH (SIGABRT)`, uncaught ObjC exception on
`tovis.camera.session`, `lastExceptionBacktrace` = `objc_exception_throw` ←
`-[AVCaptureFigVideoDevice _setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:completionHandler:]`,
incident `606EB0B6-…`, iPhone16,2 / iOS 27.0 beta 24A5390f, ~2.2s after launch.
Symbolicated against build 38's own dSYM (slice
`0AF7954C-A604-3E4F-BBE1-11DC78E8E9AF`,
`Archives/2026-08-05/Tovis 8-5-26, 12.35 PM.xcarchive`):

| Image offset | Symbol |
| --- | --- |
| 913640 | `closure #1 in CameraController.applyWhiteBalanceGains(r:g:b:)` — `CameraController.swift` |
| 1570956 | caller frame, `CoachEngine.swift` |

So **#275's guard was in the binary and the crashing call site routed through
it.** Confirmed before anything else was assumed.

**What actually threw.** Apple raises `NSGenericException` from that setter for
three separate preconditions: gains outside `1…maxWhiteBalanceGain`, the device
not being locked for configuration, and `.locked` white balance being
unsupported. The crash log carries a backtrace but **no exception `reason`
string**, so which of the three fired cannot be read off it directly — that is
stated plainly rather than guessed, and the new logging (below) captures the
reason if it ever happens again.

It does not matter much, because **all three collapse into one root cause**:

> Every precondition was checked against the device at one instant and the write
> happened at a later one.

The specifics line up exactly:

- The device is **virtual** (`preferredCaptureDevice` prefers
  `.builtInTripleCamera` / `.builtInDualWideCamera` since #268). A virtual device
  switches its **active constituent lens asynchronously**, including during the
  settle after `startRunning`.
- `maxWhiteBalanceGain` and `isWhiteBalanceModeSupported(.locked)` are both
  **per-active-format** — the wide lens's limits are not the ultra-wide's.
- `applyWhiteBalanceGains` runs **immediately after `await camera.start(…)`**
  (`ProCapturePhotosView.swift`, the "one card, one session" re-apply) — i.e.
  squarely inside that settle window. That is the ~2.2s.
- The crash log's **main thread was inside
  `-[AVCaptureVideoPreviewLayer _initWithSession:makeConnection:]`** —
  `CameraPreview.makeUIView` assigning `videoPreviewLayer.session`, which adds a
  connection to the already-running session and **forces it to re-negotiate the
  active format**, concurrently.
- `lockForConfiguration()` does **not** close this window. It excludes other
  *clients* from configuring the device; it does not stop the session's own
  renegotiation or the virtual device's constituent switching. #275's
  `defer`-unlock audit was correct and is not implicated.

**The fix, in two layers — because one layer has now failed twice.**

*(a) The root cause.* The white-balance write now happens inside a session
configuration transaction (`withSettledFormat`), so the session cannot
re-negotiate its format — and the virtual device cannot swap constituents —
while the limits are read and the write lands. Inside that, **every precondition
is re-read within the device lock** immediately before the write, by
`GuardedWhiteBalance` (TovisKit). The transaction contains no session-level
changes, so the commit is a no-op; its entire job is mutual exclusion against
the main thread's preview attach.

*(b) The guarantee.* **Swift can now catch AVFoundation's exceptions.** A new
`TovisObjC` target — the one place in the codebase allowed to contain `@try` —
exposes `TovisObjCException.catching(_:)`, wrapped for app use as
`CaptureExceptionShield.perform(_:_:)`. **Every** `AVCaptureDevice` /
`AVCaptureSession` call in `CameraController.swift` that can raise now goes
through it. A raise is no longer a process kill; it is a returned outcome. For
white balance specifically the degradation is explicit: log it, skip the lock,
fall back to `.continuousAutoWhiteBalance`, keep the session running, and show
**AUTO** rather than falsely claiming CALIBRATED. The coach worked without
locked WB for months. A less colour-calibrated shoot beats a dead camera.

⚠️ **The one rule for shielded blocks**, and it is load-bearing: a block holds
exactly one AVFoundation call and **never a `defer`**. An ObjC exception
unwinding through a Swift frame runs no Swift cleanup, so a
`defer { unlockForConfiguration() }` inside a shielded block would silently not
run and wedge the device for the rest of the shoot. Every unlock is spelled out
*after* the shielded call, on both paths. Documented in
`TovisObjCException.h` and `CaptureDeviceShielding.swift`.

**Red-proofed, both layers, and the red is real.**
`CaptureExceptionShieldTests` + `GuardedWhiteBalanceTests` (13 tests) raise
genuine `NSException`s through the genuine shim. `GuardedWhiteBalanceTests`
stages the crash itself: gains valid for the lens that was active, the device
switching to a lens with a lower max *while the lock is held*, and the write
rejected — then asserts the camera came back on auto WB with the device
unlocked and the lock/unlock counts balanced. **Mutation-checked:** with the
`@catch` removed from the shim, the suite does not fail, it dies —
`exited with unexpected signal code 6`, `libc++abi: terminating due to uncaught
exception of type NSException`. That is build 38's failure mode reproduced
inside the test harness, which is the correct red for this bug.

**Audit — the writes shielded (all in `CameraController.swift`).**
`setWhiteBalanceModeLocked` ×2 · `whiteBalanceMode` · `setExposureTargetBias` ×3
· `focusPointOfInterest` / `exposurePointOfInterest` · `focusMode` /
`exposureMode` · `isSubjectAreaChangeMonitoringEnabled` · `videoZoomFactor` ·
`activeColorSpace` · `photoOutput.maxPhotoDimensions` ·
`settings.maxPhotoDimensions` · `maxPhotoQualityPrioritization` · `capturePhoto`
· `sessionPreset` · `addInput` / `addOutput` ×3 · `beginConfiguration` /
`commitConfiguration` · `startRunning` ×3 / `stopRunning` ·
`movieOutput.startRecording` / `stopRecording` / `maxRecordedDuration` ·
`conn.videoRotationAngle` / `preferredVideoStabilizationMode`. Where a raise
means a delegate callback will never arrive (`capturePhoto`, `startRecording`,
`stopRecording`), the awaiting continuation is failed immediately rather than
left to the 10s watchdog with the shutter gated shut.

⚠️ **CI still does not compile the app target** (`swift test` on TovisKit only).
Verified locally: **BUILD SUCCEEDED** against the iOS Simulator SDK, **1218
TovisKit tests pass**. Both new TovisKit files and the ObjC target DO run in CI.

**Not verified — needs Tori's device.** That build 39 opens the camera and stays
open on a multi-lens phone, and whether the WB lock now succeeds or degrades to
AUTO. If it degrades, the new `⚠️ camera:` log line carries AVFoundation's own
reason string — which is precisely what this crash log lacked — and that names
the remaining precondition without another round of inference.

#### The camera stack now has ONE isolation story

Tori's Xcode showed ~50 Swift-6 concurrency warnings, half of them in
`CameraController`. Most were noise, but two were a real unsynchronized
read/write, and they are exactly the shape of defect that lets a validated
device parameter go stale before it is applied:

- **`device` was written on `sessionQueue`** (by `configureSession`) **and read
  on the main actor** — every public method opened with `guard let device else
  { return }` before dispatching, then captured that non-Sendable
  `AVCaptureDevice` into the `@Sendable` queue closure. Seven call sites.
- **`configured` had the same split**, written on the queue and read by
  `start()`.

Neither *caused* the abort — the crash is AVFoundation's own renegotiation, not
a Swift data race — but a file that died to "validated at one instant, written
at another" does not get to be casual about which thread is looking at the
device. The model is now stated at the top of the class and enforced:

| Home | What lives there |
| --- | --- |
| **Main actor** | `status`, `aeAfLocked`, `whiteBalanceCalibrated`, `isRecording`, the callbacks, and `previewLayer` (main-thread UIKit state that was wrongly marked `nonisolated`) |
| **`sessionQueue`** | every AVFoundation object, `device`, `configured`, the continuations, the metering scalars — `@ObservationIgnored nonisolated(unsafe)`, and never touched from the main actor |

Every `device` read now happens **inside** the queue closure. Main-actor →
queue crossings go through one explicit `onSessionQueue` helper, so a crossing
has to be written down rather than happening because a property looked like
"just a Bool". `frameDelegate` is handed to `configureSession` as an argument
and stored on the queue instead of parked on the main actor and read from it.

Two side benefits worth naming: the session-queue internals were being tracked
by `@Observable`, so **every session-queue write was invalidating SwiftUI views
for state no view reads** — `@ObservationIgnored` stops that. And
`@preconcurrency import AVFoundation` was deliberately NOT used: it silences the
whole module's Sendable diagnostics in one line, including the ones worth
reading. The one genuine unverifiable transfer (handing the coach's frame
delegate to the queue) goes through a `UncheckedSendableBox` that names the
invariant instead of hiding it.

**Camera stack: 26 warnings → 0.** Whole app: 48 → 22. Clean build, BUILD
SUCCEEDED, 1218 TovisKit tests still pass.

⚠️ **This refactor is verified by compilation and reading, not by running the
camera.** The simulator has no capture device — `preferredCaptureDevice()`
returns nil there, so `configureSession` bails with "No camera available" and
none of the device paths execute. It changes threading in `start()` /
`configureSession`, so it wants a real look on build 39: camera opens, preview
draws, tap-to-focus works, AE/AF lock works, a clip records.

The remaining 22 warnings are one coherent group — image helpers
(`FrameMath`, `PhotoQC`, `CardCorrection`, `BeforeShotMeasure`, `ReferenceLook`,
`CameraLibraryImport`, `ProMediaExport`, `BestShotsReviewView`,
`ProCapturePhotosView`) whose `static` methods are main-actor-isolated but called
from background contexts, plus two genuinely cosmetic ones (`LooksGrid`
nil-coalescing, `ProCalendarTimeGrid` unused var). **None of them touch
`AVCaptureDevice` or the session queue**, which is where the scope line was
drawn. Filed as a follow-up.

**Follow-up closed in #279 — whole app is now at 0 warnings.** Same line held:
no `@preconcurrency import`, `nonisolated` at the type level where the type is
genuinely pure (`FrameMath`, `VisionDetect`, the pose vocabulary, the shot-guide
value types), per-declaration where it isn't. `FrameMath.context` lost its
`nonisolated(unsafe)` — CIContext is Sendable, so the qualifier was claiming an
audit the type doesn't need.

⚠️ One of the two "genuinely cosmetic" ones was not cosmetic. `LooksGrid`'s
`(look.thumbUrl ?? look.url).flatMap(URL.init(string:))` resolves the `??` at
`String??`, so the left side can never be nil and `look.url` is dead — a look
whose row carries no `thumbUrl` was rendering the placeholder sheen instead of
its own image. Worth remembering the next time a nil-coalescing warning gets
waved through as tidy-up: the compiler was reporting a bug, not a style note.

> 🛠 **Check warnings with the beta toolchain, or the count is fiction.**
> #279's "0 warnings" was measured on the wrong compiler. Two Xcodes are
> installed: `xcode-select -p` → `/Applications/Xcode.app` (26.6, Swift 6.3.3),
> which is what a bare `xcodebuild` picks up, while Tori works in
> `/Applications/Xcode-beta.app` (27.0, Swift 6.4). Diagnostic groups that only
> exist in 6.4 — confirmed case `#ImplicitStrongCapture` — are invisible to
> 6.3.3. On the same commit: IDE 2 warnings, from-clean 6.3.3 build 0.
>
> This is **not** a stale-derived-data problem, so cleaning does not fix it. It
> reproduces on a clean build with a fresh `-derivedDataPath`. Use:
>
> ```bash
> DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
>   xcodebuild build -project tovis-ios.xcodeproj -scheme Tovis \
>   -configuration Debug -destination 'generic/platform=iOS Simulator' \
>   -derivedDataPath /tmp/dd-beta
> ```
>
> `Debug` because that is what the Tovis scheme's Run and Test actions use — a
> bare `xcodebuild` with no `-configuration` defaults to Release. Ignore the
> three `ld: warning: address=… points before section(N) start` lines: linker
> noise from prebuilt binary dependencies, not source issues, and not shown in
> the IDE. Re-confirm the beta path when it is eventually replaced by a release.

**The last two closed in #280.** `ContentView`'s `startRealtime` was the third
instance of the shape #279 fixed in `startPush` — an `@escaping @Sendable`
callback that realtime stores for the life of the subscription, capturing self
implicitly and strongly, with a decorative `[weak self]` on the inner `Task`.
#279 assessed it as "already correct" without reading it. `CameraController`'s
watchdog was a *different* case wearing the same message: both its strong outer
capture (it owns the continuation) and its weak inner one (it fires long after
the outer block returns) were already correct, and the fix was to spell the
outer capture `[self]` so the contrast is explicit rather than accidental. Not
every instance of this diagnostic wants the weak moved outward.

### 2026-08-05 — build 37 STILL crashes; the crash log names white balance

> 🔴 **Tori must archive BUILD 38.** Build 37's camera is dead on every
> multi-lens phone — it opens, runs ~5s, and aborts. #273 is in build 37 and
> #273 was not enough. Do not ship or demo 37.

Build 37 carried #273 and crashed anyway on iPhone16,2 / iOS 27.0 beta
(24A5390f), ~5s after the camera opened. **This time there is a crash log**, and
unlike the build 36 entry below, nothing here is reasoned from the surface:

`EXC_CRASH (SIGABRT)`, uncaught ObjC exception on `tovis.camera.session`,
`lastExceptionBacktrace` running `objc_exception_throw` ←
`-[AVCaptureFigVideoDevice _setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:completionHandler:]`.
Symbolicated against build 37's own dSYM (slice
`10C2A400-534C-3944-95C1-EACB69AAE217`, `Archives/2026-08-05/Tovis 8-5-26, 8.47 AM.xcarchive`),
the app frame at image offset 911544 is **`CameraController.swift:352`** — the
return address after `setWhiteBalanceModeLocked` inside
**`applyWhiteBalanceGains(r:g:b:)`**. A fourth device-parameter write of exactly
the class #273 was opened for.

**The call site was already clamping. The clamp was the bug.**

```swift
func clamp(_ x: Double) -> Float { min(max(Float(x), 1), maxGain) }
```

Swift's `min`/`max` are `Comparable`, not IEEE — `1 >= NaN` and `maxGain < NaN`
are both false — so **a NaN falls straight back out unchanged**. Measured:
`+∞ → maxGain`, `−∞ → 1`, `99 → maxGain`, `NaN → NaN`. Every bad value was
caught except the one that matters, which is why the line survived three reads.

**Why it fired on open, every time, and never in the simulator.** The gains
`applyWhiteBalanceGains` writes are not computed at open — they are read raw out
of `UserDefaults` (`ProCapturePhotosView`, the per-booking "one card, one
session" re-apply) right after `await camera.start(...)`. That is the ~5s.
`CameraCalibration.neutralizingGains` had the *identical* hole in its own clamp
and reaches NaN by ordinary means — a device that reports `deviceWhiteBalanceGains`
of 0 before it has settled, times a near-black sample's ∞ channel ratio, is
0 × ∞. So one bad card scan wrote a NaN to `UserDefaults` once, and from then on
**the poison was persisted state, not a code path she re-entered** — it aborted
every subsequent open, on that phone, forever.

**The fix (#TBD).** One shared, NaN-safe clamp —
`TovisKit/CameraCalibration/DeviceParameterGuard.swift` — that answers `nil`
("make no write at all") rather than forwarding a value, and treats bounds read
off the device as untrusted too. **Every** `AVCaptureDevice` /
`AVCaptureSession` parameter write in the app now goes through it; there is no
second clamp anywhere. Poisoned stored gains are additionally *dropped* on
detection (`onWhiteBalanceUnusable` → the view removes the defaults key), so a
phone already carrying a NaN — Tori's is — recovers on the next launch instead
of shooting on automatic white balance forever.

Red-proofed in `CameraCalibrationTests` + `DeviceParameterGuardTests`. Three of
the new tests compile unchanged against build 37's math and **fail there with a
literal `nan`**; `build37sHandRolledClampLetNaNStraightThrough` pins the exact
`min(max(…))` expression so the hole cannot be reintroduced by hand.

**Audit — every device/session parameter write, and its disposition.** All are
in `CameraController.swift`; nothing outside that file touches a capture device.

| Write | Before | Now |
| --- | --- | --- |
| `setWhiteBalanceModeLocked` (`applyWhiteBalanceGains`) | **the crash** — NaN through | guard; unusable stored gains dropped |
| `setWhiteBalanceModeLocked` (`lockWhiteBalance`) | same hole, one user tap away | guard |
| `neutralizingGains` clamp (TovisKit) | **source of the poison** | shared guard; result finite by contract |
| `setExposureTargetBias` ×3 (face meter, card anchor, WB reset) | range-clamped, NaN through | guard |
| `calibrationBiasEV` store | a NaN parked here poisoned every later bias | sanitized at the store |
| `focusPointOfInterest` / `exposurePointOfInterest` (tap) | NaN if the preview layer has zero bounds | guard (`unitPoint`) |
| `exposurePointOfInterest` (face meter) | unvalidated Vision-derived point | guard (`unitPoint`) |
| `videoZoomFactor` | #273 range-clamped, NaN through | guard |
| `session.sessionPreset` | unguarded (`.photo` always supported, but still a bet) | `canSetSessionPreset` |
| `activeColorSpace` | #273 — checked against `supportedColorSpaces` | unchanged, already safe |
| `photoOutput.maxPhotoDimensions` | #273 — checked against the format's list | unchanged, already safe |
| `settings.maxPhotoDimensions` (per capture) | bounded by the output's own value | unchanged, already safe |
| `focusMode` / `exposureMode` / `whiteBalanceMode` | `is…Supported` gated | unchanged, already safe |
| `isSubjectAreaChangeMonitoringEnabled`, `conn.videoRotationAngle`, `maxPhotoQualityPrioritization` | no invalid domain | unchanged |
| `addInput` / `addOutput` | `canAddInput` / `canAddOutput` gated | unchanged |

Two latent leaks fixed in passing: `lockWhiteBalance`, `applyWhiteBalanceGains`
and `matchWideAngleFraming` now `defer { unlockForConfiguration() }`, because the
new guards introduce early returns *after* the device is locked.

⚠️ **CI does not compile the app target** (`swift test` on TovisKit only — see
the note in `.github/workflows/ci.yml`), so `CameraController.swift` changes are
green in CI whether they build or not. This change was built locally against the
iOS Simulator SDK: **BUILD SUCCEEDED**, 1144 TovisKit tests pass.

### 2026-08-05 — build 36 crashes the moment the camera opens (Tori, real device)

> "im in the app when i click the camera the app crashes immediately."

**Not the standalone camera.** The centre button out of session was the obvious
suspect (it was new in #261, and it is what Tori tapped), but it is not the
variable. `TOVIS_DEBUG_OPEN_PRACTICE_CAMERA=1` opens
`ProCapturePhotosView(destination: .practice)` on the simulator exactly as the
centre button does, and the whole pre-photon half runs clean: the view
constructs, `@Environment(SessionModel.self)` resolves, `ShotGuide.resolve`,
`CoachEngine.start()` (CoreMotion), the crop-guide wiring, the clip/byte vault
sweeps. It lands on the permission prompt and then the "No camera available"
dead end. **The in-session camera should be expected to crash identically** —
the destination is not involved.

**Where it actually is.** `CameraController.configureSession()`, on hardware,
after permission. Three properties there answer a bad value with an **ObjC
exception**, which Swift cannot catch, so each one is an instant process kill
with no preview ever drawn — precisely the reported shape:

| property | raises |
| --- | --- |
| `AVCapturePhotoOutput.maxPhotoDimensions` | size not in the active format's `supportedMaxPhotoDimensions` |
| `AVCaptureDevice.activeColorSpace` | colour space not in the active format's `supportedColorSpaces` |
| `AVCaptureDevice.videoZoomFactor` | factor outside the active format's range |

**All three read `device.activeFormat` from INSIDE the
`beginConfiguration`/`commitConfiguration` block** — i.e. before the session has
negotiated the format it will actually run, which it settles on COMMIT and which
depends on the full set of attached outputs (photo + video-data + movie). Every
value derived there describes a format the camera may not end up in.

That was survivable while the input was always the single wide-angle camera: one
camera, one obvious format, before and after agreed. **#268's B14 adopted the
virtual triple / dual-wide devices**, whose negotiation with three outputs
attached is not trivial — so the two reads stopped agreeing on hardware that has
a second lens, which is every phone a pro shoots on and no simulator.

**The fix.** The three format-dependent settings moved out of the configure pass
into `applyFormatDependentSettings(device:)`, which runs after the commit in its
own begin/commit pair, so each read of `activeFormat` describes the format that
is actually active, and each value is checked against that format's own
supported list.

**Two defects red-proofed on the way** (`CameraCompositionTests`), both in the
still-size choice, both latent until a virtual device reported a richer list:

- `dims.last(where: ≤ cap)` reads as "the largest under the cap" but is only
  that if the device lists ascending, which nothing promises. A device
  reporting 24 MP before 48 MP lost the 24 and shipped 12 — the pro's stills
  silently halving with nothing anywhere saying so.
- when everything on offer is over the cap the fallback was `dims.first`, which
  can be the LARGEST size on the device — the exact opposite of a cap that
  exists because full-sensor stills piled into the jetsam kills.

`maxPhotoDimensions(for:)` is now order-independent and always returns a member
of the list it was given.

⚠️ **NEVER CONFIRMED AGAINST A CRASH LOG, AND STILL ISN'T.** The root cause
above is reasoned from the diff and the surface; no build 36 log was ever
captured, and the simulator can only prove where the crash *isn't* — it has no
capture device, so `configureSession` never reaches any of the three properties
there.

What we know now: build 37 shipped this fix and **crashed again**, on a fourth
property (locked white-balance gains) that this entry never considered — see the
build 37 entry above, which *is* log-confirmed and symbolicated. So #273 was a
real hardening pass against a real crash class, but whether it fixed the crash
Tori actually hit in build 36 is unknown and now unknowable: build 36's
white-balance path had the same NaN hole, and the persisted-gain re-apply fires
on open, which fits "crashes immediately" at least as well. Treat #273 as
necessary, not as diagnosed.

### 2026-08-01 — first live client session (Tori, real device)

> "I tested the camera with a client today and it's making it mandatory to take
> multiple images. I'd like it to just be mandatory to take one before one after
> but them to have the option to take multiple."

**What was actually true.** Nothing in either repo ever *blocked* on a count
above one, and it's worth writing that down because it shaped the fix:

- `tovis-app` has **no** server-side photo requirement. `isAllowedSessionTransition`
  (`lib/booking/writeBoundary.ts`) never counts media; there is no media-plan or
  owed-photo config anywhere in the web repo. **No web change, no deploy.**
- The session gates already required exactly one — `beforeCount > 0` to continue
  to service, `afterCount > 0` to open the wrap-up checklist.
- `requestExit()` in `ProCapturePhotosView` has never counted photos at all. Its
  "unsaved work" is upload *custody* (unreviewed best shots, bytes the server
  hasn't taken, owed clips) — unrelated to how many shots were taken.

**What made it feel mandatory** was the directed shoot, which is 4–5 steps:

- the step chip's progress dots read as a checklist to clear ("1 of 5"),
- the completion moment — the "That's the full set" card, the accented **Done** —
  only arrived at the **last** step, so at 1-of-5 the app never said "you're
  done",
- the guide sheet listed five shots with checkmarks and said nothing about what
  was actually owed,
- and the same "at least one" rule was re-typed at four call sites in three
  different sentences, so no single place said what the requirement was.

### The rule now

**Exactly one BEFORE photo and one AFTER photo. Every additional shot is
optional — the guide directs, it does not demand.**

It lives in **one** place:
`TovisKit/Sources/TovisKit/ProSession/ProSessionPhotoRequirement.swift`
(`requiredPerPhase = 1`, plus the sentences, so no screen can promise a different
number). Change the constant, change the app. Unit-tested in
`ProSessionPhotoRequirementTests` + `ProSessionFlowTests.oneAfterPhotoSatisfiesCloseout`.

Everything that used to state the rule now asks that type:

| Surface | Before | After |
| --- | --- | --- |
| Hub — continue to service | `beforeCount > 0`, "Add at least one before photo…" | `isMet(captured:)`, "Add 1 before photo to continue to service — extras are optional." |
| Hub — wrap-up gate | `afterCount == 0`, "Take at least one after photo…" | `isMet(captured:)` + `gateSentence` |
| `ProSessionCloseoutInput` | took **both** `afterCount` and `hasAfterPhoto` (the rule, twice) | takes the count; `hasAfterPhoto` is derived — they can no longer disagree |
| Closeout row subtitle | `"\(afterCount) photos captured"` → "1 photos captured" | pluralised on the count |
| Camera — **Done** accent | lit at `allStepsDone` (5 of 5) | lit at `requirementMet` (1 photo) |
| Camera — completion moment | only "That's the full set", at the last step | "That's the one you need" the instant the requirement is met; the full-set card still fires at the end |
| Camera — guide sheet | shot list only | leads with "Only 1 before photo is required — the rest of this set is optional." |
| Camera — step chip a11y | "Shot 1 of 5" (reads as a quota) | same label, with the requirement as its accessibility value |
| Camera — exit | custody only | custody, **plus** one sentence if the phase still has no photo. Still a question, never a locked door. |

Deliberate non-changes:

- **The guide still runs all 4–5 steps and auto-capture still marches through
  them.** That's the AI photographer, and Tori asked for the *option* to shoot
  multiple, not for the direction to go away.
- `requestExit()` still never counts guide steps. An unfinished shot list costs
  nothing and must not hold the door.
- The web's `closeoutChecklist.ts` keeps its `hasAfterPhoto` input (its caller
  derives `afterCount > 0` — same rule). The Swift port's departure is documented
  in the file header.

### Rode along with this change

- **`tovis-app` #827** — the web wrap-up row said "1 photos captured" for the same
  reason. Copy only; no behaviour, schema or DTO. ⚠️ **MERGED, NOT DEPLOYED** —
  it rides the next deploy Tori authorizes.
- **`tovis-ios` #256** — `Wire contract` was red on *every* iOS PR (pre-existing on
  `main`) because `tovis-app` #821 (W6/W7 location truth) added required
  `isAddressPublic` + `locationType` to the pro-search location preview. Fixed as
  its own PR so this one stayed clean, and landed first so this one could merge
  on a green board. iOS never had W7's bug — Discover plots a pin and offers no
  directions — so the fix is the wire plus the rule (`publishedAddress` /
  `isNavigable`); see `BACKLOG.md §5`.

### Not verified on device

The simulator has no camera, so everything below was reasoned + compiled, not
watched:

- the requirement card appearing on the first keeper and retiring itself on the
  second shot (it shows only while `phasePhotoCount == 1` and something was shot
  in this camera session),
- the **Done** accent flipping at one photo,
- the exit sentence when leaving a phase with nothing shot,
- the guide-sheet requirement line under a trending pack / matched look.

Needs one real-device pass alongside the outstanding on-device tune.
