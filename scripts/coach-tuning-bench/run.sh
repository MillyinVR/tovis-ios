#!/bin/bash
# Offline coach tuning bench — see docs/camera-tuning-bench.md.
#
#   scripts/coach-tuning-bench/run.sh <folder-of-photos | photo.jpg ...>
#   scripts/coach-tuning-bench/run.sh --compile-only   # build against the live sources, run nothing
#   scripts/coach-tuning-bench/run.sh --selftest       # build + run + diff against the pinned baseline (CI)
#   scripts/coach-tuning-bench/run.sh --update-baseline # accept the current output as the new pin
#
# Compiles the REAL Tovis perception sources against measure.swift and runs
# them over the given images on this Mac. No simulator, no device, no camera.
# Because it compiles the live sources every run, it cannot drift from what the
# camera actually does.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/coach-tuning-bench"
BASELINE="$HERE/selftest-baseline.txt"

# `--compile-only` and `--selftest` exist because this bench is not something
# CI could re-measure. Its real corpus is 35 photographs out of an installed
# simulator runtime; those are Apple's files, this repo is public, and a hosted
# runner has a different runtime anyway, so "check the numbers" is not on
# offer. What IS on offer is the failure that actually happened, twice, and
# both times silently: the bench stopped COMPILING. `ShotExpectations` moved
# out of the file this script brace-matched it from (found 2026-08-23, after
# rotting ~19 days), and #360 added a source the hand-maintained list below did
# not know about. Neither showed up until a person happened to run it.
#
#   --compile-only    builds every source in the list and stops. Needs no corpus.
#   --selftest        does that, then generates deterministic synthetic frames,
#                     runs the whole path over them, and DIFFS the result
#                     against selftest-baseline.txt.
#   --update-baseline accepts the current output as the new pin.
#
# The diff is the part that makes this more than a smoke test. Every number the
# bench prints for those frames is pinned, so a change to FrameMath, the
# coaches or CoachTuning that moves what the camera MEASURES shows up as a diff
# on the PR that moved it. That check was previously done by hand — diff the
# bench output before and after — and hand checks get skipped.
#
# 🔴 What it still does NOT do is CALIBRATION. These are synthetic gradients:
# no faces, no optics, no salon light. "0.13 is the right mixedLightSpread for
# a salon" is a question only real photographs answer, and the numbers in
# docs/camera-tuning-bench.md still come from a hand-run on the real corpus.
# Regression and calibration are different questions; this pins the first.
MODE="corpus"
case "${1:-}" in
  --compile-only)    MODE="compile" ;;
  --selftest)        MODE="selftest" ;;
  --update-baseline) MODE="update" ;;
  "")
    echo "usage: $(basename "$0") <folder-of-photos | photo.jpg ...>" >&2
    echo "       $(basename "$0") --compile-only | --selftest | --update-baseline" >&2
    exit 64
    ;;
esac

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# ShotCoach.swift's FrameContext references ShotExpectations. That type used to
# live inside ShotGuide.swift — which imports TovisKit and would drag the whole
# package in — so the bench brace-matched the struct out of it with awk. It now
# has its own framework-agnostic file (Foundation only), so the real source is
# compiled directly: one less thing between the bench and what the camera runs.
#
# The extraction is what rotted when the type moved, and it rotted SILENTLY
# until someone ran the bench (2026-08-23). Compiling the file means a move
# breaks the build loudly instead.
EXPECTATIONS="$ROOT/Tovis/ShotExpectations.swift"
if [ ! -f "$EXPECTATIONS" ]; then
  echo "error: $EXPECTATIONS not found — did ShotExpectations move again?" >&2
  exit 1
fi

# ShotCoach.swift imports TovisKit for exactly ONE symbol: `PublishCrop`, the
# crop geometry CompositionCoach judges inside. Building the whole package for
# one enum would cost minutes on every run, so the bench compiles the REAL
# PublishCrop source alongside and strips that single import from its copy of
# ShotCoach.swift. The copy is regenerated from the live file every run, so the
# only difference from what the camera compiles is the deleted import line — and
# if the camera ever reaches for a SECOND TovisKit symbol, this build fails
# loudly rather than measuring something the app doesn't do.
PUBLISH_CROP="$ROOT/TovisKit/Sources/TovisKit/SocialExport/PublishCrop.swift"
if [ ! -f "$PUBLISH_CROP" ]; then
  echo "error: $PUBLISH_CROP not found — did PublishCrop move again?" >&2
  exit 1
fi
sed '/^import TovisKit/d' "$ROOT/Tovis/ShotCoach.swift" > "$BUILD/ShotCoach.swift"

