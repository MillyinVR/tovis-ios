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
- **Discover** — native **MapKit** rebuild of the web SearchMapClient: a full-screen map of
  nearby pros (`GET /api/v1/search/pros` geo) with category chips (`/discover/categories`),
  free-text search, a **Map/List toggle**, an active-pro card → profile, and a **"Search this
  area"** button on pan. Uses `LocationManager` (CLLocationManager) for the "near you" origin;
  falls back to LA + manual pan if denied. Web uses Leaflet/OSM; iOS uses MapKit. Pins use the
  coarsened (~neighborhood) coords the API returns; `distanceMiles` is accurate.
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

**There are now ZERO "Coming soon" placeholders** — every footer tab is a real screen.
(The old `ComingSoonView` was deleted once the Looks tab shipped.)

**Verification posture:** `TovisKit` `swift test` green (**18 tests**); the contract validator
(`scripts/contract`) green (**17 objects** vs the backend schema); the whole app **BUILDS via
`xcodebuild`** for the simulator in Debug AND Release. The booking write path (hold→finalize)
was verified **live end-to-end** against the API (201 PENDING → shows in /client/bookings).

Next real work (pick up here): **(1) Notifications** — see the dedicated section below.
**(2) Booking v2** — mobile mode + add-ons + reschedule/cancel. **(3) Xcode/operator** — Apple
capability + `APPLE_CLIENT_ID` env. **(4) Deploy** tovis-app `main` (the merged Stripe-return
PR #417 isn't on prod yet — the user is holding the deploy).

## 🔔 Notifications — Track A DONE; Track B (push) is next

Two distinct tracks. **Track A (in-app center) is now built + live-verified.** Track B (push/APNs)
still needs operator + Apple.

**✅ Track A — in-app notification center — DONE 2026-06-28.** A real notification center on the
existing `/client/notifications*` endpoints. TovisKit `Models/Notifications.swift` +
`Notifications/NotificationsService.swift` on `client.notifications` (feed cursor-paged with
unread/eventKey filters · summary · markRead · preferences GET/PATCH); 2 fixtures
(`clientNotifications.json`, `notificationPreferences.json`) + 3 decode tests + 2 contract entries
(`ClientNotificationDTO`, `NotificationPreferencesPayload`). App: `NotificationsView.swift` — feed
list (per-event icon/tint, unread dot, tap-to-mark-read, **Mark all read**, pull-to-refresh, cursor
pagination); **booking notifications push `BookingDetailView`** (resolved from `client.bookings`).
**Home header** now has a **notifications bell** (unread dot from the unread feed, so it covers every
event type — the bucketed summary only covers booking/consult/aftercare/reminder) opening the sheet;
the messages entry became an **envelope** to disambiguate. Wired to `refreshTick` + the 30s home poll.
Verified: `swift test` (21) · contract validator (20 objects) · Debug `xcodebuild` · and a **live
round-trip** (feed/summary/preferences/mark-read) against the local backend — item keys, ISO
`createdAt`, `data` object, and `readAt` all matched. ⚠️ Note: the prefs PATCH method is **PATCH**
(an earlier handoff said PUT). The companion **tovis-app** change (typed DTOs + wire contract, branch
`feat/client-notifications-dto`, **not yet a PR/merged**) adds `lib/dto/clientNotifications.ts`,
retypes the feed + summary routes (Date→ISO mapper), and re-exports the prefs payload through the DTO
barrel so the schema captures the contract. **Not yet wired:** a SwiftUI **preferences editor**
screen (the service supports GET/PATCH; only the feed UI shipped) — easy follow-up.

**Track B — push / APNs (needs Apple capability + operator creds).**
`TovisKit/Devices/DeviceService.swift` already has `register(apnsToken:deviceId:)` / `unregister`
(POST/DELETE `/api/v1/devices`) but is **inert** — nothing calls it. To light it up: add the **Push
Notifications** capability in Xcode, register for APNs in the app delegate / `UIApplicationDelegate`
adaptor, and call `DeviceService.register` on sign-in with the SAME `deviceId` used for login (per-
device revocation depends on that). Operator sets APNs creds — runbook:
`tovis-app/docs/mobile/push-go-live-runbook.md`. Pair with Track A's preferences so users can
control what pushes.

**✅ DONE 2026-06-27 — Looks tab (the last placeholder), reworked to match web 1:1.** The center
feather tab is a full-bleed, vertically-paged TikTok/IG feed **ported directly from the web
components** (`tovis-app/app/(main)/looks/_components/*`): the **`Looks` serif header + Spotlight ·
Following · category tabs** (categories fetched from `/looks/categories`), bottom-left overlays
(creator name + **FOLLOW pill** + follower count, italic caption in quotes, mono-uppercase service
pill), and the full **right action rail**: creator **avatar with + badge** → teal **BOOK** circle →
like → comment → **save (bookmark)** → **share**. Cursor pagination; optimistic like + follow; share
via `ShareLink`; **save-to-board sheet** (`SaveToBoardSheet`, loads the viewer's boards). Full
**comments sheet** (`LookCommentsView`): top-level + 1-level replies (load-on-tap), like, reply,
delete-your-own — matching the rebuilt web CommentsDrawer. All existing endpoints, **no new backend
code**. TovisKit: `Models/Looks.swift` + `Looks/LooksService.swift` (feed w/ filter/category +
categories + like + follow + save + comments/replies) on `client.looks`; 2 fixtures + decode tests
(17 total) + contract entries (`LooksFeedItemDto`, `LooksCommentDto`). Verified live `GET /api/v1/looks`
returns all modeled fields. **Deferred:** video playback (`mediaType==VIDEO` shows the still frame,
no `AVPlayer` yet) and the header's search icon + workspace-switch pills (global chrome).
⚠️ **Couldn't screenshot it logged-in this session** (terminal lacks simulator accessibility
access; a `simctl install` also logs the sim out). To see it: Xcode ⌘R + sign in
(`client@tovis.app`/`password123` on local). Debug shows LOCAL looks (sparse) — to compare against
the prod web feed, point Debug at prod (flip the scheme to Release, or add a prod override).

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
  `feat(notifications)` in-app notification center (Track A) · `style(discover)` grid-default +
  web-grid view · `feat(discover)` MapKit rebuild ·
  `style(looks)` TikTok comments + feed-above-comments · `fix(auth)` cookieless URLSession ·
  `style(footer)` web-match + bigger center coin · `feat(looks)` feed + comments ·
  `feat(checkout)` Stripe pay + deep-link return · then `feat(booking|inbox|home|me|theme|footer)`.
- **`tovis-app`** — the native-Stripe-return backend **PR #417 is MERGED** into `main`
  (`90c5931e`); local `main` fast-forwarded + level with `origin/main`. It added
  `lib/checkout/nativeReturn.ts` (shared, dedupes the old per-route `getAppUrl`), the public
  `app/checkout/return` bounce route, and the `native` branch in both `*/stripe-session` routes
  (web URLs byte-for-byte unchanged; native gated on the header). **NOT yet deployed to Vercel
  prod** (user is holding the deploy) — so Release builds won't get the native return until then.
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
`booking` · `checkout` · `looks` · `discover` · `notifications` — plus `client.currentUserId()` (decodes the JWT; used to align chat bubbles).
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

⚠️ **Native MUST be cookieless (fixed 2026-06-27).** The login response sets a `tovis_token`
cookie for web. `URLSession.shared` has a shared cookie jar that would store it and silently
resend it — and the backend's CSRF gate (`tovis-app/proxy.ts`) only exempts native requests
when they carry **no cookie**. A stale cookie → the Origin check runs → native sends no Origin →
**403 "Invalid request origin." (INVALID_ORIGIN)** on the NEXT login. Fix: `TovisClient` now runs
on a **cookieless `URLSession`** (`makeCookielessSession()`: nil cookie storage,
`httpShouldSetCookies=false`, accept policy `.never`). Verified: a no-cookie login → 200; the
same login with a `Cookie: tovis_token=…` header → 403. Don't reintroduce `.shared`.

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

**✅ DONE 2026-06-27/28 (this session, all committed, build green):**
- **Stripe in-app payment + `tovis://` deep-link return** (PR #417 merged on backend; see TL;DR).
- **Looks tab** built then reworked to web parity (header tabs + rail + overlay), **TikTok-style
  comments sheet** (partial-height, count header, auto-expand on input), feed **lifted above the
  footer**, and the look **shrinks above the comments** when open.
- **Discover** rebuilt on **MapKit** (map of pros) + a **web-matching grid** (trending rail +
  2-col cards); **defaults to the grid** view, toggle to map.
- **Footer** retuned to match web (height/icons) then sized to the **pro footer's bigger center
  coin** with a translucent coin + orb glow.
- **`fix(auth)` cookieless URLSession** — native login was 403 INVALID_ORIGIN once URLSession.shared
  stored the `tovis_token` cookie; the client now runs cookieless. (Would've hit prod too.)

**Pick up here, in priority order:**

1. 🔔 **Notifications** — **Track A (in-app center) is DONE** (see the "🔔 Notifications" section).
   Remaining: **(a)** open/merge the tovis-app `feat/client-notifications-dto` branch (typed DTOs +
   wire contract); **(b)** a SwiftUI **notification-preferences editor** (the service GET/PATCH is
   ready); **(c)** **Track B push/APNs** (needs the Apple capability + operator creds).
2. **Booking v2** — mobile mode (+ client address selection via `/client/addresses`), add-ons
   (`/offerings/add-ons`), and reschedule/cancel (`/bookings/[id]/{reschedule,cancel}`). Also
   **rebook confirm** still needs a tovis-app DTO field: surface `pendingRebookConfirmation`
   (or the aftercare rebook fields) on `ClientBookingDTO` before the UI can gate it.
3. **Deploy** tovis-app `main` to Vercel prod so Release builds get the Stripe `tovis://` return
   (PR #417 is merged but **not deployed** — the user is holding it). Deploy via `npx vercel@latest --prod`.
4. **Xcode / operator (needs the human):** add **Sign in with Apple** + **Push Notifications**
   capabilities (set Team); set **`APPLE_CLIENT_ID`** (bundle id `app.tovis.Tovis`) in Vercel env;
   confirm Twilio Verify + APNs creds. Then Archive → TestFlight (Release auto-targets `www.tovis.app`).

**Smaller follow-ups (deferred this session):** Stripe — confirm the `tovis://` redirect on-device +
model `depositStatus` for a deposit-pay CTA. Looks — save-to-board exists but needs polish; Spotlight
already wired; **video playback** (`mediaType==VIDEO` shows the still frame, no `AVPlayer`). Discover —
Google Places location autocomplete in the search bar, pin **clustering**, and a radius/sort filter
sheet (fixed 25mi / distance sort today); grid cards use a decorative box, not the avatar photo (matches web).

⚠️ **Xcode synchronized-folder note:** new Swift files in `Tovis/` only join the build once
Xcode's synchronized folder picks them up. CLI `xcodebuild` already sees them (build is green),
but if Xcode itself can't find a new view, open the project once so it registers.

## Key references

- Backend native-readiness handoff: `tovis-app/docs/mobile/native-readiness-handoff.md`
- Brand source of truth: `tovis-app/lib/brand/brands/tovis.ts`, `lib/brand/eyeSvg.ts`
- Wire contract for native models: `tovis-app/schema/api/tovis-api.schema.json` (+ `lib/dto/`)
- Push runbook: `tovis-app/docs/mobile/push-go-live-runbook.md`
