# Coach tuning bench — measuring the camera coach without a device

`CoachTuning.swift` opens by admitting its numbers were set without hardware.
The on-device pass (`CoachTuningHUD`, DEBUG, sliders over the live preview) is
still owed. But the coach's behaviour splits into two halves, and only one of
them actually needs a camera:

| | needs a device? | instrument |
|---|---|---|
| **Perception thresholds** — what raw luma/edge-energy/warmth the sensor produces | partly | this bench for the order of magnitude, `CoachTuningHUD` to confirm on the phone |
| **Scoring arithmetic** — which combinations clear the green ring, which tip wins the one on-screen line | **no** | `CoachAggregate` + `TovisTests/CoachReadinessTests.swift` |

This bench covers the first column offline. `CoachReadinessTests` pins the second.

## Running it

```sh
scripts/coach-tuning-bench/run.sh ~/Pictures/salon-session/
scripts/coach-tuning-bench/run.sh a.heic b.jpg
scripts/coach-tuning-bench/run.sh --compile-only   # build against the live sources, run nothing
scripts/coach-tuning-bench/run.sh --selftest       # build + run + diff against the pinned baseline (what CI does)
scripts/coach-tuning-bench/run.sh --update-baseline # accept the current output as the new pin
```

### What CI covers, and what it does not

`--selftest` runs on every PR, in the `Coach tools` job (`swiftc` only, no
simulator — it shares a runner with the voice-manifest check because macOS
bills at 10x).

It exists because of how this bench actually fails. It compiles the LIVE
perception sources every run, which is what makes it trustworthy, and it keeps
a **hand-maintained list** of those sources, which is what makes it fragile.
That list has broken twice, and both times **silently**: `ShotExpectations`
moved out of the file the script brace-matched it from and the bench stayed
broken for ~19 days (found 2026-08-23), and #360 added a source the list did
not know about. Nothing ran it, so nothing said so. `--selftest` also runs the
whole path over generated frames and fails if the bench decodes none of them,
so "links, then dies on the first image" cannot pass either.

It then **diffs the numbers** against
`scripts/coach-tuning-bench/selftest-baseline.txt`. That is what makes this more
than a smoke test: a change to `FrameMath`, the coaches or `CoachTuning` that
moves what the camera MEASURES shows up as a diff on the PR that moved it,
instead of relying on someone remembering to diff the bench by hand. If the
change is intended, `--update-baseline` and commit the new pin in the same PR —
the movement becomes reviewable as numbers. Moving `sharpnessReference` 0.12 →
0.15, for instance, shows both the threshold and the three frames whose
normalized sharpness it drags with it.

**The pin holds only what reproduces on a different machine.** Whole-frame
luma, raw edge energy, normalized sharpness, whole-frame colour, whether a face
was found, and the thresholds those are judged against. Measured 2026-08-25,
this Mac vs a `macos-latest` runner: every one agreed to the digit.

🔴 **Nothing derived from the person-segmentation mask is pinned** — `fill`,
`clutter`, `bgLuma`, background-scoped colour, and the readiness/coach line
that depend on them. Those did *not* agree across machines: bgLuma 0.520 vs
0.522, fill 0.00 vs 0.01, background edge median 0.0157 vs 0.0158.
`VNGeneratePersonSegmentationRequest` is an ML model that ships with the OS,
and a runner's is not this Mac's. Pinning a value the machine decides buys a
check that goes red for reasons nobody in this repo caused, which is worse than
no check — it teaches people to ignore red. Those columns are still PRINTED, in
the tables CI logs; they are just not asserted.

It earned its keep on day one: pinning the output immediately exposed that the
bench's own "which line wins" tally sorted ties with
`sorted(by: { $0.value > $1.value })`, leaving equal counts in Dictionary order
— and Swift randomizes its hash seed per process. Two categories on the same
count came out in either order from run to run. The 35-image corpus never
showed it because its counts are all distinct (19/11/3/1/1).

🔴 **What CI still cannot do is CALIBRATE, and a green tick says nothing about
whether the numbers below are RIGHT.** Regression and calibration are different
questions. CI pins the first — "did this change move what the bench measures?"
Only real photographs answer the second — "is 0.13 the right
`mixedLightSpread` for a salon?" The self-test frames are synthetic gradients
with no faces, no optics and no salon light, so every value they yield is
meaningless as tuning data and useful only as a fixed point to diff against.

The real corpus cannot come to CI: the 35 photographs are Apple's files out of
an installed simulator runtime, this repo is public, and a hosted runner has a
different runtime than the one the recorded numbers came from. **Every threshold
in this document still comes from a hand-run on that corpus, and still has to be
re-run before it is trusted.**

