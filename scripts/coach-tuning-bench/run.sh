#!/bin/bash
# Offline coach tuning bench — see docs/camera-tuning-bench.md.
#
#   scripts/coach-tuning-bench/run.sh <folder-of-photos | photo.jpg ...>
#
# Compiles the REAL Tovis perception sources against measure.swift and runs
# them over the given images on this Mac. No simulator, no device, no camera.
# Because it compiles the live sources every run, it cannot drift from what the
# camera actually does.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/coach-tuning-bench"

if [ $# -eq 0 ]; then
  echo "usage: $(basename "$0") <folder-of-photos | photo.jpg ...>" >&2
  exit 64
fi

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

# swiftc only allows top-level statements in a file literally named main.swift,
# so stage it under that name rather than saddling the repo with it.
cp "$HERE/measure.swift" "$BUILD/main.swift"

swiftc -O -swift-version 6 \
  "$ROOT/Tovis/FrameMath.swift" \
  "$ROOT/Tovis/VisionDetect.swift" \
  "$BUILD/ShotCoach.swift" \
  "$ROOT/Tovis/CoachFocusLadder.swift" \
  "$ROOT/Tovis/CoachMoment.swift" \
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

"$BUILD/bench" "$@"