# Every coach's corrective line now comes out of Tovis/CoachCanonicalCopy.swift
# (the one home for the default voice's words) rather than a literal at the
# call site, so ShotCoach.swift does not compile without it. It is Foundation
# only for exactly this reason — this list and coach-voice-manifest's both
# compile it directly, and either would break on a SwiftUI/TovisKit import.

# swiftc only allows top-level statements in a file literally named main.swift,
# so stage it under that name rather than saddling the repo with it.
cp "$HERE/measure.swift" "$BUILD/main.swift"

swiftc -O -swift-version 6 \
  "$ROOT/Tovis/FrameMath.swift" \
  "$ROOT/Tovis/VisionDetect.swift" \
  "$BUILD/ShotCoach.swift" \
  "$ROOT/Tovis/CoachFocusLadder.swift" \
  "$ROOT/Tovis/CoachMoment.swift" \
  "$ROOT/Tovis/CoachCanonicalCopy.swift" \
  "$ROOT/Tovis/CoachBackOff.swift" \
  "$ROOT/Tovis/CoachTuning.swift" \
  "$PUBLISH_CROP" \
  "$EXPECTATIONS" \
  "$BUILD/main.swift" \
  -o "$BUILD/bench" 2>&1 | grep -v "warning: 'nonisolated(unsafe)' is unnecessary" || true

if [ ! -x "$BUILD/bench" ]; then
  echo "error: bench failed to compile" >&2
  exit 1
fi

if [ "$MODE" = "compile" ]; then
  echo "coach-tuning-bench compiles against the live sources."
  exit 0
fi

if [ "$MODE" = "selftest" ] || [ "$MODE" = "update" ]; then
  # The generator builds on its own — Foundation/CoreGraphics/ImageIO, none of
  # the app sources — so a failure here is unambiguously the harness, never the
  # thing under test.
  swiftc -O -swift-version 6 \
    "$HERE/selftest-corpus.swift" \
    -o "$BUILD/selftest-corpus" 2>&1 | grep -v "warning: 'nonisolated(unsafe)' is unnecessary" || true
  if [ ! -x "$BUILD/selftest-corpus" ]; then
    echo "error: selftest corpus generator failed to compile" >&2
    exit 1
  fi
  EXPECTED="$("$BUILD/selftest-corpus" "$BUILD/corpus")"
  echo "generated $EXPECTED synthetic frames"

  OUT="$BUILD/selftest.txt"
  "$BUILD/bench" "$BUILD/corpus" | tee "$OUT"

  # The bench prints its own count in the header. Assert it measured every
  # frame: `measure()` returns nil on a frame it cannot decode and the run
  # simply prints "(skipped …)" and carries on, so a build that decodes
  # NOTHING would otherwise print empty tables and exit 0 — green, having
  # measured nothing. Same shape as the "reported success but ran no tests"
  # guards in .github/workflows/ci.yml.
  if ! grep -q "=== Raw perception signals on $EXPECTED image(s) ===" "$OUT"; then
    echo "error: bench did not report $EXPECTED images" >&2
    exit 1
  fi
  if grep -q "(skipped " "$OUT"; then
    echo "error: the bench skipped a generated frame — it could not decode its own self-test corpus" >&2
    exit 1
  fi
  if ! grep -q -- "--- which line wins, across the corpus ---" "$OUT"; then
    echo "error: bench did not reach its final summary" >&2
    exit 1
  fi
  # Everything above proves the harness ran. THIS is the regression pin: the
  # bench's full output for these frames, byte for byte.
  if [ "$MODE" = "update" ]; then
    cp "$OUT" "$BASELINE"
    echo "wrote $BASELINE"
    exit 0
  fi

  if [ ! -f "$BASELINE" ]; then
    echo "error: $BASELINE is missing — run $(basename "$0") --update-baseline" >&2
    exit 1
  fi

  if ! diff -u "$BASELINE" "$OUT"; then
    cat >&2 <<'EOF'

error: the bench measures something different than the pinned baseline.

  If you changed FrameMath, VisionDetect, the coaches or CoachTuning, this is
  the check doing its job: read the diff above. It is the difference your
  change makes to what the camera MEASURES. If it is intended, run
  scripts/coach-tuning-bench/run.sh --update-baseline and commit the result in
  the same PR, so the change to the perception math is reviewable as a number
  rather than only as code.

  If you changed none of those and this failed only on CI, suspect the runner:
  the fill/clutter/bgLuma columns come from VNGeneratePersonSegmentationRequest,
  whose model can move when GitHub rolls the macOS image. Regenerate the
  baseline on a machine and say so in the PR — do not "fix" the coaches to
  match a runner.
EOF
    exit 1
  fi

  echo "coach-tuning-bench compiles, runs end to end, and measures what it did before."
  exit 0
fi

"$BUILD/bench" "$@"