### The corpus the runs below used, exactly

Recorded 2026-08-23 because it never was: the previous two runs describe their
corpus in prose ("images bundled with the installed simulator runtimes"), which
is not enough to reproduce a number. These are the files, from the **iOS 26.4**
simulator runtime:

```sh
R="/Library/Developer/CoreSimulator/Volumes/iOS_23E254a/Library/Developer/\
CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources"
mkdir -p /tmp/corpus35
cp "$R/SampleContent/Media/DCIM/100APPLE/"* /tmp/corpus35/           #  6
find "$R/RuntimeRoot/System/Library/NanoTimeKit/FaceBundles" \
  \( -name 'base_*.heic' -o -name 'gallery-placeholder-*-base.heic' \) \
  -exec cp {} /tmp/corpus35/ \;                                      # 29
scripts/coach-tuning-bench/run.sh /tmp/corpus35/
```

6 + 17 `base_*` (NTKUltraCube) + 12 `gallery-placeholder-*` (NTKParmesan) = 35.
The August 1 corpus of 23 is the same minus the 12 Parmesan assets. Rebuilding
it this way reproduced August 4's numbers to the digit (faceLuma median 0.487,
background `mixed` median 0.086, bg-edge median 0.0402), which is what confirms
it is the right set. Substitute a runtime path if 26.4 is no longer installed —
and note in the run if you do, because the numbers will move.

It compiles the **live** `Tovis/FrameMath.swift`, `Tovis/VisionDetect.swift`,
`Tovis/ShotCoach.swift`, `Tovis/CoachCanonicalCopy.swift` (where every coach's
corrective line now lives) and `Tovis/CoachTuning.swift` on every run, so it
cannot drift from what the camera does. No simulator, no device, no camera — it reads
image files on the Mac and prints the raw signal behind every threshold:
per-image luma, raw edge energy (pre-normalization), normalized sharpness, face
hit, subject fill, raw background edge energy, clutter, mixed-light spread,
warmth and pose-joint count, then min/median/max summaries against the current
thresholds.

Point it at real salon photos and the guessed divisors become measured ones.

### What it deliberately does not do

- **CoreMotion.** `LevelCoach` returns a neutral 1.0 with no tilt reading, so
  every bench number is one coach short of a real frame. On the Simulator the
  same is true — bench and simulator scores both run high.
- **Live preview frames.** A decoded still is not a sensor frame at
  `workingMaxDim`: no auto-WB settling, no focus hunting, different noise. The
  bench establishes magnitude, not the final value.

## Measured, 2026-08-01

Corpus: 23 real photographs bundled with the installed Xcode simulator runtimes
(6 general `SampleContent` shots + 17 portrait watch-face assets, all with a
detected face). Not salon photos — but real optics, real people, real
backgrounds, which is what the divisors were guessed against.

| threshold | current | measured on the corpus | read |
|---|---|---|---|
| `sharpnessReference` | 0.12 | raw edge energy median 0.078 (min 0.014, max 0.162) → normalized median 0.65 | **about right** — the one guessed divisor that landed. A touch generous: 14/23 already score a perfect 1.0 from `SharpnessCoach` (4 saturate the metric itself), and 2 well-focused photos are still called "clearly soft". |
| `clutterReference` | 0.18 | area-normalized bg edge median 0.040 → normalized clutter 0.22 | **too forgiving.** 1/23 overall and **0/17 portraits** ever reach `clutterBusy = 0.6`. `BackgroundCoach` effectively never fires. |
| `mixedLightSpread` | 0.13 | spread median **0.136** (min 0.009, max 0.523) | **sits on the median of ordinary photographs.** 12/23 overall and **9/17 portraits** trip "Mixed light — turn off the overheads". |
| `lumaTooDark` / `lumaIdeal` | 0.22 / 0.47 | luma median 0.62 (min 0.244, max 0.739) | plausible; nothing in the corpus reads as too dark. Real salon light is the open question. |
| `warmCastWarmth` | 0.30 | warmth median −0.004 (min −0.256, max 0.271) | never tripped. Untested by this corpus. |

## The finding that matters

`mixedLightSpread` is not merely mistuned — it lands where it does the most
damage, because of how the one coach line is chosen.

`ColorCoach` scores **0.45** on mixed light, at weight **1.1** → a weighted
deficit of **0.605**. The nudge shown is whichever coach has the largest
weighted deficit. 0.605 outranks *everything* except an outright lighting
failure (0.96–1.12) or a clearly soft frame (0.98) — it beats a soft frame
(0.56), a clearly tilted camera (0.60), every composition tip (0.45–0.55) and a
busy background (0.40).

