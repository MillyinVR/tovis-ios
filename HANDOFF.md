# Tovis iOS — Build Handoff

> Self-contained handoff for a fresh Claude Code session continuing the **native
> iOS app** build. Written 2026-06-27, **last updated 2026-06-28** (footer parity,
> light/dark, Me, Home, Inbox, Discover, Booking v1, prod deploy). The companion
> backend doc is `tovis-app/docs/mobile/native-readiness-handoff.md`.

## TL;DR — where we are

Native **SwiftUI iOS app** for Tovis (iOS-first, **separate repo** at `~/Dev/tovis-ios`).
Branded login with **3 auth methods** (email/pw, Sign in with Apple, phone-OTP) on real
`/api/v1` endpoints. The signed-in app is a **custom 5-tab shell that matches the web client
footer 1:1** — Home · Discover · Looks(center feather) · Inbox · Me — with brand-matched,
**actionable** screens, **System/Light/Dark** theming, and **live-sync** so web ⇄ iOS stay in step.

**Signed-in screens (all committed, build green):**
- **Home** (`GET /client/home`) — full web parity: accent glow, greeting + InboxBell, action
  card (inline consult approve/decline), last-minute openings (Grab it/Pass), next booking,
  favorite pros, favorited services, waitlist, Viral Looks band.
- **Discover** (`GET /api/v1/search`) — search pros + services (debounced), Pros/Services
  toggle; pro rows → pro profile, service rows → re-search. **List only (no map yet.)**
- **Inbox** (`GET /messages/*`) — thread list + conversation (bubbles, send, mark-read);
  live unread badge on the footer tab; Home bell switches to this tab.
- **Me** (`GET /api/v1/me`) — full web /client/me parity: header + FOLLOWERS/BOARDS/SAVED/
  BOOKED stats, creator card, upcoming, Your Looks (with working Public/Private toggle),
  BOARDS/FOLLOWING/HISTORY tabs. Theme picker + Sign out live in its header menu.
- **Appointments** (`GET /client/bookings`) — bucketed list → **Booking detail** (read-only).
  NOT a footer tab (matches web): reached from Home cards + the Me tab.
- **Pro profile** (`GET /professionals/{id}`) — header/stats/bio/offerings/portfolio/reviews;
  tapping a **service opens the booking flow**.
- **Booking flow (v1)** — `BookingFlowView` sheet from a pro's service: bootstrap availability
  → pick date → exact slots → **hold + finalize** → booking lands in Appointments as PENDING.

**Actions wired (client → backend):** consultation approve/decline (home card + booking
detail), favorite/unfavorite a pro, accept/decline last-minute invites, **send messages**,
**toggle a look Public/Private**, **request-to-book** (hold→finalize), theme preference.

**Looks tab** is the ONLY remaining "Coming soon" placeholder (`ComingSoonView.looks`).

**Verification posture:** `TovisKit` `swift test` green (**15 tests**); the contract validator
(`scripts/contract`) green (**11 objects** vs the backend schema); the whole app **BUILDS via
`xcodebuild`** for the simulator in Debug AND Release. The booking write path (hold→finalize)
was verified **live end-to-end** against the API (201 PENDING → shows in /client/bookings).

Next real work (pick up here): **(1) Looks tab** — clear the last placeholder
(`GET /api/v1/looks` feed). **(2) Push/APNs** (DeviceService is inert). **(3) Booking v2** —
mobile mode + add-ons + reschedule/cancel. **(4) Xcode/operator** — Apple capability +
`APPLE_CLIENT_ID` env.

