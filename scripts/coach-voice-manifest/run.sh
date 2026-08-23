#!/bin/bash
# Coach voice line-extraction pipeline — chunk 1 of
# docs/design/custom-coach-voices-brief.md (tovis-app repo).
#
#   scripts/coach-voice-manifest/run.sh              # regenerate manifest.json in place
#   scripts/coach-voice-manifest/run.sh --check       # regenerate to a temp file, diff
#                                                      # against the committed manifest.json,
#                                                      # fail if they differ (drift guard, CI)
#
# Compiles the REAL Tovis/CoachMoment.swift (the CoachMoment vocabulary),
# Tovis/CoachVoice.swift and Tovis/CoachVoicePacks.swift
# against generate.swift and runs the result on this Mac. No simulator, no
# device. Same technique as scripts/coach-tuning-bench/run.sh: because it
# compiles the live sources every run, the manifest cannot drift from what
# the app actually says without either a code change (which regenerates the
# manifest) or this check catching the mismatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/coach-voice-manifest"
COMMITTED="$HERE/manifest.json"

CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# CoachVoice.swift's `extension CoachCategory { goodMoment; canonicalGoodPhrase }`
# needs CoachCategory's declaration to compile. The real one lives in
# ShotCoach.swift, which pulls in TovisKit + the whole perception stack for
# the REST of that file. Extract just the enum (brace-matched, same
# technique as coach-tuning-bench's ShotExpectations shim) so this stays a
# small, fast compile and the declaration can never go stale behind our back.
awk '
  /^enum CoachCategory/ { inblock = 1 }
  inblock {
    print
    opens = gsub(/\{/, "{")
    closes = gsub(/\}/, "}")
    depth += opens - closes
    if (seen && depth == 0) exit
    if (opens > 0) seen = 1
  }
' "$ROOT/Tovis/ShotCoach.swift" > "$BUILD/CoachCategoryShim.swift"

if ! grep -q "^enum CoachCategory" "$BUILD/CoachCategoryShim.swift"; then
  echo "error: could not extract CoachCategory from Tovis/ShotCoach.swift" >&2
  exit 1
fi

# The CoachVoice protocol's `id: CoachPersonality` needs that enum too. The
# real one lives in CoachSettings.swift, which imports SwiftUI and defines a
# whole @Observable settings class alongside it — extract just the enum
# (same brace-matching technique) rather than pull SwiftUI into this tool.
awk '
  /^enum CoachPersonality/ { inblock = 1 }
  inblock {
    print
    opens = gsub(/\{/, "{")
    closes = gsub(/\}/, "}")
    depth += opens - closes
    if (seen && depth == 0) exit
    if (opens > 0) seen = 1
  }
' "$ROOT/Tovis/CoachSettings.swift" > "$BUILD/CoachPersonalityShim.swift"

if ! grep -q "^enum CoachPersonality" "$BUILD/CoachPersonalityShim.swift"; then
  echo "error: could not extract CoachPersonality from Tovis/CoachSettings.swift" >&2
  exit 1
fi

# swiftc only allows top-level statements in a file literally named
# main.swift, so stage it under that name rather than saddling the repo
# with it.
cp "$HERE/generate.swift" "$BUILD/main.swift"

swiftc -O -swift-version 6 \
  "$BUILD/CoachCategoryShim.swift" \
  "$BUILD/CoachPersonalityShim.swift" \
  "$ROOT/Tovis/CoachMoment.swift" \
  "$ROOT/Tovis/CoachVoice.swift" \
  "$ROOT/Tovis/CoachVoicePacks.swift" \
  "$BUILD/main.swift" \
  -o "$BUILD/generate" 2>&1 | grep -v "warning: 'nonisolated(unsafe)' is unnecessary" || true

if [ ! -x "$BUILD/generate" ]; then
  echo "error: manifest generator failed to compile" >&2
  exit 1
fi

if [ "$CHECK" -eq 1 ]; then
  OUT="$BUILD/manifest.json"
  "$BUILD/generate" "$OUT"
  if [ ! -f "$COMMITTED" ]; then
    echo "error: $COMMITTED does not exist — run without --check to generate it" >&2
    exit 1
  fi
  if ! diff -u "$COMMITTED" "$OUT" > "$BUILD/diff.txt"; then
    echo "error: scripts/coach-voice-manifest/manifest.json is stale — the packs changed" \
         "without regenerating it. Run scripts/coach-voice-manifest/run.sh and commit the result." >&2
    cat "$BUILD/diff.txt" >&2
    exit 1
  fi
  echo "manifest.json is up to date."
else
  "$BUILD/generate" "$COMMITTED"
  echo "wrote $COMMITTED"
fi
