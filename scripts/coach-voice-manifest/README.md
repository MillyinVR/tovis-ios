# Coach voice manifest

Chunk 1 of the custom-coach-voices build
(`docs/design/custom-coach-voices-brief.md` in tovis-app, build plan §5). The
line-extraction pipeline — no ElevenLabs account or API key needed.

## What it does

`run.sh` compiles the **real** `Tovis/CoachVoice.swift`,
`Tovis/CoachVoicePacks.swift` and `Tovis/CoachCanonicalCopy.swift` against
`generate.swift` and runs the result on this Mac. The generated binary
instantiates the four launch packs (Hype Bestie, Straight Shooter, Editorial
Director, Drag Queen Bestie), samples `phrase(for:ctx:)` for every in-scope
`CoachMoment`, asks `CoachCanonicalCopy` the same question for the default
voice (Calm Mentor), and writes `manifest.json`: one entry per distinct line,
keyed by a content hash of its text.

The bounded dynamic segments are cross-producted too, and the app declares
them: `CoachCanonicalCopy.contexts(for:)` names every value a canonical line
varies over — `dimensionCleared`'s 7 fundamentals (`CoachCategory.spokenName`),
the 2-value QC subject, the 2-value light-match noun, `levelTilted`'s side, and
the two forms of the exposure lines. Those lists used to be hand-written in
`generate.swift`, and they drifted: this tool still said "Colour" for months
after iOS #363 made the app say "Color", so five pack lines in the committed
manifest interpolated a noun the app never produces — and `--check` stayed
green, because the stale copy was the tool's own.

Because it compiles and runs the live sources every time, the manifest
**cannot** drift from the shipping packs without either (a) a code change,
which regenerates it, or (b) `run.sh --check` catching the mismatch — wired
into CI as the `coach-voice-manifest` job.

```
scripts/coach-voice-manifest/run.sh              # regenerate manifest.json in place
scripts/coach-voice-manifest/run.sh --check       # CI: regenerate + diff, fail on drift
```

## Scope

- **In scope (43 moments):** every `CoachMoment` whose copy is static or
  varies only over a finite, real, already-shipping set of values.
- **Excluded (13 moments):** moments that wrap open-set text not known until
  runtime — a `ShotStep`'s title/hint, a trending pack's tagline, an AI
  direction line, a retake reason, a session requirement sentence, or (for
  `focusRungAdvanced`) another moment's own already-rendered line. These stay
  on system TTS permanently — brief §1, decision 4 (server-copy gap
  accepted). `manifest.json`'s `scope.excluded` lists each with its real
  call-site source.
- **Calm Mentor:** all 43 in-scope moments are covered, read out of
  `Tovis/CoachCanonicalCopy.swift`. Its `phrase(for:ctx:)` still returns `nil`
  by design — canonical sits at the BOTTOM of the vocabulary precedence
  `CoachEngine.apply` builds (look → booking → plain → room → canonical), and a
  default voice that returned text would jump the whole stack — but the words
  it defers to now live in one `(CoachMoment, CoachPhraseContext) -> String`
  table instead of as literals across eight app files, so this tool can compile
  and call them exactly as it calls a pack. Until it could, 36 of the default
  voice's 43 lines were unreadable by any tool, which meant the voice almost
  every pro is on was the one voice that could never be pre-recorded.
  `manifest.json`'s `calmMentorGap.uncoveredInScopeMoments` is now empty and
  `generate.swift` exits non-zero if it ever isn't.

Line counts as of this manifest: 95 Hype Bestie, 67 Straight Shooter, 67
Editorial Director, 69 Drag Queen Bestie, 59 Calm Mentor — 357 total.

Those numbers are **checked**, not asserted: `run.sh` passes this file to the
generator, which fails if the counts above (and the two in **Scope**) are not
the ones the run produced. `--check` used to validate `manifest.json` alone,
which is how this README came to claim "42 / 12" and "301 total" while the
pipeline produced 43 / 13 and 305.

## Manifest shape

```jsonc
{
  "schemaVersion": 1,
  "scope": { "inScope": [...], "excluded": [{ "moment": "...", "reason": "..." }] },
  "calmMentorGap": { "coveredMoments": [...], "uncoveredInScopeMoments": [...], "note": "..." },
  "lines": [
    {
      "id": "38c180b6052c8360",        // sha256(text), first 16 hex chars
      "personality": "dragQueenBestie",
      "moment": "lightingBlownOut",
      "variantIndex": 0,
      "ctx": {},                        // e.g. {"subjectNoun": "reference"} for bounded-domain moments
      "text": "Honey, you're washed out — step back from that light, it's too much!"
    }
  ]
}
```

`id` is a content hash of `text` alone (matching the brief's
`audio/v{N}/{personality}/{contentHash}.m4a` layout, where `personality`
already scopes the directory) — a copy edit to one line changes only that
line's `id`, so chunk 2's batch generation can regenerate just the hashes
that are missing on disk rather than the whole catalog.

## Why sampling instead of refactoring the packs

`pick()` in `CoachVoicePacks.swift` is `lines.randomElement()!` on an inline
array literal — there's no addressable array to read from outside. Rather
than refactor ~280 lines of hand-tuned character copy into a `static let
[CoachLine]` shape (the brief's original suggestion, and still an option
later), this tool discovers the full variant set by sampling
`phrase(for:ctx:)` 1000 times per `(personality, moment, ctx)` and collecting
distinct non-nil results. At the variant counts these packs actually use
(2–4), the odds of missing a real variant are astronomically small
(worst case ≈ 4×(3/4)¹⁰⁰⁰ ≈ 10⁻¹²⁴), and it means this pipeline needed **zero
changes** to the shipping pack files — lower risk than a refactor, and it
runs the exact function that ships, not a description of it. Variants are
sorted before `variantIndex` is assigned so output stays deterministic
across runs regardless of sampling order.

## Why `swiftc` directly, not an SPM tool

`CoachVoice.swift`/`CoachVoicePacks.swift`/`CoachCanonicalCopy.swift` live in the `Tovis` app target,
not the `TovisKit` package — an SPM executable can't depend on an app
target the way it depends on a package library. Moving these files into
TovisKit (and making their types `public`) is a real option but a much
bigger, riskier change for a chunk whose only job is extraction. This
mirrors `scripts/coach-tuning-bench/run.sh`'s existing convention instead:
compile the real sources directly with `swiftc`, brace-matching out the one
extra type each file needs (`CoachCategory` from `ShotCoach.swift`,
`CoachPersonality` from `CoachSettings.swift`) so the tool doesn't drag in
TovisKit or SwiftUI. `CoachCanonicalCopy.swift` is Foundation-only for exactly
this reason — an `import SwiftUI` there breaks this tool and
`scripts/coach-tuning-bench` together.

## Next (chunk 2, not built here)

Reads `manifest.json`, calls the ElevenLabs batch API once per line not
already present on disk (keyed by `id`), writes AAC output to
`audio/v{N}/{personality}/{id}.m4a`.