So on roughly half of ordinary portrait frames, the coach's single line is
"Mixed light — turn off the overheads": a tip the pro often cannot act on (the
overheads are the salon's), derived from a signal that is **content-confounded**
— `mixed` is the warm↔cool spread across the frame's left/middle/right thirds,
so a red top on one side and a cool wall on the other reads as "mixed light"
under perfectly uniform illumination.

`CoachReadinessTests.theCoachTalksAboutLightWhileTheFrameIsFailingOnFocus` pinned
the concrete case: a frame that is amber **because it is soft** shows the pro
"turn off the overheads". → **That test was deliberately rewritten 2026-08-23**
into the pair `aTouchSoftFrameStillYieldsTheLineToTheRoomsLight` (unchanged, and
meant to be) and `aClearlySoftFrameTakesTheLineBackFromTheRoomsLight` (the fix).
See the 2026-08-23 run below for why the case had to be split in two — the frame
this paragraph describes is only a TOUCH soft, which is a correction rather than
a hard failure and still yields to colour on purpose.

Camera Step 2 (iOS #250) cut 13 simultaneous elements to 5 and made one coach
line the primary voice. That subtraction did not cause this, but it removed
everywhere else the pro could look — so a wrong, unactionable, unchanging line
is now most of the coaching experience. This is a strong candidate for the
"so much going on… I feel overwhelmed instead of feeling like it's helping me"
report that started the redesign chain.

### Secondary: the green ring and the Session Reel disagree

`readyThreshold = 0.8` vs `harvestThreshold = 0.85` leaves a band where the ring
is green and auto-capture fires but the reel harvests nothing. Mixed light + a
busy backdrop + 3.5° of hand tilt lands at **0.818** — green, never harvested.
Deliberate (the reel should keep only the best), but worth knowing the reel can
stay empty through an entire ordinary session.

> **→ CLOSED 2026-08-23** (plan item 2, the backstop harvest). The band is still
> there and the arithmetic behind it is unchanged; what it COSTS is what changed.
>
> The number moved: that frame measures **0.826** today, not 0.818. The cause is
> not the backdrop retune below — this frame is scored from an already-normalized
> `clutter: 0.70`, which `clutterReference` never touches — it is the removal of
> `PoseCoach`'s silent 0.9 cap on any detected body: deficit 0.6 × 0.1 ÷ 7.5 total
> weight = **+0.008**, exactly the gap. (Pinned by
> `CoachReadinessTests.detectingABodyNoLongerCostsReadiness`.) It moved the frame
> further INTO the band, not out of it.
>
> `harvestThreshold` has stopped being the reel's floor. A steady green HOLD is
> now a second way in — a hold that has been ready for `autoCaptureHoldSeconds`
> banks a frame, and then banks again only when it improves on what the reel
> already took from it, which is what keeps one long pose from spending the tray.
> See `Tovis/CoachHarvestGate.swift`; pinned by `CoachHarvestGateTests` and by the
> rewritten pair in `CoachReadinessTests`
> (`anOrdinarySalonFrameLandsBetweenTheRingAndThePeakGate` — the measurement,
> unchanged — and `theSameFrameIsBankedOnceTheHoldIsSteady` — the fix).
>
> ⚠️ What this does NOT do: it does not stop a frame that clears 0.85 on a real
> defect from being kept. `aLightingFailureAloneStillClearsBothTheRingAndTheHarvestGate`
> still stands, and is still the device pass's call.

### Secondary: the readiness budget

Readiness ≥ 0.8 allows a total weighted deficit of 1.5 across seven coaches.
Ordinary salon conditions cost: mixed light 0.605, busy background 0.40, 3.5°
off level 0.30, a touch soft 0.56, a detected body 0.06 (permanent — `PoseCoach`
caps at 0.9 whenever it sees a person). Three ordinary conditions usually still
clear the ring; the fourth never does.

---

## Measured again, 2026-08-04 — after the pre-device-pass fixes

The bench was extended (plan item **B17**) to report the columns §3.1 and §3.2
of `docs/design/camera-excellence-plan.md` actually need: `faceLuma`,
`faceLuma/luma`, `backgroundLuma`, `faceLuma/backgroundLuma`, the colour signals
measured **both ways** (whole frame vs segmented background), and **the coach
line each image would put on screen**. It also stopped keeping its own copies of
the analyzer's segmentation and colour math — both now live in `FrameMath` and
the bench calls them, so it cannot drift from the camera.

Corpus: 35 images — the 6 `SampleContent` shots plus 29 watch-face / gallery
placeholder assets from the installed iOS 26.4 simulator runtime. 21 have a
detected face. **Still no complexion coverage** (see the caveat below).

### The headline: relocating colour onto the background fixed the worst finding

| | whole frame (what shipped before) | segmented background (what ships now) |
|---|---|---|
| `mixed` median | **0.120** | **0.086** |
| `mixed` max | 0.523 | 0.416 |
| trips `mixedLightSpread = 0.13` | **17/35** | **11/35** |

The August 1 finding was that `mixedLightSpread` "sits on the median of ordinary
portraits" and therefore wins the single coach line about half the time. **The
relocation alone moves the median from above the threshold to below it, without
touching the threshold.** Six images that were being told to turn off the
overheads no longer are.

Per-image, the confound is large where you'd expect — a subject filling the
frame in strongly-coloured clothing:

```
base_4D9C5F54…   mixed 0.523 → 0.145    warmth −0.031 → −0.539
base_E73CC61B…   mixed 0.297 → 0.032    warmth −0.256 → −0.393
base_152A8D27…   mixed 0.309 → 0.035    warmth −0.241 → −0.371
gallery-…-3B     mixed 0.280 → 0.095    warmth −0.212 → −0.657
```

`warmCastWarmth = 0.30` was never tripped by the August corpus. On the
background column it is now tripped by exactly one image (max 0.336) — still
essentially untested, still the device pass's call.

### faceLuma, reported for the first time

| | min | median | max |
|---|---|---|---|
| `faceLuma` (21 faces) | 0.276 | **0.487** | 0.606 |
| `faceLuma / luma` | 0.488 | 0.844 | 1.130 |
| `faceLuma / backgroundLuma` | 0.467 | 0.841 | 2.120 |

Zero faces fall outside the `lumaTooDark 0.22 … lumaTooBright 0.78` band, so on
this corpus the relocated exposure rule changes no verdict — which is expected
and is exactly why §3.1 needs real subjects. What the table gives the device
pass is the **shape** of the distribution to compare a salon sweep against.

### ⚠️ The direction the device pass must set

Moving the backlit test onto the background makes it **more** sensitive at the
current `backlitFaceRatio = 0.6`, not less: `faceLuma/backgroundLuma` has a
median of 0.841 against `faceLuma/luma`'s 0.844, but its *lower tail* is lower
(0.467 vs 0.488) because the background is brighter than a frame average the
darker subject was dragging down.

On this corpus it changes nothing (1 image trips, either way). On deeper
complexions it will trip more. The relocation is still the right comparison —
face-vs-background is what "the light is behind them" means — but it is a
**structural** fix and **not** a fix for the deep-complexion false positive.
`CoachReadinessTests.relocatingTheBacklitTestMakesItMoreSensitiveNotLess` pins
this so it can't surprise anyone.

### Which line wins now

| count | line |
|---|---|
| 17/35 | composition — "Move in closer — fill the frame" |
| 10/35 | colour — "Mixed light — turn off the overheads" |
| 6/35 | sharpness |
| 1/35 | lighting |
| 1/35 | nothing to fix |

Colour is no longer the top voice; composition is. That is partly the fix and
partly the corpus (watch-face assets are framed loose, so `minSubjectFill 0.22`
fires constantly on them — a corpus artefact, not a salon finding).

`BackgroundCoach` now fires on 4/35 rather than 1/23 — but only on the faceless
gallery assets, which have no subject to segment. **On portraits it is still
effectively dead**, so August's recommendation #2 stands and is still the device
pass's number to set.

### Still no complexion coverage

This remains the single biggest gap in the bench, and it is the one thing the
bench could fix on a Mac. To close it, point `run.sh` at a folder of
complexion-diverse portraits shot under one light and read Table 1:

```sh
scripts/coach-tuning-bench/run.sh ~/Pictures/complexion-sweep/
```

Until then §3.1 is a discovery on the device rather than a confirmation.

---

---

## Measured again, 2026-08-23 — the backdrop threshold, and the ladder's cost

Same 35-image corpus as August 4 (recipe above), re-run to set
`clutterReference` (plan item 1.2) and to measure what sequential focus
coaching did to which line the pro actually sees (plan item 1.3).

### ⚠️ First finding: the bench had not run since August 4, and said nothing

It did not fail loudly — it failed at the first step and exited, and nobody had
run it in the 19 days since. Three separate rots, all from ordinary refactors
that no test covered because **nothing in CI compiles this script**:

1. `ShotExpectations` moved out of `ShotGuide.swift` into its own file, so the
   `awk` block that brace-matched the struct out of `ShotGuide.swift` extracted
   nothing.
2. `PublishCrop.swift` moved into TovisKit, so the file list pointed at a path
   that no longer exists — and `ShotCoach.swift` gained `import TovisKit` with
   it.
3. The file list predated `CoachFocusLadder.swift` and the `CoachMoment`
   vocabulary, so even once the paths were fixed, `FocusRung` and
   `CoachPhraseContext` were undefined.

Fixed by compiling the real sources instead of reconstructing them: the shim is
gone, `PublishCrop` is compiled from its TovisKit path with the single
`import TovisKit` line stripped from the bench's copy of `ShotCoach.swift`, and
`CoachMoment`/`CoachPhraseContext` were split out of `CoachVoice.swift` into
`CoachMoment.swift` so the decision layer can be compiled without dragging
SwiftUI (via `CoachPersonality`) behind it. A path that moves now fails the
build loudly rather than silently.

**The lesson worth keeping:** this bench is the only instrument for half the
tuning plan, and it is not exercised by anything. Treat "run the bench" as
"first, check the bench still runs".

### `clutterReference`: 0.18 → 0.125

The bench now reports the distribution **portraits-only**, which is the fix that
mattered for reading it. Only a frame with a segmented person has a real
background; without one the mask is empty, the "background" is the whole frame,
and the number measures how busy the PICTURE is. All four images that were
firing `BackgroundCoach` at the old threshold were faceless — which is why it
looked half-alive while being completely dead where it counts.

| raw area-normalized background edge | min | median | max |
|---|---|---|---|
| all 35 | 0.0000 | 0.0402 | 0.1634 |
| **the 21 portraits** | 0.0000 | **0.0371** | **0.0968** |

At `clutterReference = 0.18`, "busy" needs raw > `clutterBusy × 0.18` = 0.108 —
**above the busiest portrait in the corpus**. 0/21. Reconfirmed, now on the
larger corpus (August's "0/17" was the same finding on the 23-image one).

The sweep the bench prints, so the choice is auditable rather than asserted:

| clutterReference | busy above | portraits judged busy |
|---|---|---|
| 0.180 | 0.1080 | 0/21 (0%) |
| 0.150 | 0.0900 | 2/21 (10%) |
| 0.130 | 0.0780 | 2/21 (10%) |
| **0.125** | **0.0750** | **3/21 (14%)** |
| 0.120 | 0.0720 | 4/21 (19%) |
| 0.110 | 0.0660 | 5/21 (24%) |
| 0.080 | 0.0480 | 6/21 (29%) |

**0.125 chosen.** It puts the busy line at ~2× the median portrait rather than
on it — which is the entire lesson of `mixedLightSpread`, a threshold set at the
median of ordinary photographs that fired on half of them until it read as
noise. Deliberately the conservative end of "fires at all": this corpus's
backdrops are cleaner than a working salon's shelves and mirrors, so the same
number will fire MORE on real frames, not less. The salon pass should expect to
lower it further after watching it, never to raise it blind.

What it costs: normalizing against a smaller divisor raises every frame's
clutter, so an ordinary portrait pays ~0.01 more readiness than before (the
non-busy score floors at 0.7, so the cost is bounded). Pinned in
`CoachReadinessTests.wakingTheBackdropCoachCostsAMedianPortraitAboutAHundredth`
rather than left to be discovered next to the 0.80/0.85 ring-vs-harvest band.

### What the focus ladder had done to the one line

Re-running August 4's corpus against today's code measures the ladder change
(2026-08-06) that landed between the two runs — this was never measured when it
shipped:

| which line wins | 2026-08-04 (weighted deficit) | 2026-08-23 (ladder, before this change) | after |
|---|---|---|---|
| composition | 17/35 | 21/35 | 19/35 |
| colour | 10/35 | 12/35 | 11/35 |
| **sharpness** | **6/35** | **0/35** | **3/35** |
| lighting | 1/35 | 1/35 | 1/35 |
| nothing to fix | 1/35 | 1/35 | 1/35 |

Sharpness is the ladder's LAST rung, so once ordering replaced weighted deficit
it stopped winning the line at all: all six frames that used to be told "hold
steady" were told about colour or framing instead. Three of those are frames the
sharpness metric calls **clearly soft** — motion blur no edit recovers.

That is what "a hard failure outranks its rung" (item 1.3) fixes, and the 3/35
is its measured effect. The other three were only a TOUCH soft, and still yield
to colour on purpose: the ladder is right that fixing the room is the bigger
adjustment, and "tap to focus" is polish that can wait its turn.

Note this restores exactly what the pre-ladder rule got right — August 1
measured mixed light outranking everything "except an outright lighting failure
or a clearly soft frame" — without giving up sequential coaching. Ordinary
corrections are still taken strictly one at a time, in rung order.

---

## Recommended next steps

These are **recommendations, not applied changes** — the corpus is not salon
footage, and the perception numbers are the device pass's call:

1. ~~**Re-measure `mixedLightSpread` against real salon frames** before changing
   it.~~ …and consider whether `mixed` should be measured on the background
   region only (excluding the segmented subject) to kill the content confound.
   → **The background-only half SHIPPED 2026-08-04** and moved the median below
   the threshold on its own. The re-measurement against real salon light is
   still owed and is now plan §3.2 — and it must be read off the **background**
   column, which is what the coach judges.
2. ~~**Lower `clutterReference`** (or `clutterBusy`) so `BackgroundCoach` can
   fire at all — currently it is dead weight on portraits.~~ → **DONE
   2026-08-23: 0.18 → 0.125**, set from the portrait-only distribution above.
   The salon pass still owns the final value; the direction to expect there is
   DOWN again, not up.
3. ~~**Reconsider the colour weight or the mixed-light score** so a
   low-confidence, often-unactionable signal cannot outrank focus and tilt for
   the single on-screen line.~~ → **ADDRESSED 2026-08-23**, but not by touching
   the weight or the score. Neither picks the line any more: `CoachSeverity`
   lets an unrecoverable capture outrank its rung, so a clearly soft frame takes
   the line back from mixed light while every ordinary correction keeps its
   ladder order. The colour WEIGHT (1.1) is untouched and still means what it
   always did — how much mixed light drags the readiness ring down — which is a
   separate question the salon pass should still look at.

   Left open underneath it: `mixedLightSpread` itself is still un-measured
   against real salon light (§3.2), and colour still wins 11/35 lines here.
   Severity stops it outranking a lost frame; it does not make it right.

## ⚠️ Before you retune `mixedLightSpread` or `clutterReference` (added 2026-08-23, P4.1)

Those two constants now have a second consumer. `CoachRoomMemory` lets a pro
retire a room-condition tip at their own salon ("the overheads stay on here"),
and the record is keyed on **tip-id + location and nothing else** — no
threshold value, no tuning version. That is deliberate, and it was chosen
against the alternative:

- **A retune cannot resurrect a dismissal.** The pro's answer was never about
  the number: "the overheads stay on here" is a statement about the salon, and
  the salon does not change when `mixedLightSpread` does. A dismissal quietly
  evaporating because a constant two files away moved is exactly the
  forgetting the phase exists to fix, and the pro experiences it as the coach
  going back on its word.
- **The cost of that choice** is the other half: a dismissal keeps suppressing
  a tip even if a retune changes what that tip *claims* about a room. That is
  made non-silent rather than accepted blind —
  `CoachRoomMemory.meaningVersions` (empty today) is the deliberate,
  auditable invalidator. If your retune genuinely changes what a moment
  **means**, bump that moment's version in the same commit and every pro's
  dismissal of it is forgotten at once, in the diff. If it only moves where
  the threshold sits, leave it alone.

Pinned by `CoachRoomMemoryTests.aThresholdRetuneCannotResurrectADismissal` and
`.aMeaningVersionBumpIsTheOnlyThingThatForgetsADismissal`.

Note also that none of this moves a number this bench measures: the dismissal
suppresses the on-screen SENTENCE, never a score, and the bench runs through
`CoachAggregate.evaluate(_:_:)`, whose fresh arbiter carries no dismissals at
all. The 2026-08-23 run above was reproduced to the digit after the change
(19/35 composition · 11/35 colour · 3/35 sharpness · 1/35 lighting · 1/35
nothing to fix), which is what says so.

## The coach backing off, and why it moves nothing here (added 2026-08-24, P4.3)

`CoachBackOff` gives the tip arbiter a second reason to stop saying something:
a rung that has held the lane for `CoachTuning.coachPatienceSeconds` with **no
measurable improvement in its own score** is said once more plainly and then
dropped, and the ladder coaches the next thing instead.

Three things about it matter to whoever reads this file next:

1. **`coachPatienceSeconds` is not a perception threshold.** It sits in the
   "How the one coach line behaves" block with `focusStabilityWindow` and
   `focusRegressionWindow` — behavioural numbers set by how long a person takes
   to read a line and act on it. The salon pass does not invalidate it; a
   stopwatch on a working pro would. Do not sweep it with the luma/edge/colour
   numbers.
2. **It changes no number this bench measures.** The bench runs every image
   through `CoachAggregate.evaluate(_:_:)`, whose fresh arbiter is asked
   **once**, at `now = 0` — so nothing can have stalled and every line is the
   canonical one. The 2026-08-23 run reproduces to the digit after the change
   (19/35 composition · 11/35 colour · 3/35 sharpness · 1/35 lighting · 1/35
   nothing to fix), which is what says so, and it was re-run BEFORE the change
   as well to prove the bench itself still ran.
3. **`Tovis/CoachBackOff.swift` is now in `run.sh`'s file list.** `ShotCoach.swift`
   references the type, so a bench that did not compile it would fail — loudly,
   which is the design, but the file list is a thing to keep in step (this is
   the third rot mode the 2026-08-23 repair called out).

Like a dismissal, backing off suppresses the SENTENCE and never a score:
readiness is a weighted mean computed before the arbiter is consulted, and the
dimensions drawer is built from the same signals. Pinned by
`CoachTipArbiterTests.backingOffDoesNotMoveReadinessOrTheDimensionsDrawer`.

## The station read, and why it moves nothing here (added 2026-08-24, P4.2)

`CoachStationRead` lets a pro snap their empty station once; the read is
stored per room by `CoachRoomMemory` and reaches the pro as **words**
(`CoachRoomVocabulary`, at the #974/#358/#360 seam in `CoachEngine.apply`)
and as an **earlier GOT IT offer** for the colour tips the station itself
measured. Four things about it matter to whoever reads this file next:

1. **It seeds no threshold prior and moves no score — deliberately, and
   against the plan's own wording.** The plan said "seeds profile/priors".
   The colour thresholds this bench measures have never been salon-measured
   (§3.2 is still owed), so a per-room delta would compound a guess with a
   guess — and a ring that means different things in different rooms cannot
   be trusted in any of them. When the salon pass has set the base numbers,
   a prior can be argued from data; the profile already stores the raw
   station measurements it would need.
2. **Nothing in this bench's compile graph changed.** `ShotCoach.swift`,
   `CoachTuning.swift` and `FrameMath.swift` are untouched;
   `CoachStationRead`/`CoachRoomVocabulary` are consumed by
   `CoachRoomMemory`/`CoachEngine`, which are deliberately outside the graph
   — so `run.sh`'s file list needs no new entry. The 2026-08-23 run
   reproduces to the digit after the change (19/35 composition · 11/35
   colour · 3/35 sharpness · 1/35 lighting · 1/35 nothing to fix), re-run
   BEFORE the change as well to prove the bench itself still ran.
3. **A retune coherently moves what an old read means.** The profile stores
   RAW numbers (warmth, green tint, per-third warmths) and every verdict —
   window, cast, which tips it corroborates — is derived at use time against
   the CURRENT `CoachTuning` thresholds. Move `mixedLightSpread` or
   `warmCastWarmth` and every stored read is re-interpreted under the new
   meaning in the same commit, with nothing stale frozen into UserDefaults.
   That is also why no `meaningVersions` bump accompanies a station read: it
   never changes what any moment CLAIMS — it only adds the room's own
   evidence for the claim, which is why the offer may come early.
4. **The read expires** (`CoachRoomMemory.stationReadMaxAge`, ~6 months) and
   can be retaken any time from the session hub — a salon's light changes
   and the coach cannot see it happen, so an unbounded read would drift ever
   further from the room it claims to know.

## The before-parity recognition, and why it moves nothing here (added 2026-08-24, P5.3)

`BeforePair` adds the coach's first line of GOOD NEWS — "Light and framing
match the before", when the after now pairs with its before on both axes the
app already measures. The bench's numbers are byte-identical before and after
it (19/35 composition · 11/35 colour · 3/35 sharpness · 1/35 lighting · 1/35
nothing), and that is structural, not luck:

1. **It measures nothing new.** Both terms are comparisons that already run —
   `LightMatch.verdict` against the before's stamp, and the before's own fill
   band. No coach's score, no rung, no readiness, no `signals`. The bench
   measures the live coaches, and none of them changed.
2. **It invents no threshold.** The light half uses
   `lightMatchLumaTolerance` / `lightMatchWarmthTolerance`; the framing half
   uses `BeforeShotMeasure.pairFillBand`, which is now the ONE definition that
   `ShotExpectations.matchingFraming` also coaches to. **If you retune either,
   the recognition and the coaching move together** — the coach cannot end up
   asking for one framing and congratulating another. That single derivation is
   the thing to preserve if you touch the fill tolerance (today `0.12`).
3. **It is not in the bench's compile graph**, but two files it touches are:
   `CoachMoment.swift` (a new case) and `ShotCoach.swift` (`CoachResult` gained
   `frameSubjectFill`, a passthrough). Both are in `run.sh`'s file list already,
   so the bench compiles them and would break loudly rather than silently.
   `BeforePair.swift` itself needs no entry — nothing in the graph references it.

### 🔴 A real defect found while building this, NOT fixed here

`ShotExpectations.matchingFraming` derives the after's fill band from the
before stamp's **whole-frame** subject fill (`BeforeShotMeasure.measureSync`
measures with `cropGuide: nil`). `CompositionCoach` compares that band against
`FrameContext.judgedFill`, which is a fraction of the **9:16 publish crop**
whenever the pro has the crop guide on. Those are not the same quantity.

`PublishCrop.feedRect` is the centred `(9/16) ÷ (3/4) = 0.75` of the frame's
width, full height — so a subject sitting inside it fills ~`1/0.75` = 1.33× as
much of the crop as of the frame:

| before fill (whole frame) | band | identical after, as crop fill | coach says |
|---|---|---|---|
| 0.30 | 0.18–0.42 | 0.40 | in band |
| 0.35 | 0.23–0.47 | 0.47 | in band |
| **0.40** | 0.28–0.52 | **0.53** | **"Too tight — step back a touch"** |
| 0.45 | 0.33–0.57 | 0.60 | "Too tight — step back a touch" |
| 0.50 | 0.38–0.62 | 0.67 | "Too tight — step back a touch" |

So with the crop guide ON and a before filling more than about 0.39 of its
frame, an after framed **identically to its pair** is already told to step
back. (The table assumes the subject sits fully inside the crop, so it is the
upper bound of the skew; a subject spilling past the crop edges skews less.)
This predates P5.3 — it arrived with the crop-aware composition judging.

P5.3 does **not** fix it, and deliberately does not route around it: the
recognition reads the very same `judgedFill`, so it stays consistent with
whatever the coach says rather than contradicting it on screen. Fixing it
means measuring the stamp's crop-space fill as well (`FrameMath.segmentSignals`
already takes a `cropGuide:`) and picking the matching one in `pairFillBand` —
which MOVES the "too far / too tight" thresholds, so it belongs with the salon
pass, not with a recognition line.

Noticed alongside it, unfixed and cosmetic: `PublishCrop`'s header and
`CompositionCoach`'s `closerWhy` both say the feed crop "takes ~40% of the
width off". The arithmetic above says **25%**. `closerWhy` is user-facing (the
dimensions drawer, and spoken).

⚠️ **Known, inherited, NOT introduced here**: a light verdict flickering across
its own tolerance re-announces on every crossing, exactly as it does today. The
FRAMING re-cross — the new way in — is floored by
`CoachTuning.settleLineMinInterval`. Flooring the light path too would mean
suppressing lines that ship today, which P5.3 deliberately did not do; if the
salon pass finds the light tolerances too tight, that flicker is a reason to
widen them rather than to add a fourth knob. Pinned by
`aFlickeringLightVerdictStillReAnnouncesJustAsItDoesToday`.

## What still genuinely needs the phone

- Every number in the table re-measured on live preview frames in a real salon.
- `LevelCoach` entirely: CoreMotion has no reading here, and the tilt **sign
  convention** (`"tilted right"` vs `"left"`) is flagged unverified in the source.
- `autoCaptureHoldSeconds`, `analysisFPS`/`heavyFPS` cadence, thermal/perf.
- The composed Step-2 UI over a live preview (never seen; surfaces were only
  rendered standalone).
- Whether the readiness ring *feels* right, which no bench can answer.
- **`coachPatienceSeconds` = 20** (P4.3): whether twenty seconds of an unmoved
  score is the right moment to say it plainer, and forty the right moment to
  stop. Set from how long a real physical adjustment takes to land; only
  watching a pro mid-session settles it.
- **The before-parity recognition** (P5.3): whether being told the pair landed
  reads as a photographer noticing or as the app congratulating itself, whether
  the lane's 2s transient is long enough to read it, and whether
  `settleLineMinInterval` (12s) is the right floor for a frame hovering on the
  edge of the before's fill band. All three are felt, not measured.
