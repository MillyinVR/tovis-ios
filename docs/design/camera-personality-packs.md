# Camera coaching personality packs — design doc

**Status:** scoping only. No camera code changes in this PR — this document and
its inventory/architecture/sample-copy/estimate are the entire deliverable.
Approved direction, 2026-08-05: user-selectable coach personalities that change
**tone only**.

## 0. The guardrail, restated as a test

> Personalities never change advice, timing thresholds, or metering logic —
> only phrasing, energy, and chattiness level.

Concretely: for any given frame, the *set of things wrong with the shot*, the
*single tip chosen to show*, and the *moment auto-capture fires* must be
byte-for-byte identical regardless of which personality is active. Only the
**string rendered for that decision** may vary. §3 below is built around
making that an architectural guarantee, not a convention someone has to
remember.

---

## 1. Current-state inventory — where coach copy originates

All paths are in `Tovis/` (the main app target) unless noted; TovisKit's
`CameraCalibration/` module holds only color-matrix/white-balance math, no
user-facing copy.

### 1.1 The coaching pipeline (perception → decision, no copy yet)

| Piece | File | What it does |
|---|---|---|
| Per-dimension evaluators | `Tovis/ShotCoach.swift` | `protocol ShotCoach { func evaluate(_ ctx: FrameContext) -> CoachSignal }`; seven concrete structs, one per `CoachCategory` (lighting, composition, sharpness, background, pose, level, color) |
| Aggregation | `Tovis/ShotCoach.swift` — `enum CoachAggregate` | Weighted readiness + single `Verdict` from all seven signals |
| Tip arbitration | `Tovis/ShotCoach.swift` — `struct CoachTipArbiter` | Dwell/margin state machine deciding which tip "holds the line" across frames |
| Frame analysis + delivery | `Tovis/CoachEngine.swift` — `CoachAnalyzer`, `CoachEngine` (`@MainActor @Observable`) | Runs Vision/CoreImage per frame, publishes `readiness`/`nudge`/`statuses`, drives haptics (`tap(_:)`) and speech (`speak(_:priority:)`), tracks auto-capture hold (`holdProgress`, `isSteadyReady`) |
| Every threshold | `Tovis/CoachTuning.swift` | `lumaTooDark`, `tiltBadDegrees`, `tipDwellSeconds`, `autoCaptureHoldSeconds`, `readyThreshold`, etc. — **no copy; this file must not change for this feature** |
| Auto-capture arming | `Tovis/GuidedCaptureArm.swift` | Pure state machine, no copy |
| On-screen lane arbitration | `Tovis/CameraCoachLane.swift` — `enum CameraLane` | Single-occupant priority pick across ~8 candidate messages (coach tip is only one of them) |

### 1.2 Every place a user-facing coach STRING is built

Copy exists in **nine independent locations**, each with its own inline
literals — there is no `CoachCopy.swift` and no localization catalog (the
pipeline is English-only, hardcoded today):

**A. Per-dimension correction copy — `Tovis/ShotCoach.swift`.** Each
`ShotCoach.evaluate` returns `CoachSignal(score:message:why:)` with literals
inline:
- `LightingCoach` (:436–493) — `"Light's behind them — turn them to face the window"`, `"Their face is too dark — turn them toward the light"` / `"Too dark — move toward the light"`, `"Their face is blown out — turn away from the bright light"` / `"Blown out — turn away from the bright light"`
- `CompositionCoach` (:506–595) — `"Move in closer — fill the frame"`, `"Too tight — step back a touch"`, `"Leave a little headroom — lower the camera"`, `"Raise the camera — subject's too low"`, `"Center your subject"`, etc.
- `SharpnessCoach` (:602–623) — `"Hold steady — shot looks soft"`, `"Tap to focus — a touch soft"`
- `BackgroundCoach` (:629–647) — `"Busy background — find a cleaner backdrop"`
- `PoseCoach` (:687–757) — `"Subject's getting clipped — pull back"`; also surfaces `PoseRule.tip`, which is **server-driven** copy from a trending shot pack (via `ShotGuide.init(pack:)` / `ProShotPacks.swift`) — not ours to author, must stay pack-neutral
- `LevelCoach` (:764–786) — `"Camera's tilted \(dir) — straighten it"`, `"Almost level — straighten up"`
- `ColorCoach` (:799–825) — `"Mixed light — turn off the overheads"`, `"Greenish light — switch to one clean source"`, `"Warm/yellow light — daylight reads truer"`

