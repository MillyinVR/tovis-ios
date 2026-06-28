# Tovis iOS — Build Handoff

> Self-contained handoff for a fresh Claude Code session continuing the **native
> iOS app** build. Written 2026-06-27, last updated 2026-06-27 (live-sync). The
> companion backend doc (auth/API readiness) is
> `tovis-app/docs/mobile/native-readiness-handoff.md` — read it for backend context.

## TL;DR — where we are

Native **SwiftUI iOS app** for Tovis (native Swift, iOS-first, **separate repo** at
`~/Dev/tovis-ios`). Branded login with **3 auth methods** (email/pw, Sign in with Apple,
phone-OTP), all on real `/api/v1` endpoints. Signed-in app is a **tab shell (Home +
Appointments)** with real, brand-matched, **actionable** screens, plus **live-sync** so the
web and the app stay in step.

**Signed-in screens (all committed, build green):**
- **Home** (`GET /client/home`) — greeting header (time-of-day + italic name), action banner,
  last-minute invites, next booking, favorite pros, favorited services, waitlist, viral looks.
- **Appointments** (`GET /client/bookings`) — bucketed Upcoming / Needs-attention /
  Pre-booked / Waitlist / Past → each row pushes to **Booking detail** (read-only, built from
  the list DTO; there is no standalone `GET /bookings/[id]` read endpoint).
- **Pro profile** (`GET /professionals/{id}`) — header/stats/bio/offerings/portfolio/reviews;
  reachable by tapping any pro across the app.