**✅ DONE 2026-06-27 — in-app Stripe payment + deep-link return (the old #1).** A client can now
pay a booking inside the app via hosted Stripe Checkout, and the app is handed back
automatically — **without any Apple-portal setup**. Chosen approach: a **custom-scheme bounce**
(not Universal Links). The native app sends an `x-tovis-return-target: native` header on the
`*/stripe-session` POST; the backend then points Stripe's success/cancel `*_url` at a new public
page `tovis-app app/checkout/return`, which redirects to `tovis://checkout/return?status=…&kind=…&bookingId=…`.
The app catches that via `.onOpenURL`, dismisses the in-app `SFSafariViewController`, and refetches.
The Stripe **webhook is the source of truth** (sets `checkoutStatus=PAID`), so the return is just
UX. Wired: `TovisKit/Checkout/CheckoutService` (`createCheckoutSession` + `createDepositSession`),
`Tovis/SafariView.swift`, `CheckoutReturn` deep-link parser + `SessionModel.handleDeepLink`, and a
**Pay button in `BookingDetailView`** (shows when `checkoutStatus` is READY/PARTIALLY_PAID and
nothing's collected; flips to "Payment received" after). `tovis` URL scheme registered in Info.plist.
🟡 **One on-device unknown** (same posture as live-sync): whether `SFSafariViewController`
auto-follows the `tovis://` redirect. If it doesn't, the bounce page shows a "Return to the app"
button (user-tap always works) and the manual "Done" tap refetches anyway — so it degrades safely.
🟡 **Deposit UI not gated yet**: `CheckoutService.createDepositSession` exists, but `ClientBooking`
doesn't model `depositStatus`, so there's no UI trigger. Add that field to surface a deposit-pay CTA.

## Current repo state (resume here)

- **`tovis-ios`** — branch `main`, **all work committed, working tree clean**. **NO git
  remote** (local commits only; nothing to push). Recent commits (newest first):
  `feat(checkout)` (Stripe pay + deep-link return) · `feat(booking)` · `feat(discover)` ·
  `feat(inbox)` · `feat(home)` · `feat(me)` · `feat(theme)` · `feat(config: www.tovis.app)` ·
  `feat(footer)`.
- **`tovis-app`** — the native-Stripe-return backend is on branch
  **`feat/native-stripe-checkout-return`** (committed; **not yet pushed/PR'd** as of this
  handoff — local `main` is still clean + level with `origin/main`). It adds
  `lib/checkout/nativeReturn.ts` (shared, dedupes the old per-route `getAppUrl`), the public
  `app/checkout/return` bounce route, and the `native` branch in both `*/stripe-session` routes
  (web URLs byte-for-byte unchanged; native gated on the header). typecheck + lint +
  static-guards green; checkout stripe-session route tests 12/12 (added a native-return case).
- **`tovis-app`** — branch `main`, level with `origin/main`. **PR #416 (live-sync) is MERGED**
  (it's the latest main commit). **`main` has been DEPLOYED to Vercel production** this session
  (`npx vercel@latest --prod`) — native cookieless auth now passes on prod (was 403
  INVALID_ORIGIN before the deploy). Prod migration `20260627040000_add_user_apple_user_id`
  applied.
- **Local backend is/was running** for dev: `cd ~/Dev/tovis-app && pnpm dev` (serves
  `localhost:3000`, used by the iOS **Debug** build). It uses the **local** Postgres on
  `:5434` (Docker container `tovis-dev-postgres`), NOT prod — see the env/DB note below.
  **Seed login: `client@tovis.app` / `password123`** (CLIENT).
- **Build/verify commands:**
  - iOS unit + contract: `cd ~/Dev/tovis-ios/TovisKit && swift test` (15 pass);
    `cd ~/Dev/tovis-ios/scripts/contract && npm run validate` (11 objects vs backend schema).
  - iOS app build: `cd ~/Dev/tovis-ios && xcodebuild build -scheme Tovis -project
    tovis-ios.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.
  - Backend: `cd ~/Dev/tovis-app && npm run typecheck && npm run lint && npm run
    check:static-guards` + `npx vitest run`.
- **#1 next action:** deep links + Stripe so a booking can be *paid* in-app (see Next steps).

## ⚙️ Backend env / DB / prod (so the app actually loads — learned this session)

- **API base URL is build-type driven** (`Tovis/ContentView.swift` → `apiConfig`):
  **Debug → `.local` (localhost:3000)**, **Release → `.production` (`https://www.tovis.app/api/v1`)**.
  Use `www.` — the apex `tovis.app` 307-redirects and a cross-host redirect can drop the
  `Authorization` header. Live-sync Supabase creds in `TovisConfig` are already prod.
- **Local dev DB:** `pnpm dev` runs in development mode, so Next loads `.env.development.local`
  FIRST → `DATABASE_URL=postgresql://postgres:postgres@localhost:5434/tovis_dev` (the Docker
  container). `.env.local` points at the prod Supabase pooler but is NOT used by `pnpm dev`.
  So the iOS sim (Debug) + your local web share the **local** DB; prod web uses prod Supabase.
- **If signed-in endpoints 500 with "table … does not exist":** the local DB schema is stale.
  Fix: `cd ~/Dev/tovis-app && DATABASE_URL=postgresql://postgres:postgres@localhost:5434/tovis_dev
  DIRECT_URL=…5434…/tovis_dev npx prisma db push --skip-generate --accept-data-loss`.
  (This session that fixed a missing `DeviceSessionRevocation` table that was 500-ing /me + /home.)
- **Start the DB if down:** `docker start tovis-dev-postgres` (or `pnpm db:dev:up` to create it).

## TovisKit services map (one service per surface, all on `TovisClient`)

`auth` · `devices` · `home` · `bookings` · `profiles` · `me` · `messages` · `search` ·
`booking` — plus `client.currentUserId()` (decodes the JWT; used to align chat bubbles).
`APIClient.request/requestVoid` now take `query: [URLQueryItem]?` and `headers: [String:String]?`
(added for search params + the finalize idempotency-key).

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
│       ├── Me/               MeService (GET /api/v1/me + PATCH /client/looks/{id} visibility)
│       ├── Messages/         MessagesService (threads/messages/send/markRead/unreadCount)
│       ├── Search/           SearchService (GET /api/v1/search ?tab=PROS|SERVICES&q=)
│       ├── Booking/          BookingService (availability bootstrap/day → holds → finalize)
│       ├── Live/             SupabaseRealtime (dependency-free Phoenix ws → live-sync)
│       ├── Models/            Codable wire models (Auth, Common, ClientHome, ClientBooking,
│       │                      ProProfile, ClientMe, Messaging, Search, Booking)
│       ├── Tests/             DecodingTests + Fixtures/*.json (shared with the contract test)
│       └── TovisClient.swift  (wires it all + stable per-install deviceId; exposes .home/.bookings/.profiles)
├── Tovis/                    ← the Xcode APP TARGET (synchronized folder — drop files here, they auto-add)
│   ├── ContentView.swift      @main (apiConfig: Debug→.local/Release→.production) + SessionModel + RootView + LoginView
│   ├── PhoneLoginView.swift    two-step phone→code sheet
│   ├── ClientTab.swift         the 5 footer tabs (mirror of web app/config/clientNav.ts)
│   ├── TovisTabBar.swift       custom footer bar (mirror of web ClientSessionFooter + footers.css)
│   ├── MainTabView.swift       signed-in shell: TabView w/ hidden system bar + TovisTabBar overlay; unread badge
│   ├── ComingSoonView.swift    branded placeholder — now ONLY used by the Looks tab
│   ├── HomeView.swift          client home (full web parity; cards→Appointments, bell→Inbox tab, pros→profile)
│   ├── DiscoverView.swift      search pros/services → pro profile
│   ├── InboxView.swift         message thread list → ThreadView
│   ├── ThreadView.swift        conversation (bubbles + composer + mark-read)
│   ├── MeView.swift            /client/me dashboard (stats/creator/looks/tabs; theme+signout menu)
│   ├── AppointmentsView.swift  bucketed bookings list (pushed from Home/Me — NO own NavigationStack)
│   ├── ProProfileView.swift    pro profile; service rows → BookingFlowView sheet
│   ├── BookingFlowView.swift   v1 request-to-book (date → slots → hold → finalize)
│   ├── BookingDetailView.swift read-only booking detail + consultation approve/decline
│   ├── Theme/                  BrandColor, BrandFont, TovisEye, LooksMark (footer feather),
│   │                           ThemePreference (System/Light/Dark store), Formatters (Wire), BrandComponents
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
- **#415 — phone-OTP login backend — MERGED** (`d1e707d5`).
- **#416 — live-sync (web ⇄ iOS) — MERGED** (now the latest `main` commit `740fa5bc`).
- **✅ `main` DEPLOYED to Vercel prod this session.** All auth methods + the native aggregate
  endpoints (`/api/v1/me`, etc., from #389) are live on `www.tovis.app`. Native cookieless
  auth verified passing on prod (`POST /auth/login` with no Origin → 401 bad-creds, not 403).
  Backend `/api/v1/me` and `/client/me` were used as-is — **no new backend code was needed**
  for the Me dashboard (it already existed). Discover/Inbox/Booking also use existing endpoints.

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

1. **DB up:** `docker start tovis-dev-postgres` (created via `pnpm db:dev:up`). If signed-in
   screens 500 with "table … does not exist", run the `prisma db push` from the env/DB note above.
2. **Backend:** `cd ~/Dev/tovis-app && pnpm dev` (serves `localhost:3000` against the local DB).
3. **Xcode:** open `~/Dev/tovis-ios/tovis-ios.xcodeproj`, pick an **iPhone simulator**, ⌘R.
   A **Debug** build talks to localhost; a **Release** build talks to prod (`www.tovis.app`).
4. **Sign in:** `client@tovis.app` / `password123` (CLIENT). Home/Me/Bookings are `requireClient`,
   so a PRO/ADMIN account 403s those screens.
5. Email/password works locally + on prod now. Apple needs the Xcode capability + `APPLE_CLIENT_ID`.
   Phone field expects **E.164** (`+15555550123`).
6. **Booking smoke test:** seed pros lack near-term schedules, but availability exists on some
   farther dates (e.g. one pro had 26 slots on 2026-07-15) — pick a date a few weeks out to see slots.

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

**✅ DONE this session (all committed, build green):** footer parity (5-tab custom bar +
center feather) · System/Light/Dark theming · Me dashboard (incl. look Public/Private toggle) ·
Home full web parity · Inbox (threads + send + unread badge) · Discover (search) · **Booking
v1 (request-to-book, verified live)** · prod deploy (native auth unblocked). Earlier sessions:
consultation approve/decline, pro profile, favorite, last-minute invites, live-sync.

**Pick up here, in priority order:**

1. ✅ **Deep links + Stripe payment — DONE 2026-06-27** (custom-scheme bounce; see the TL;DR
   block above for the full wiring). Two follow-ups remain: **(a)** confirm the `tovis://` redirect
   on a real device/simulator with a live Stripe test session; **(b)** model `depositStatus` on
   `ClientBooking` to surface a deposit-pay CTA (the service method already exists).
2. **Looks tab** — the LAST `ComingSoonView` placeholder. `GET /api/v1/looks` (feed) +
   `/looks/[id]` + like/save/comments exist (DTOs: `LooksFeedResponseDto`, `LooksDetailResponseDto`,
   etc. in `lib/looks/types`). Build a feed (the center tab is the client's "home base" on web).
3. **Push / APNs** — `DeviceService.register(apnsToken:deviceId:)` exists but is inert. Add the
   Push Notifications capability, register for APNs, call it on sign-in. Operator sets APNs creds
   (`tovis-app/docs/mobile/push-go-live-runbook.md`).
4. **Booking v2** — mobile mode (+ client address selection via `/client/addresses`), add-ons
   (`/offerings/add-ons`), and reschedule/cancel (`/bookings/[id]/{reschedule,cancel}`). Also
   **rebook confirm** still needs a tovis-app DTO field: surface `pendingRebookConfirmation`
   (or the aftercare rebook fields) on `ClientBookingDTO` before the UI can gate it.
5. **Xcode / operator (needs the human):** add the **Sign in with Apple** capability (set Team)
   + set **`APPLE_CLIENT_ID`** (the bundle id) in Vercel env; confirm Twilio Verify env for
   phone-OTP. Then Archive → TestFlight (Release build auto-targets `www.tovis.app`).

⚠️ **Xcode synchronized-folder note:** new Swift files in `Tovis/` only join the build once
Xcode's synchronized folder picks them up. CLI `xcodebuild` already sees them (build is green),
but if Xcode itself can't find a new view, open the project once so it registers.

## Key references

- Backend native-readiness handoff: `tovis-app/docs/mobile/native-readiness-handoff.md`
- Brand source of truth: `tovis-app/lib/brand/brands/tovis.ts`, `lib/brand/eyeSvg.ts`
- Wire contract for native models: `tovis-app/schema/api/tovis-api.schema.json` (+ `lib/dto/`)
- Push runbook: `tovis-app/docs/mobile/push-go-live-runbook.md`