**B. Success/clear copy — `Tovis/CoachEngine.swift:492`.** `speak("\(cleared.spokenName) — got it", priority: .tip)`, spoken when a dimension clears.

**C. Lane banner text — `Tovis/CameraCoachLane.swift`, `CameraLane.message(_:)` (:157–246).** The single biggest concentration of literals — a priority switch:
`"1 photo can't be saved here"` / `"\(n) photos can't be saved here"`,
`"1 photo waiting on signal"` / `"\(n) photos waiting on signal"`,
`"1 keeper from that burst"` / `"\(n) keepers from that burst"`,
`"Light's changed — re-scan the card"`,
**`"That's the full set — beautiful work"`** (the "great shot" celebration line),
**`"Hold it — shooting"`** (the closest thing to a countdown — no numeric "3…2…1", just this line plus the `holdProgress` ring).
Also: `spokenName`/`shortLabel` per category (:266–293) for VoiceOver and pill labels, and `accessibilityValue(...)` (:252–263).

**D. "Good"/passing phrasing — `Tovis/CameraDrawers.swift`, `DimensionsDrawer.goodPhrase(_:)` (:119–129).** `"Good light"`, `"Colour is true"`, `"Level"`, `"Framed"`, `"Sharp"`, `"Background is clean"`, `"Pose reads"` — entirely separate from A's failure copy.

**E. Post-capture QC retake copy — `Tovis/PhotoQC.swift:120–133`.** `"Their eyes were closed"`, `"It came out soft"`, `"\(subject) came out too dark"`, `"\(subject) came out blown out"` — a separate inline `if/else if` chain.

**F. Before/after light-match copy — `Tovis/BeforeShotMeasure.swift`, `enum LightMatch` (:118–158).** `"Light matches the \(noun)"`, `"Brighter than the \(noun) — dim a touch"`, etc.

**G. Directed-shoot step copy — `Tovis/ShotGuide.swift`.** `ShotStep.title`/`.hint` catalogs (five hardcoded, e.g. `.generic`, `.hair`, `.nails`) plus server-driven packs.

**H. Spoken directives + inline UI copy — `Tovis/ProCapturePhotosView.swift`** (2500+ lines, the camera screen). `coach?.announce(...)` call sites (`"Next, the \(step.title). \(step.hint)"` :448, `"Got the \(title)."` :1389, trending-pack intros :1516/1531/1569) plus dozens more inline literals for calibration status, error banners, exit-dialog copy, and the settings toggle labels themselves.

**I. Session framing copy — `Tovis/ProCameraDestination.swift`.** `guideNote(requirementMet:)`, `leavingWithoutTitle`, `outstandingSentence`.

### 1.3 Test exposure

`TovisTests/CoachReadinessTests.swift` and `TovisTests/CoachTipArbiterTests.swift`
assert on **literal string equality** (e.g. `signal.message == "Light's behind
them — turn them to face the window"`). Any refactor must keep the default
pack's rendered output byte-identical to today's strings, or these pinned
tests break for reasons that have nothing to do with coaching correctness.

### 1.4 Existing persistence pattern