**Actions wired (client → backend):** approve/decline **consultation**, **favorite/unfavorite**
a pro (heart), **accept/decline last-minute invites**.
Not yet: **pay** (Stripe web + deep-link return) and **rebook confirm** (the bookings list DTO
doesn't carry the `aftercare.rebookMode` gate — needs a small tovis-app DTO field first).

**Live-sync (web ⇄ iOS) — built, shipped as tovis-app PR #416 + iOS commits.** See the
dedicated section below. Both sides stay fresh; the one open item is a live end-to-end smoke
test of the Realtime websocket.

**Verification posture:** `TovisKit` `swift test` green (9 tests, incl. wire-contract
fixtures); the **whole app BUILDS via `xcodebuild`** for the simulator (not just type-check).

Next real work (pick up here): **(1) live-sync end-to-end smoke test** (see its section),
**(2) pay flow** (needs deep links), **(3) rebook confirm** (needs the tovis-app DTO field),
**(4) more screens** — search/discover, messages — then **(5) operator/Xcode**: Apple
capability + `APPLE_CLIENT_ID`, push (APNs), and set the **production** API base URL.

## Current repo state (resume here)

- **`tovis-ios`** — branch `main`, **all work committed, working tree clean**. Has **NO git
  remote** (local commits only — `git remote -v` is empty; nothing to push). Latest commit:
  `feat(live-sync): wire Supabase project creds into TovisConfig`.
- **`tovis-app`** — branch `feat/live-sync` (7 commits ahead of `origin/main`), **pushed**,
  **PR #416 OPEN** (pre-push full suite 4828 green). Local `main` is level with `origin/main`.
  To resume backend work: `git checkout feat/live-sync` in `~/Dev/tovis-app`.
- **Build/verify commands:**
  - iOS unit + contract: `cd ~/Dev/tovis-ios/TovisKit && swift test` (9 pass);
    `cd ~/Dev/tovis-ios/scripts/contract && npm run validate` (fixtures vs backend schema).
  - iOS app build: `cd ~/Dev/tovis-ios && xcodebuild build -scheme Tovis -project
    tovis-ios.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.
  - Backend: `cd ~/Dev/tovis-app && npm run typecheck && npm run lint && npm run
    check:static-guards` + `npx vitest run`.
- **#1 next action: the live-sync end-to-end smoke test** (see the live-sync section's 🔴 note).

## Two repos

| Repo | Path | Role |
|------|------|------|
| Backend | `~/Dev/tovis-app` | Next.js 16 API (the `/api/v1` surface). Where auth endpoints live. |
| iOS app | `~/Dev/tovis-ios` | This repo. SwiftUI app + `TovisKit` package. Talks to the backend over HTTP only. |

## iOS repo layout

```
tovis-ios/
├── TovisKit/                 ← local Swift Package (UI-free core). `swift build` + `swift test` pass.
│   └── Sources/TovisKit/
│       ├── Config/TovisConfig.swift     baseURL (.local=localhost, .production=SET REAL URL) + supabaseURL/anonKey (live-sync, wired)
│       ├── Networking/        APIClient (bearer auth, 401→refresh→retry), APIError
│       ├── Auth/              TokenStore (Keychain), AuthService (login/apple/phoneLogin/refresh/logout), SessionToken (decode userId from JWT)
│       ├── Devices/           DeviceService (POST /devices push registration)
│       ├── Home/             HomeService (GET /client/home + accept/decline priority-offer invites)
│       ├── Bookings/         BookingsService (GET /client/bookings + POST consultation decision)
│       ├── Professionals/    ProfileService (GET /professionals/{id} + POST/DELETE favorite)
│       ├── Live/             SupabaseRealtime (dependency-free Phoenix ws → live-sync)
│       ├── Models/            Codable wire models (Auth, Common, ClientHome, ClientBooking, ProProfile)
│       ├── Tests/             DecodingTests + Fixtures/*.json (shared with the contract test)
│       └── TovisClient.swift  (wires it all + stable per-install deviceId; exposes .home/.bookings/.profiles)
├── Tovis/                    ← the Xcode APP TARGET (synchronized folder — drop files here, they auto-add)
│   ├── ContentView.swift      @main + SessionModel (owns refreshTick live-sync seam + realtime) + RootView + LoginView
│   ├── PhoneLoginView.swift    two-step phone→code sheet
│   ├── MainTabView.swift       signed-in tab shell (Home + Appointments; add tabs here)
│   ├── HomeView.swift          client home (NavigationStack; cards→Appointments tab, pros→profile; foreground refresh + poll)
│   ├── AppointmentsView.swift  bucketed bookings list (NavigationStack → detail; foreground refresh + poll)
│   ├── ProProfileView.swift    public pro profile (header/stats/bio/offerings/portfolio/reviews; favorite heart)
│   ├── BookingDetailView.swift read-only booking detail + consultation approve/decline (from ClientBookingDTO)
│   ├── Theme/                  BrandColor (Peacock Plume), BrandFont (Grotesk trio), TovisEye, Formatters (ISO date + money), BrandComponents (shared Surface/Pill/Avatar/Section eyebrow + statusTone)
│   ├── Fonts/                  bundled .ttf (Hanken/Space Grotesk, Space Mono) + registered in Info.plist
│   └── Info.plist              ATS Allow Local Networking = YES; UIAppFonts
├── scripts/contract/         Node+ajv: validate Fixtures/*.json vs tovis-app/schema/api/tovis-api.schema.json (npm run validate)
├── AppFiles/                 ← stale reference copies (superseded by Tovis/*). Ignore/clean up.
└── tovis-ios.xcodeproj        ⚠️ IPHONEOS_DEPLOYMENT_TARGET pinned to 17.0 (was 27.0 > SDK max)
```

**Design decision:** match the web app closely (it was built to look like iOS), but
rebuild with native SwiftUI components. Brand is **exact** — colors + logo ported 1:1
from `tovis-app/lib/brand/brands/tovis.ts` and `lib/brand/eyeSvg.ts`. Default mode is
**dark** (`.preferredColorScheme(.dark)`).

## Auth — three methods, all wired

| Method | App | Backend endpoint | Backend PR |
|--------|-----|------------------|------------|
| Email + password | `LoginView` | `POST /api/v1/auth/login` | (already existed) |
| Sign in with Apple | `SignInWithAppleButton` → `AuthService.appleLogin` | `POST /api/v1/auth/apple` | **#414 MERGED** |
| Phone OTP | `PhoneLoginView` → `AuthService.phoneLoginSend`/`Verify` | `POST /api/v1/auth/phone-login/{send,verify}` | **#415 MERGED** |

All return the same session payload (`AuthLoginResponseDTO`): token in the JSON body
(stored in Keychain) + cookie for web. 401s auto-refresh via `POST /api/v1/auth/refresh`.

## Backend PR status (in `tovis-app`)

- **#413 — proxy cookieless-origin fix — MERGED.** *Critical:* native login/apple/phone
  are cookieless with no `Origin` header; without this they 403. This unblocks ALL native auth.
- **#414 — Sign in with Apple backend — MERGED.**
- **#415 — phone-OTP login backend — MERGED** (`d1e707d5`). All three auth methods are now
  on `main`. **Deploy `main` to make them live in production** (local dev already has them).
- **#416 — live-sync (web ⇄ iOS) — OPEN** (`feat/live-sync`,
  https://github.com/MillyinVR/tovis-app/pull/416). Pushed; pre-push full suite (4828) green.
  Needs review/merge + deploy. See the live-sync section below.

## Live-sync (web ⇄ iOS) — built, PR #416 open

Goal: a booking/consult/message done on one device shows on the other without manual reload.
**One backend + one DB; clients are thin** — so they can't truly diverge; this just removes
staleness. Two layers (each safe alone):

- **Layer 1 — refresh on focus + poll (zero infra, in both repos).**
  - iOS: `SessionModel.refreshTick` is the seam — bumped when the app foregrounds
    (`scenePhase`); Home + Appointments observe it and also poll every 30s (`poll()`).
  - Web (tovis-app PR #416): `app/_components/live/RefreshOnFocus.tsx` `router.refresh()` on
    tab focus/visibility (mounted in client + pro layouts) + 20s poll on pro bookings.
- **Layer 2 — Supabase Realtime (notify-then-refetch).**
  - Server (tovis-app): `lib/live/broadcast.ts` `broadcastLive(channels, topic)` POSTs a tiny
    "changed" ping (no data) to channels `pro:{professionalId}` / `user:{userId}` via the
    Realtime HTTP API. **Fail-open.** `lib/live/broadcastBooking.ts` resolves a booking's
    pro+client channels in one query. Wired into: booking finalize, consultation decision,
    pro-created bookings, aftercare rebook (confirm/decline), pro rebook, new chat message.
  - Web subscriber: `app/_components/live/LiveRefresh.tsx` (supabase-js) → `router.refresh()`.
  - iOS subscriber: `TovisKit/Sources/TovisKit/Live/SupabaseRealtime.swift` — dependency-free
    Phoenix websocket; subscribes to `user:{userId}` (userId decoded from the JWT via
    `SessionToken`, so it works on cold launch) and bumps `refreshTick`. Started on sign-in
    (incl. bootstrap), stopped on logout. **Fail-safe**: if it can't connect, the app falls
    back to Layer 1.
  - Config: iOS creds are wired in `TovisConfig` (supabaseURL + the **publishable** key
    `sb_publishable_…`, public/safe to embed, same project the backend uses). Web uses
    `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (this project ships the publishable key, NOT the
    legacy anon key — important gotcha). Server uses `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`.
    **No Supabase DB/publication config needed** — Broadcast is pub/sub, not Postgres CDC.
  - Runbook: `tovis-app/docs/runbooks/live-sync.md`.

🔴 **OPEN — the one unverified piece: a live end-to-end smoke test of the Realtime websocket.**
Everything builds and is logically wired, but it was never run against a live Supabase. The
specific unknown: **does the publishable key (`sb_publishable_…`) authenticate the Realtime
websocket?** (Legacy Realtime used the anon JWT.) If not, both clients **fail safe to the
poll/focus layer** — nothing breaks, you just don't get sub-second push. To verify: `npm run
dev` in tovis-app, open the pro bookings page on web + the app in a simulator (same accounts),
make a booking, watch it appear with no manual refresh. If silent, check the ws handshake
(browser Network tab / Xcode console) — if the publishable key is rejected, mint a Realtime
token or use the legacy anon JWT instead. v1 uses **public** broadcast channels; before
multi-tenant scale, upgrade to authorized channels (RLS on `realtime.messages` + minted token).

## 🔴 Remaining setup to light it all up (operator + Xcode — needs the human)

1. **`APPLE_CLIENT_ID` env** = the iOS bundle id (e.g. `me.tovis.Tovis`, check Xcode →
   target → Signing & Capabilities). Set in `tovis-app/.env.local` for local dev AND in
   Vercel for prod. Without it, `/api/v1/auth/apple` can't verify tokens.
2. **Xcode: add the "Sign in with Apple" capability** — Tovis target → Signing &
   Capabilities → set **Team** (paid Apple Developer account — the user HAS one) → +
   Capability → Sign in with Apple. The button compiles without it but Apple's sheet
   errors until it's added.
3. **Twilio Verify** for phone-OTP — `TWILIO_VERIFY_SERVICE_SID` etc. (already set in prod).
4. **Deploy** so the merged backend is live against production (not just local dev).

## How to run / test (current state)

1. Backend: `cd ~/Dev/tovis-app && npm run dev` (serves `localhost:3000`).
2. Xcode: open `~/Dev/tovis-ios/tovis-ios.xcodeproj`, pick an **iPhone simulator** (not
   "My Mac"), ⌘R.
3. Email/password sign-in works today against local dev. Apple needs steps 1–2 above.
   Phone-OTP needs Twilio Verify configured locally (or test against deployed prod).
4. Phone field expects **E.164** (`+15555550123`).

## ⚠️ Gotchas / lessons (so the next session doesn't repeat them)

- **Xcode 26/27 beta single-file app:** new projects open as "Untitled" and you name them
  by **saving** (⌘S). They generate ONE file with `@main` + `ContentView` + `#Preview` +
  `#Playground` — we replaced it with our real `ContentView.swift`. Files dropped into
  `Tovis/` (a synchronized folder) auto-appear in the project.
- **App-target CLI type-check IS possible** (better than the original handoff implied).
  You can't fully *build*/sign from CLI, but you CAN type-check the app target against the
  simulator SDK by first emitting a TovisKit simulator module, then `-typecheck`-ing the
  app sources against it:

  ```bash
  cd ~/Dev/tovis-ios
  SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
  TRIPLE="arm64-apple-ios17.0-simulator"
  OUT=$(mktemp -d)
  xcrun swiftc -emit-module -module-name TovisKit -sdk "$SDK" -target "$TRIPLE" \
    -emit-module-path "$OUT/TovisKit.swiftmodule" $(find TovisKit/Sources/TovisKit -name '*.swift')
  xcrun swiftc -typecheck -sdk "$SDK" -target "$TRIPLE" -I "$OUT" $(find Tovis -name '*.swift')
  ```

  This catches every type/SwiftUI error (it caught a bogus `Equatable` conformance during
  the home-screen build).

  Even better — the **full app target now BUILDS via `xcodebuild`** (real toolchain, not
  just type-check):

  ```bash
  xcodebuild build -scheme Tovis -project tovis-ios.xcodeproj \
    -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO
  # → ** BUILD SUCCEEDED **
  ```

  ⚠️ **Deployment-target gotcha (fixed):** the project shipped with
  `IPHONEOS_DEPLOYMENT_TARGET = 27.0`, which exceeds the installed SDK's max (26.5) — a plain
  simulator build then reports "Supported platforms … is empty" and silently produces nothing.
  Lowered to `17.0` (matches TovisKit's `.iOS(.v17)`). If a future Xcode bumps this back up,
  watch for that message.
- **Wire-contract test (DTO drift guard):** `scripts/contract/validate-fixtures.mjs` (ajv)
  validates the shared `TovisKit/Tests/.../Fixtures/*.json` against tovis-app's generated
  `schema/api/tovis-api.schema.json`. The SAME fixtures are decoded by `swift test`. So a
  backend DTO change fails loudly in one of those two places. Run:
  `cd scripts/contract && npm install && npm run validate` (schema path overridable via
  `TOVIS_API_SCHEMA`; defaults to the sibling `../../../tovis-app/...`). It already caught a
  real enum drift (`professionType` "HAIR" → "HAIRSTYLIST").
- **Branch hygiene (we got burned once):** in `tovis-app`, branch every feature off
  `origin/main` and DON'T stack PRs. Phone-OTP got accidentally committed on top of the
  Apple branch; I had to un-stack it (cherry-pick onto main + reset). When two auth PRs
  both touch `lib/rateLimit/policies.ts` + the generated schema, expect a rebase conflict —
  resolve by keeping BOTH buckets and re-running `npm run gen:api-schema`.
- **CI "Browser E2E" flakes** with `runner received a shutdown signal` (infra, not code) —
  just re-run that one job.
- **Fonts** are variable fonts referenced by FAMILY name in `BrandFont` so `.weight()`
  drives the axis; `UIAppFonts` in Info.plist lists the files.

## ▶️ Suggested next steps (pick up here)

0. 🔴 **Live-sync end-to-end smoke test (DO FIRST).** All of live-sync is built (iOS committed;
   web on PR #416) but never run against a live Supabase Realtime. Verify: `npm run dev` in
   tovis-app, open the pro bookings page on web + the app in a simulator (same accounts), make
   a booking → it should appear on both with no manual refresh. The one unknown is whether the
   **publishable key authenticates the Realtime websocket** (legacy used the anon JWT). If the
   ws handshake is rejected (check browser Network tab / Xcode console), mint a Realtime token
   or fall back to the legacy anon JWT. Fail-safe: if realtime is silent, Layer-1 poll/focus
   still keeps both fresh. Then **merge PR #416 + deploy**.
1. **Confirm the app builds & runs in Xcode** + add the Apple capability + `APPLE_CLIENT_ID`,
   then smoke-test all three sign-ins AND the Home + Appointments tabs in the simulator (run
   the backend with `npm run dev` and sign in as a CLIENT account — the home/bookings
   endpoints are `requireClient`, so a PRO-only account 403s and the screens show the error
   state). Note: a NEW Swift file in `Tovis/` only joins the build once Xcode's synchronized
   folder picks it up — if the build can't find `MainTabView`/`AppointmentsView`/etc., open
   the project in Xcode once so they register.
2. ✅ **DONE — signed-in tab shell + 3 screens (home, appointments, booking detail).**
   `GET /client/home` → `HomeService`/`ClientHome`; `GET /client/bookings` →
   `BookingsService`/`ClientBooking` (mirror the DTOs; only the rendered subset modeled,
   nullable→optional, unknown keys ignored). Shared UI in `Theme/BrandComponents.swift`.
   Decode tests in `DecodingTests.swift`.
3. **Make the screens actionable (in progress).**
   - ✅ **Consultation approve/reject DONE.** `BookingsService.decideConsultation(bookingId:_:)`
     → `POST /client/bookings/[id]/consultation` `{action:APPROVE|REJECT}` (server is
     idempotent). `BookingDetailView` shows Approve/Decline buttons when the consultation is
     pending; on success it refreshes the list (`onDecision`) and pops back. Wire verbs
     locked by a test.
   - ✅ **Open a pro profile DONE.** `ProfileService.professional(id:)` →
     `GET /professionals/{id}` (returns `{ professional }`; note `/u/[handle]` is the
     *client/creator* profile, NOT the pro). `ProProfileView` renders header/stats/bio/
     offerings/portfolio/reviews. Pros are tappable from booking detail + home (favorite
     chips / invite / waitlist rows). Decode test added.
   - ✅ **Favorite/unfavorite a pro DONE.** `ProfileService.setFavorite` →
     `POST`/`DELETE /professionals/{id}/favorite` (returns `{favorited,count}`). Heart toggle
     in `ProProfileView`, optimistic + reverts on error, seeded from `isFavoritedByMe`.
   - ✅ **Accept/decline last-minute invites DONE.** `HomeService.acceptInvite/declineInvite`
     → `POST /client/priority-offer/{recipientId}/{accept,decline}` (`HomeInvite.id` IS the
     recipientId). Home invite rows have inline Accept/Decline + still link to the pro;
     success reloads home. 410/409 (expired / no-longer-priority) surface as the error line.
   - ⏭️ **Remaining two need backend/app infra, NOT iOS-only — STOPPED here on purpose:**
     - **rebook (aftercare next-appointment confirm/decline)** — endpoint exists
       (`POST /client/bookings/[id]/aftercare-rebook` `{action:CONFIRM|DECLINE}`, and CONFIRM
       requires an `Idempotency-Key` header → APIClient needs header support added). BUT the
       gating signal (`aftercare.rebookMode === BOOKED_NEXT_APPOINTMENT` + `rebookedFor`) is
       **NOT in the `/client/bookings` list DTO** — the native app can't tell which prebooked
       booking is awaiting confirmation. Fix first in tovis-app: surface a
       `pendingRebookConfirmation` flag (or the aftercare rebook fields) on `ClientBookingDTO`,
       then wire the UI.
     - **pay** (`/client/bookings/[id]/checkout` + `/deposit/stripe-session`) — Stripe returns
       a hosted URL; needs in-app Safari + a Universal-Link deep-link return (Tier 3.2, step 6).
     The pro display-name resolver (`BookingProfessional.displayName`) already ports
     `lib/privacy/professionalDisplayName.ts`.
4. Then iterate outward: search/discover, booking flow (holds → availability → checkout),
   messages. All have `/api/v1` endpoints + DTOs already.
5. **Push notifications** (backend built but inert): add the Push Notifications capability,
   register for APNs, call `DeviceService.register(apnsToken:deviceId:)`; operator sets
   APNs/FCM creds (`tovis-app/docs/mobile/push-go-live-runbook.md`).
6. **Deep links / Universal Links** (backend Tier 3.2, not started) — needed for Stripe
   checkout returns and to replace web Turnstile with App Attest (Tier 4.1).

## Key references

- Backend native-readiness handoff: `tovis-app/docs/mobile/native-readiness-handoff.md`
- Brand source of truth: `tovis-app/lib/brand/brands/tovis.ts`, `lib/brand/eyeSvg.ts`
- Wire contract for native models: `tovis-app/schema/api/tovis-api.schema.json` (+ `lib/dto/`)
- Push runbook: `tovis-app/docs/mobile/push-go-live-runbook.md`
