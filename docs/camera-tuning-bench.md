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
```

It compiles the **live** `Tovis/FrameMath.swift`, `Tovis/VisionDetect.swift`,
`Tovis/ShotCoach.swift` and `Tovis/CoachTuning.swift` on every run, so it cannot
drift from what the camera does. No simulator, no device, no camera — it reads
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

`CoachReadinessTests.theCoachTalksAboutLightWhileTheFrameIsFailingOnFocus` pins
the concrete case: a frame that is amber **because it is soft** shows the pro
"turn off the overheads".

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
2. **Lower `clutterReference`** (or `clutterBusy`) so `BackgroundCoach` can fire
   at all — currently it is dead weight on portraits. **Still open**; the
   direction is measured, the value is the device pass's.
3. **Reconsider the colour weight or the mixed-light score** so a
   low-confidence, often-unactionable signal cannot outrank focus and tilt for
   the single on-screen line. **Still open** — but much less pressing now that
   the signal is de-confounded and the tip has a dwell + switching margin, so
   even when colour wins it no longer wins six times a second.

## What still genuinely needs the phone

- Every number in the table re-measured on live preview frames in a real salon.
- `LevelCoach` entirely: CoreMotion has no reading here, and the tilt **sign
  convention** (`"tilted right"` vs `"left"`) is flagged unverified in the source.
- `autoCaptureHoldSeconds`, `analysisFPS`/`heavyFPS` cadence, thermal/perf.
- The composed Step-2 UI over a live preview (never seen; surfaces were only
  rendered standalone).
- Whether the readiness ring *feels* right, which no bench can answer.
