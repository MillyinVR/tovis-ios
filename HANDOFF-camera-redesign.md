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

## Device feedback log

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
