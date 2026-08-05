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

# ShotCoach.swift's FrameContext references ShotExpectations, which lives in
# ShotGuide.swift — and that file imports TovisKit, which would drag the whole
# package in. Extract just the struct (brace-matched) so the bench stays a
# four-file compile and the declaration can never go stale behind our back.
awk '
  /^struct ShotExpectations/ { inblock = 1 }
  inblock {
    print
    opens = gsub(/\{/, "{")
    closes = gsub(/\}/, "}")
    depth += opens - closes
    if (seen && depth == 0) exit
    if (opens > 0) seen = 1
  }
' "$ROOT/Tovis/ShotGuide.swift" > "$BUILD/ShotExpectationsShim.swift"

if ! grep -q "^struct ShotExpectations" "$BUILD/ShotExpectationsShim.swift"; then
  echo "error: could not extract ShotExpectations from Tovis/ShotGuide.swift" >&2
  exit 1
fi

# swiftc only allows top-level statements in a file literally named main.swift,
# so stage it under that name rather than saddling the repo with it.
cp "$HERE/measure.swift" "$BUILD/main.swift"

swiftc -O -swift-version 6 \
  "$ROOT/Tovis/FrameMath.swift" \
  "$ROOT/Tovis/VisionDetect.swift" \
  "$ROOT/Tovis/ShotCoach.swift" \
  "$ROOT/Tovis/CoachTuning.swift" \
  "$ROOT/Tovis/PublishCrop.swift" \
  "$BUILD/ShotExpectationsShim.swift" \
  "$BUILD/main.swift" \
  -o "$BUILD/bench" 2>&1 | grep -v "warning: 'nonisolated(unsafe)' is unnecessary" || true

if [ ! -x "$BUILD/bench" ]; then
  echo "error: bench failed to compile" >&2
  exit 1
fi

"$BUILD/bench" "$@"
