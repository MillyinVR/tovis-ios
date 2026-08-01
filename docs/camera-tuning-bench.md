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

## Recommended next steps

These are **recommendations, not applied changes** — the corpus is not salon
footage, and the perception numbers are the device pass's call:

1. **Re-measure `mixedLightSpread` against real salon frames** before changing
   it. If the median there is also ~0.13, raise it until it flags only genuinely
   mixed rooms, and consider whether `mixed` should be measured on the
   background region only (excluding the segmented subject) to kill the content
   confound.
2. **Lower `clutterReference`** (or `clutterBusy`) so `BackgroundCoach` can fire
   at all — currently it is dead weight on portraits.
3. **Reconsider the colour weight or the mixed-light score** so a
   low-confidence, often-unactionable signal cannot outrank focus and tilt for
   the single on-screen line.

## What still genuinely needs the phone

- Every number in the table re-measured on live preview frames in a real salon.
- `LevelCoach` entirely: CoreMotion has no reading here, and the tilt **sign
  convention** (`"tilted right"` vs `"left"`) is flagged unverified in the source.
- `autoCaptureHoldSeconds`, `analysisFPS`/`heavyFPS` cadence, thermal/perf.
- The composed Step-2 UI over a live preview (never seen; surfaces were only
  rendered standalone).
- Whether the readiness ring *feels* right, which no bench can answer.
