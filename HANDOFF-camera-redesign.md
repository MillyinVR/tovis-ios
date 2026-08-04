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
| **Camera outside a session** | this branch | The footer's centre button stops being dead when no session is live. Same camera, same coach, no custody. See below. |

Still owed: the on-device tune pass proper (`BACKLOG.md` §"Camera on-device tune
pass") — perception thresholds need the sensor, and the simulator has no camera.

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