No SwiftData/CoreData anywhere in the app. `Tovis/CoachSettings.swift` is an
`@Observable final class CoachSettings` where every property has `didSet {
persist(...) }`, keyed via `key(_ name: String) -> String { "tovis.coach.\(name)"
}`, read back in `init()` via `UserDefaults.standard.object(forKey:) ?? default`.
It's device-local, un-synced, and already owns *how the coach communicates*
(`speak`, `haptics`, `showNudge`) rather than *what it measures* — the natural
home for a `personality` preference. There is no server-synced pro-preferences
model for camera behavior yet (`ProProfile.swift`/`ProProfileService.swift`
hold profile/portfolio data, not coaching preferences).

### 1.5 Existing settings UI

`CoachSettingsSheet` (private struct, `Tovis/ProCapturePhotosView.swift:2438`)
is the full "All coaching settings" screen — a SwiftUI `Form` with `Section`s
of `Toggle`s bound to `CoachSettings` (`"How it guides you"`, `"On the
camera"`, `"AI analysis"`). It's reached from `CameraToolsDrawer`
(`Tovis/CameraDrawers.swift:136`, the tools tray) via an `"All coaching
settings"` row. This is where a personality picker belongs.

---

## 2. Architecture

### 2.1 The seam: a copy-transform layer downstream of decisions

The trigger/decision pipeline (§1.1: `ShotCoach.evaluate` → `CoachAggregate`
→ `CoachTipArbiter` → `GuidedCaptureArm`) keeps deciding *what's wrong* and
*when to act*, unchanged, and keeps returning today's Calm Mentor strings as
its canonical `message`/`why` — this is what keeps `CoachReadinessTests.swift`
and `CoachTipArbiterTests.swift` green with zero edits. A new **moment
identifier** rides alongside the canonical string; a new **rendering layer**
looks up the active pack's line for that moment at the three places copy
actually reaches the user. If a pack has no override for a moment (mid-rollout
gap, or a moment intentionally left pack-neutral like `PoseRule.tip`), the
renderer falls back to the canonical string — never a blank or a crash.

```swift
// New: a stable tag alongside each canonical signal — one case per
// literal enumerated in §1.2.A–D. Hashable, no associated copy.
enum CoachMoment: Hashable {
    case lightingBacklit, lightingTooDark, lightingBlownOut
    case compositionTooClose, compositionTooFar, compositionOffFrame
    case compositionNoHeadroom, compositionTooLow, compositionRecenter
    case sharpnessHoldSteady, sharpnessTapToFocus
    case backgroundBusy
    case poseClipped                      // poseServerTip stays pack-neutral, not in this enum
    case levelTilted, levelAlmostLevel
    case colorMixed, colorGreenish, colorWarm
    case goodLighting, goodColor, goodLevel, goodFraming
    case goodSharpness, goodBackground, goodPose
    case laneHoldShooting, laneSetComplete, laneCalibrationDrift
    case dimensionCleared
}

// CoachSignal gains a tag; message/why are UNCHANGED (still Calm Mentor text,
// still what the pinned tests assert on).
struct CoachSignal {
    var score: Double
    var message: String?     // unchanged — canonical / fallback text
    var why: String?         // unchanged
    var moment: CoachMoment? // NEW
}

protocol CoachVoice {
    var id: CoachPersonality { get }
    var displayName: String { get }
    var chattiness: CoachChattiness { get }
    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String?
    func includesWhy(for moment: CoachMoment) -> Bool
}

// Interpolation payload — covers every \(...) seen in §1.2 (direction, noun,
// subject, count) without each pack needing to know FrameContext internals.
struct CoachPhraseContext {
    var direction: String?
    var subjectNoun: String?
    var count: Int?
}

enum CoachChattiness { case minimal, standard, expressive }

// The only place a moment turns into on-screen/spoken text.
enum CoachVoiceRenderer {
    static func render(_ moment: CoachMoment?, fallback: String?,
                        ctx: CoachPhraseContext, voice: CoachVoice) -> String? {
        guard let moment else { return fallback }
        return voice.phrase(for: moment, ctx: ctx) ?? fallback
    }
}
```

`CalmMentorVoice: CoachVoice` is a byte-identical port of today's strings —
its purpose is to validate the seam with **zero user-visible change**, and it
becomes the reference the other four packs are diffed against for coverage.

