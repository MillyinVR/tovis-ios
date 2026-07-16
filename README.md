# Tovis iOS

Native SwiftUI app for the Tovis backend (the `tovis-app` Next.js API). Talks to
the backend purely over its versioned HTTP API (`/api/v1`) — no shared code; the
contract is the wire schema (`tovis-app/schema/api/tovis-api.schema.json`). The app
is one shell for both roles: the signed-in JWT's **acting role** (`CLIENT | PRO |
ADMIN`) picks the client vs pro tab bar. Client app is feature-complete + on
TestFlight; the pro side + AI camera are the active track (see `BACKLOG.md`).

## Two repos

| Repo | Path | Role |
|------|------|------|
| Backend | `~/Dev/tovis-app` | Next.js 16 API — the `/api/v1` surface. |
| iOS app | `~/Dev/tovis-ios` | This repo. SwiftUI app + `TovisKit` package. HTTP only. |

## Layout

```
tovis-ios/
├── TovisKit/                 ← UI-free core (local Swift Package). `swift build`/`swift test` pass.
│   └── Sources/TovisKit/
│       ├── Config/           TovisConfig — baseURL (.local=localhost / .production=www.tovis.app) + supabase creds
│       ├── Networking/       APIClient (bearer auth, 401→refresh→retry, query+headers), APIError
│       ├── Auth/             TokenStore (Keychain), AuthService (login/apple/phoneLogin/refresh/logout/switchWorkspace), SessionToken (decodes userId + acting-role from the JWT)
│       ├── Live/             SupabaseRealtime (dependency-free Phoenix ws → live-sync)
│       ├── Models/           Codable wire models mirroring /api/v1 DTOs
│       ├── Tests/            DecodingTests + Fixtures/*.json (shared with the contract test)
│       └── TovisClient.swift wires it all + a stable per-install deviceId
├── Tovis/                    ← Xcode app target (synchronized folder — files dropped here auto-add)
├── scripts/contract/         Node+ajv: validate Fixtures/*.json vs tovis-app's generated schema (see its README)
└── tovis-ios.xcodeproj       ⚠️ IPHONEOS_DEPLOYMENT_TARGET pinned to 17.0 (matches TovisKit .iOS(.v17))
```

**TovisKit services** (one per surface, all on `TovisClient`): `auth · devices · home ·
bookings · profiles · me · messages · search · booking · checkout · looks · discover ·
notifications · addresses · places` + pro services (`proSession · proCalendar`), plus
`client.currentUserId()` (decodes the JWT). Add a screen → add a service + `Models/*` +
a fixture + decode test + a contract entry. Reuse `BrandColor/BrandFont/Theme`, `LooksMark`,
the footer `NavItemLabel/BadgeDot`, `APIClient`, `Formatters`, upload helpers — **no
duplicated logic** (CLAUDE.md house rule), **web parity 1:1**.

## Backend env / DB (so the app actually loads)

- **API base URL is build-type driven** (`Tovis/ContentView.swift`): **Debug → `.local`
  (localhost:3000)**, **Release → `.production` (`https://www.tovis.app/api/v1`)**. Use
  `www.` — the apex 307-redirects and a cross-host redirect can drop the `Authorization` header.
- **Local dev DB:** `cd ~/Dev/tovis-app && pnpm dev` runs in development mode → loads
  `.env.development.local` → `DATABASE_URL=postgresql://postgres:postgres@localhost:5434/tovis_dev`
  (Docker `tovis-dev-postgres`). The iOS sim (Debug) + local web share this **local** DB; prod
  web uses prod Supabase. Start it with `docker start tovis-dev-postgres` (or `pnpm db:dev:up`).
- **If signed-in endpoints 500 with "table … does not exist"** the local schema is stale — apply
  the migrations (**never `prisma db push`**, which the house rules forbid and which would drift
  the local DB away from the migration history):
  ```bash
  cd ~/Dev/tovis-app && DATABASE_URL="postgresql://postgres:postgres@localhost:5434/tovis_dev" \
    DIRECT_URL="postgresql://postgres:postgres@localhost:5434/tovis_dev" pnpm exec prisma migrate deploy
  ```
- **⚠️ Signing in with `client@tovis.app` / `password123` DOES NOT WORK, and no password will.**
  `POST /api/v1/auth/login` looks a user up by **`emailHashV2`** — a PII-keyring HMAC — so the
  seeded client 401s `INVALID_CREDENTIALS` under a different `PII_LOOKUP_HMAC_KEYS_JSON`. The
  lookup fails *before* the password compare, so resetting the password can't help. This is a
  keyring mismatch, not a bad credential. **Use `scripts/sim-login.sh`** (below) instead.
- Release/TestFlight needs a real prod account (web signup, Apple, or phone-OTP). Native
  email/password **sign-UP** is web-only (captcha/TOS/SMS-consent/ZIP gates); Apple + phone-OTP
  are the native account-creation paths.

## Running the sim SIGNED IN (`scripts/sim-login.sh`)

Because of the keyring problem above, the simulator had **no way to reach a signed-in screen** —
four parity-epic steps in a row shipped iOS screens that were build-green and unit-tested but
never *looked at*. `getCurrentUser` accepts any correctly-signed bearer token, so we mint one and
hand it to the app at launch.

```bash
docker start tovis-dev-postgres && (cd ~/Dev/tovis-app && pnpm dev)   # the stack must be up
./scripts/sim-login.sh                      # build + install + launch, signed in as client@tovis.app
./scripts/sim-login.sh --email pro@tovis.app
./scripts/sim-login.sh --device 'iPhone 16'
./scripts/sim-login.sh --no-build           # reuse the last Debug build
./scripts/sim-login.sh --signout            # clear the session instead
```

Grab a screenshot of whatever you land on:

```bash
xcrun simctl io booted screenshot /tmp/shot.png
```

How it works: `pnpm dev:mint-jwt` (tovis-app) mints the token → `simctl launch` passes it as
`SIMCTL_CHILD_TOVIS_DEBUG_TOKEN` → `TovisKit/Auth/DebugSessionSeed.swift` reads it out of the
launch environment and seeds the Keychain before `bootstrap()` checks for a session. Passing it at
*launch* keeps the credential out of any file on disk.

**It cannot ship.** The seed is entirely `#if DEBUG`, and the minter hard-refuses any non-local
database. Verified against the built binaries: the Release binary contains **0** `TOVIS_DEBUG_TOKEN`
strings and **0** `DebugSessionSeed` symbols, where Debug has both (and a control string present in
both proves the check can fail).

## Build / verify

```bash
# iOS unit + contract
cd ~/Dev/tovis-ios/TovisKit   && swift test
cd ~/Dev/tovis-ios/scripts/contract && npm install && npm run validate   # fixtures vs backend schema

# iOS app build (real toolchain, unsigned)
cd ~/Dev/tovis-ios && xcodebuild build -scheme Tovis -project tovis-ios.xcodeproj \
  -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO
```

CLI type-check of the app target against the simulator SDK (catches SwiftUI/type errors
without a full build): emit a TovisKit simulator module, then `-typecheck` the app sources
against it (`arm64-apple-ios17.0-simulator`).

## Gotchas / lessons

- **Deployment target:** the project once shipped `IPHONEOS_DEPLOYMENT_TARGET = 27.0` (> the
  installed SDK's max) → a plain simulator build reports "Supported platforms … is empty" and
  silently produces nothing. Kept at `17.0`; watch for that message if a future Xcode bumps it.
- **Native MUST be cookieless.** The login response sets a `tovis_token` cookie for web;
  `URLSession.shared`'s shared jar would store + resend it, and the backend's CSRF gate only
  exempts native requests that carry **no cookie** → a stale cookie → `403 INVALID_ORIGIN` on the
  next login. `TovisClient` runs on a cookieless `URLSession` — don't reintroduce `.shared`.
- **Wire-contract test = the DTO-drift guard.** `scripts/contract` (ajv) validates the shared
  fixtures against tovis-app's generated schema; the same fixtures are decoded by `swift test`.
  A backend DTO change fails loudly in one of the two. ⚠️ A DTO **JSDoc-comment edit** changes the
  generated schema — the backend must re-run `npm run gen:api-schema` after any DTO edit.
- **Xcode synchronized folder:** new files in `Tovis/` join `xcodebuild` immediately, but open the
  project once so Xcode itself registers them.
- **Push/APNs** is app-wired + backend-built but needs the Xcode Push capability + operator APNs
  creds to actually fire — see `tovis-app/docs/mobile/push-go-live-runbook.md` (`APNS_ENV=production`
  for TestFlight/App Store, `sandbox` for a dev build from Xcode).

## Key references

- Open work: `BACKLOG.md` · pro API contracts: `docs/PRO-BACKEND-CONTRACTS.md`
- Backend native-readiness + push runbook: `tovis-app/docs/mobile/`
- Brand source of truth: `tovis-app/lib/brand/brands/tovis.ts`, `lib/brand/eyeSvg.ts`
- Wire contract: `tovis-app/schema/api/tovis-api.schema.json` (+ `lib/dto/`)
