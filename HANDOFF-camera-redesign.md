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
| **One photo required** | this branch | The camera stops reading as "shoot the whole set or you're not done". See below. |

Still owed: the on-device tune pass proper (`BACKLOG.md` §"Camera on-device tune
pass") — perception thresholds need the sensor, and the simulator has no camera.

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
  in the file header. The web's `"N photos captured"` hard plural will read
  "1 photos captured" under the one-photo norm — **a small web copy follow-up,
  not deployed, awaiting Tori's go-ahead.**

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