### 2.2 Render sites (where `CoachVoiceRenderer` gets called)

Only three call sites change, all at the "final mile" between decision and
display — nothing upstream of them:

1. `CoachEngine.speak(...)` (`CoachEngine.swift`) — render before calling `AVSpeechSynthesizer`
2. `CameraCoachLane.message(_:)` (`CameraCoachLane.swift:157`) — render the winning candidate's text before it becomes `LaneMessage.text`
3. `DimensionsDrawer` rendering (`CameraDrawers.swift:84–129`) — render `status.message`/`.why` and `goodPhrase(_:)` per row

`ShotCoach.evaluate`, `CoachAggregate`, `CoachTipArbiter`, `CoachTuning`, and
`GuidedCaptureArm` are untouched. This is what makes "tone only" enforceable
rather than a promise: nothing about *what* is decided is reachable from a
`CoachVoice` implementation.

### 2.3 Chattiness dial

Not a separate user-facing control — it's intrinsic to each pack
(`CoachChattiness`: Straight Shooter = `.minimal`, Calm Mentor / Editorial
Director = `.standard`, Hype Bestie / Drag Queen Bestie = `.expressive`). It
governs three things, none of which touch `CoachTuning` timing:

- Whether `why` is spoken/shown alongside the fix (`includesWhy(for:)`) — minimal packs skip it by default, expressive packs usually include it
- Whether celebration moments get a flavor tail appended
- The speech min-repeat-interval already present in `CoachEngine.speak(priority:)` — expressive packs can use a shorter interval so the voice doesn't feel sparse, minimal packs a longer one. This paces *which line gets spoken*, never *when a trigger fires* — dwell timers and thresholds in `CoachTuning` stay pack-agnostic.

### 2.4 Persistence

Extend `CoachSettings.swift` with the same property-plus-`didSet`-persist
pattern already used for every other toggle, same `tovis.coach.*` namespace:

```swift
enum CoachPersonality: String, CaseIterable, Identifiable {
    case calmMentor, hypeBestie, straightShooter, editorialDirector, dragQueenBestie
    var id: String { rawValue }
}

// inside CoachSettings
var personality: CoachPersonality = .calmMentor {
    didSet { persist("personality", personality.rawValue) }
}
```

Device-local, un-synced — matching every existing coach toggle. Syncing the
selection across a pro's devices via `ProProfile` is a plausible Phase 2 but
isn't needed for launch, since no other coach preference syncs today either.

### 2.5 Settings UI

Add a `Section` to `CoachSettingsSheet` (`ProCapturePhotosView.swift:2438`),
alongside `"How it guides you"`:

```swift
Section {
    Picker("Coach personality", selection: $settings.personality) {
        ForEach(CoachPersonality.allCases) { p in Text(p.displayName).tag(p) }
    }
} header: {
    Text("Coach voice")
} footer: {
    Text("Changes tone only — the same corrections, at the same moments, in a different voice.")
}
```

A one-line live preview under the picker (rendering, say, `.laneSetComplete`
in the newly-selected pack) is a cheap, high-value addition — lets a pro
taste-test before committing.

### 2.6 Refactor required to centralize strings

In priority order (matches §1.2, A–D are required for launch; E–I are a
follow-up, §4 Phase 4):

1. Tag all seven `ShotCoach.evaluate` implementations with `CoachMoment` cases (message/why text unchanged)
2. Tag `CameraCoachLane.message(_:)`'s switch cases, at minimum `laneHoldShooting` and `laneSetComplete` (the two moments called out for sample copy below)
3. Tag `DimensionsDrawer.goodPhrase(_:)`'s seven cases
4. Build `CoachVoice` / `CoachPhraseContext` / `CoachVoiceRenderer` and wire the three render sites (§2.2)
5. Port today's strings into `CalmMentorVoice`, verify existing pinned tests still pass unmodified

