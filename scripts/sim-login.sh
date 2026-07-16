#!/usr/bin/env bash
#
# sim-login.sh — build, install, and launch the app in the simulator ALREADY
# SIGNED IN, so an iOS screen can actually be looked at.
#
# ## Why this exists
# Local sign-in is broken by design, not by bug: `POST /api/v1/auth/login` looks a
# user up by `emailHashV2` (a PII-keyring HMAC), so the seeded `client@tovis.app`
# 401s under a different `PII_LOOKUP_HMAC_KEYS_JSON` — and resetting the password
# does NOT help, because the lookup fails before the password compare. Native auth
# is bearer-token/Keychain, so there's no cookie to paste either. Four parity-epic
# steps in a row shipped iOS screens that were build-green and unit-tested but
# NEVER visually confirmed, always for this reason.
#
# `getCurrentUser` accepts any correctly-signed bearer token, so we mint one and
# hand it to the app at launch (`TovisKit/Auth/DebugSessionSeed.swift`).
#
# ## Usage
#   scripts/sim-login.sh                          # client@tovis.app on iPhone 17 Pro
#   scripts/sim-login.sh --email pro@tovis.app
#   scripts/sim-login.sh --device 'iPhone 16'
#   scripts/sim-login.sh --signout                # clear the session, land signed-out
#   scripts/sim-login.sh --no-build               # reuse the last Debug build
#
# Requires the local stack: `docker start tovis-dev-postgres` + `pnpm dev` in
# ~/Dev/tovis-app (Debug builds point at http://localhost:3000 — see TovisConfig).
#
# ## Safety
# Debug only, twice over: the token minter hard-refuses any non-local database,
# and the app-side seed lives entirely behind `#if DEBUG`, so it does not exist in
# a Release binary (verified: 0 `TOVIS_DEBUG_TOKEN` strings / 0 `DebugSessionSeed`
# symbols in Release, non-zero in Debug).
set -euo pipefail

APP_REPO="${TOVIS_APP_REPO:-$HOME/Dev/tovis-app}"
BUNDLE_ID="app.tovis.Tovis"
SCHEME="Tovis"
DEVICE="iPhone 17 Pro"
EMAIL=""
SIGNOUT=0
BUILD=1

IOS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)   EMAIL="${2:?--email needs a value}"; shift 2 ;;
    --device)  DEVICE="${2:?--device needs a value}"; shift 2 ;;
    --signout) SIGNOUT=1; shift ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1 (try --help)" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;36m▸\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Mint a token (unless signing out)
# ---------------------------------------------------------------------------
TOKEN=""
if [[ "$SIGNOUT" -eq 0 ]]; then
  [[ -d "$APP_REPO" ]] || { echo "tovis-app not found at $APP_REPO — set TOVIS_APP_REPO." >&2; exit 1; }

  say "Minting a dev JWT${EMAIL:+ for $EMAIL}…"
  # `pnpm -s` + the script's stdout discipline (logs → stderr) means this
  # captures the token and nothing else.
  if [[ -n "$EMAIL" ]]; then
    TOKEN="$(cd "$APP_REPO" && pnpm -s dev:mint-jwt --email "$EMAIL")"
  else
    TOKEN="$(cd "$APP_REPO" && pnpm -s dev:mint-jwt)"
  fi
  [[ -n "$TOKEN" ]] || { echo "Minting produced no token." >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 2. Boot the simulator
# ---------------------------------------------------------------------------
say "Booting simulator: $DEVICE"
UDID="$(xcrun simctl list devices available -j \
  | python3 -c "
import json,sys
name = sys.argv[1]
data = json.load(sys.stdin)['devices']
for runtime, devices in sorted(data.items(), reverse=True):
    for d in devices:
        if d['name'] == name:
            print(d['udid']); sys.exit(0)
sys.exit('No available simulator named %r' % name)
" "$DEVICE")"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Build + install
# ---------------------------------------------------------------------------
if [[ "$BUILD" -eq 1 ]]; then
  say "Building $SCHEME (Debug)…"
  xcodebuild build \
    -project "$IOS_REPO/tovis-ios.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$UDID" \
    -quiet
fi

PRODUCTS_DIR="$(xcodebuild -project "$IOS_REPO/tovis-ios.xcodeproj" -scheme "$SCHEME" \
  -configuration Debug -destination "id=$UDID" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')"
APP_PATH="$PRODUCTS_DIR/$SCHEME.app"
[[ -d "$APP_PATH" ]] || { echo "No app at $APP_PATH — run without --no-build." >&2; exit 1; }

say "Installing $APP_PATH"
xcrun simctl install "$UDID" "$APP_PATH"

# ---------------------------------------------------------------------------
# 4. Launch with the token
# ---------------------------------------------------------------------------
# simctl forwards SIMCTL_CHILD_* to the app with the prefix stripped, which is
# how the token reaches ProcessInfo.processInfo.environment. Passing it at LAUNCH
# (rather than writing the Keychain from outside) keeps the credential out of any
# file on disk.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

if [[ "$SIGNOUT" -eq 1 ]]; then
  say "Launching signed OUT"
  SIMCTL_CHILD_TOVIS_DEBUG_SIGNOUT=1 xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
else
  say "Launching signed IN"
  SIMCTL_CHILD_TOVIS_DEBUG_TOKEN="$TOKEN" xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
fi

say "Done. If the app shows signed-out, check that 'pnpm dev' is up in $APP_REPO."