E–I (`PhotoQC`, `BeforeShotMeasure`, `ShotGuide`, the `ProCapturePhotosView`
announce/error/dialog copy, `ProCameraDestination`) stay on Calm Mentor only
at launch — they're lower-frequency, higher-surface-area, and not part of the
five moments Tori asked to hear sample copy for. Bringing them into the
personality system later is mechanical (same tag-and-render pattern) but adds
real copywriting volume across all five packs.

### 2.7 Test impact

- No change needed to `CoachReadinessTests.swift` / `CoachTipArbiterTests.swift` — they assert on `ShotCoach.evaluate`'s `message`, which stays canonical Calm Mentor text.
- New: a coverage test per pack — every `CoachMoment` case has a non-nil `phrase(for:ctx:)`, so no pack silently falls back to Calm Mentor text on a moment it "should" own.
- New: a guardrail test — running the full `FrameContext` fixture set through `CoachAggregate`/`CoachTipArbiter` with each of the five `CoachSettings.personality` values selected produces identical `CoachResult`s (readiness, chosen moment, hold timing) — only the rendered string differs. This is the test that actually enforces §0.

---

## 3. Sample copy

Five moments, matching the ones called out in scope: too-dark lighting, tilt
correction, hold-still/auto-capture, great-shot celebration, backlit warning.
3–5 lines each, per personality — these are illustrative pack content, not a
final locked script; whichever a pack ends up shipping still routes through
the same `CoachMoment` (so QA can always confirm advice/timing didn't move).

### Calm Mentor (current voice, default)

**Too dark**
- "Their face is too dark — turn them toward the light."
- "Too dark — move toward the light."
- "A little more light on their face would help."

**Tilt correction**
- "Camera's tilted left — straighten it."
- "Almost level — straighten up."
- "Level the horizon before you shoot."

**Hold-still / auto-capture**
- "Hold it — shooting."
- "Steady… almost there."
- "Hold still, just a moment more."

**Great-shot celebration**
- "That's the full set — beautiful work."
- "Nice set. Every shot's a keeper."
- "That's a wrap — great work."

**Backlit warning**
- "Light's behind them — turn them to face the window."
- "They're backlit — turn toward the light source."
- "Too much light behind them — reposition."

### Hype Bestie (high energy, celebratory)

**Too dark**
- "Ooh it's giving shadow realm — walk them toward that light!"
- "Bestie it's too dark, let's find some glow!"
- "A lil dark! Chase the light with me!"
- "We need more light on that face, let's gooo!"

**Tilt correction**
- "We're tilting! Straighten up, we almost had it!"
- "So close to level — just a nudge!"
- "Level it out and it's PERFECT."

**Hold-still / auto-capture**
- "Hold it… hold it… YES, capturing!"
- "Don't move, don't move — this is the one!"
- "Steady steady steady — we're shooting!"

**Great-shot celebration**
- "OKAY that's the full set, we ATE."
- "Every. Single. Shot. A whole keeper. Let's gooo!"
- "That's a wrap and it's iconic."
- "Full set, full glow — we're done, we're legendary."

**Backlit warning**
- "Bestie the light's behind them, spin them around!"
- "Backlit! Turn toward that window, chase the glow!"
- "Too much light behind — let's flip the script!"

### Straight Shooter (terse, corrections only)

**Too dark**
- "Too dark. Move to light."
- "Face needs light."
- "More light, face side."

**Tilt correction**
- "Tilted. Straighten."
- "Level it."
- "Off-level."

**Hold-still / auto-capture**
- "Hold."
- "Steady."
- "Don't move."

**Great-shot celebration**
- "Set complete."
- "Done. Good set."
- "All seven. Good."

**Backlit warning**
- "Backlit. Turn to light."
- "Light's behind. Reposition."
- "Flip toward the source."

### Editorial Director (fashion-shoot vibe, composed)

**Too dark**
- "We're losing the face in shadow — bring them into the light."
- "Light needs to hit the face. Reposition toward the source."
- "Too much shadow on the subject — move them into the light."

**Tilt correction**
- "The horizon's off — straighten the frame."
- "Almost level. Tighten the line."
- "Level the camera before we lock this shot."

**Hold-still / auto-capture**
- "Hold the frame. We're taking it."
- "Steady… locking focus… now."
- "Hold — this is the shot."

**Great-shot celebration**
- "That's the set. Clean, consistent, done."
- "Full set, every frame on brand. Beautiful."
- "That's a wrap — this set is publication-ready."

**Backlit warning**
- "They're backlit — turn them into the light source."
- "Too much light behind the subject. Reposition toward the window."
- "Flip them — we need the light on the face, not behind it."

### Drag Queen Bestie (campy, fabulous, confident and affectionate — never mean)

**Too dark**
- "Mama, the shadows are eating your face — strut toward that light!"
- "It's giving dark room energy, and not the fun kind — find your light, honey!"
- "The light is not hitting right — turn toward the glow, gorgeous."
- "We need illumination on that face card, baby — chase the light!"

**Tilt correction**
- "The camera's tipping like it had one too many — level it, honey!"
- "Ooh, we're leaning! Straighten up like you're walking the runway."
- "Almost level, baby — just a hair more and it's flawless."

**Hold-still / auto-capture**
- "Hold that pose, don't you dare move — we're capturing greatness."
- "Freeze, baby! This is the moment, hold it!"
- "Steady, steady… and captured. You better work."

**Great-shot celebration**
- "That is the full set and every single shot served. You better work!"
- "Category is: photographed to perfection. We are done, baby!"
- "That's a wrap, and honey, it was flawless from frame one."
- "Full set, full fabulous — you ate that, no crumbs left!"

**Backlit warning**
- "The light's sneaking up behind you, baby — turn and face your glow!"
- "You're backlit, gorgeous — spin toward that light source!"
- "That light's behind you like a bad ex — turn around and claim it!"

---

## 4. Scope estimate

Rough breakdown, one engineer, sequential (Phase 1 must land before 2–4 can
start; 2 and 3 can overlap with a copywriter drafting packs while the seam is
built).

| Phase | Work | Est. |
|---|---|---|
| **0 — Foundation refactor** | `CoachMoment` enum; tag all `ShotCoach.evaluate` sites + `CameraCoachLane.message` + `DimensionsDrawer.goodPhrase`; build `CoachVoice`/`CoachPhraseContext`/`CoachVoiceRenderer`; port `CalmMentorVoice` byte-identical; confirm pinned tests unchanged | 3–4 days |
| **1 — Packs** | Author + wire the four new voices against the full `CoachMoment` case list; tone-review pass (ideally with Tori) | 2–3 days |
| **2 — Settings + persistence** | `CoachPersonality` enum, `CoachSettings.personality` + UserDefaults persistence, picker + live-preview UI in `CoachSettingsSheet` | 1–2 days |
| **3 — Tests + QA** | Per-pack coverage test, cross-pack guardrail test (§2.7), manual device pass per pack across all five moments | 1–2 days |
| **Total (launch scope, A–D only)** | | **~7–11 days (~1.5–2 weeks)** |
| **4 — Follow-up (not in launch scope)** | Extend moment-tagging to `PhotoQC`, `BeforeShotMeasure`, `ShotGuide` step copy, `ProCapturePhotosView` spoken announcements/dialogs, `ProCameraDestination` — so personality is consistent across the *entire* camera experience, not just the live coaching loop | separately scoped; meaningfully more copywriting volume across all five packs than launch scope |

Biggest risk to the estimate is Phase 0's coverage — the seven `ShotCoach`
structs plus the lane switch have more literal branches than the five sample
moments above (see §1.2's full literal list), so tagging every branch with a
`CoachMoment` case is more mechanical work than it is design work, but it's
still work that has to happen before any pack beyond Calm Mentor can ship
without silent fallback gaps.
