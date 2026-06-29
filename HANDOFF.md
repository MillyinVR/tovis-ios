# Tovis iOS — Build Handoff

> Self-contained handoff for a fresh Claude Code session continuing the **native
> iOS app** build. Written 2026-06-27, **last updated 2026-06-28** — the entire
> **polish backlog (#1–#6) is now built** (add-ons · push deep-linking · deposit
> CTA · Looks video · Booking v2: mobile mode + rebook-confirm · Discover: filter
> sheet + Places autocomplete + pin clustering). The companion backend doc is
> `tovis-app/docs/mobile/native-readiness-handoff.md`.

## TL;DR — where we are

Native **SwiftUI iOS app** for Tovis (iOS-first, **separate repo** at `~/Dev/tovis-ios`).
Branded login with **3 auth methods** (email/pw, Sign in with Apple, phone-OTP) on real
`/api/v1` endpoints. The signed-in app is a **custom 5-tab shell that matches the web client
footer 1:1** — Home · Discover · Looks(center feather) · Inbox · Me — with brand-matched,
**actionable** screens, **System/Light/Dark** theming, and **live-sync** so web ⇄ iOS stay in step.

> **🚀 STATUS (2026-06-28): client app feature-complete + the full polish backlog (#1–#6) BUILT.**
> v1 is LIVE ON TESTFLIGHT. tovis-app `main` deployed to Vercel prod. Since then the whole polish
> backlog shipped on `tovis-ios` `main` (no remote — local commits only), with **5 companion backend
> PRs all MERGED**: typed DTOs for add-ons (**#421**), deposit (**#422**), client addresses (**#423**),
> rebook-confirm (**#425**), plus the E2E CI flake fix (**#424**). `tovis-app main` is clean + synced.
> **⚠️ The one open gap is LIVE VERIFICATION** — every polish feature is build- + contract-verified but
> NOT yet exercised on a device/sim against the backend (see "Suggested next steps"). Plus: merge nothing
> pending; just run the stack and click through.

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
- **Appointments** (`GET /client/bookings`) — bucketed list → **Booking detail**. NOT a footer
  tab (matches web): reached from Home cards + the Me tab. Detail has consult approve/decline,
  **in-app Stripe Pay**, and a **Manage section: Reschedule + Cancel (Booking v2)**.
- **Looks** (center feather tab) — full-bleed TikTok/IG vertical feed (`/api/v1/looks`): header
  tabs (Spotlight/Following/category), like/follow/save/share, full comments sheet.
- **Notifications** — in-app **notification center** (`/client/notifications*`) reached from the
  Home bell (unread dot); per-event rows, tap-to-mark-read, Mark all read, pagination, booking
  notifications push detail. Gear → **preferences editor** (channels + quiet hours). **Push/APNs**
  registers on sign-in (Track B). See the "🔔 Notifications" section.
- **Pro profile** (`GET /professionals/{id}`) — header/stats/bio/offerings/portfolio/reviews;
  tapping a **service opens the booking flow**.
- **Booking flow** — `BookingFlowView` sheet from a pro's service: bootstrap availability → pick
  date → exact slots → **hold + finalize** (or **hold + reschedule** when reused for Booking v2).

**Actions wired (client → backend):** consultation approve/decline (home card + booking
detail), favorite/unfavorite a pro, accept/decline last-minute invites, **send messages**,
**toggle a look Public/Private**, **request-to-book** (hold→finalize), theme preference.

**There are now ZERO "Coming soon" placeholders** — every footer tab is a real screen.
(The old `ComingSoonView` was deleted once the Looks tab shipped.)

**Verification posture:** `TovisKit` `swift test` green (**24 tests**); the contract validator
(`scripts/contract`) green (**24 objects** vs the backend schema); the whole app **BUILDS via
`xcodebuild`** for the simulator in Debug AND Release **and ships via TestFlight**. Booking
write/reschedule/cancel, notifications feed/summary/read/prefs, and device register/unregister were
verified **live end-to-end** earlier — but the **polish features (#1–#6) are build/decode-verified ONLY**
(see the per-item "Verified live? No" notes).

**The polish backlog (#1–#6) is DONE — what remains is LIVE VERIFICATION, not building:**
**(1) ✅ add-ons** · **(2) ✅ push deep-linking** · **(3) ✅ deposit-pay CTA** · **(4) ✅ Looks video** ·
**(5) ✅ Booking v2** (mobile mode + Places-autocomplete address + rebook-confirm) · **(6) ✅ Discover**
(radius/sort/mobile filter sheet + search-bar Places autocomplete + grid pin clustering).
The ONLY non-built item left is the on-device **Stripe `tovis://` redirect** confirmation. See
"Suggested next steps" for the per-item detail + the live-verification checklist.

---

# 🧑‍🎨 PRO APP — port plan (started 2026-06-28)

> **New track.** Everything above is the **CLIENT** app (feature-complete, on TestFlight).
> This section is the plan to bring the **PRO** (professional) side into the same native app —
> not a second app. The web pro surface is large: ~35 `/pro/*` pages and ~90 `/api/v1/pro/*`
> routes. We port it the same way we did the client: native SwiftUI, **web parity 1:1**, one
> TovisKit service per surface, typed backend DTOs + a contract fixture for every screen, and
> **no duplicated logic** (reuse the existing brand/components/services).

## The model that makes web ⇄ iOS seamless (read this first)

A single account has a permanent **home role** (`User.role`) and an **acting role** that rides
in the signed JWT. The acting role — not the home role — decides which shell/footer you see:

- iOS already decodes `AuthUser.role` (`CLIENT | PRO | ADMIN`) from the login/refresh response
  (`Models/Common.swift`). **It just never branches on it** — `RootView` shows the client
  `MainTabView` for everyone. Step 1 of the port is role-based routing.
- Switching workspace is server-side: `POST /api/v1/workspace/switch {workspace}` re-mints the
  JWT with the new acting role (entitlement re-checked every request; PRO requires an
  `APPROVED ProfessionalProfile`). Landing routes: `CLIENT→/client`, `PRO→/pro/calendar`.
- **Why this is the cross-device seam:** switch to Pro on web → the token reflects it → on the
  next iOS login/refresh `role == .pro` and iOS shows the pro shell. No client-side role state to
  keep in sync. iOS mirrors it with an in-app workspace switcher (in the Me/Profile menu) that
  POSTs `/workspace/switch`, then re-bootstraps the shell.
- **Cold-launch routing:** extend `SessionToken` to read the acting role out of the stored JWT
  (it already reads `userId` + `sessionKind`) so the shell renders with no network call, then
  reconcile against `/api/v1/me` (or the login `user.role`).

## Pro footer (web `ProSessionFooter`) → iOS `ProTabBar`

5 destinations, mirroring the web bar 1:1 (reuse `LooksMark`, `BrandColor`, mono labels, active
dot — the same primitives `TovisTabBar` uses; do NOT fork them):

| Slot | Label | Web route | iOS target | Status |
|------|-------|-----------|------------|--------|
| 1 | Looks | `/looks` | existing `LooksView` (role-agnostic) | ✅ reuse |
| 2 | Calendar | `/pro/calendar` | new `ProCalendarView` | 🔨 build (priority) |
| **C** | **live session** | dynamic | new center button (state machine) | 🔨 build |
| 4 | Messages | `/messages` | existing `InboxView` (role-agnostic) | ✅ reuse |
| 5 | Profile | `/pro/profile/public-profile` | new pro profile view | 🔨 build |

**The center button is the hard part** — a state machine driven by `GET /api/v1/pro/session`
(contract in `tovis-app/lib/proSession/types.ts`): mode `IDLE | UPCOMING | UPCOMING_PICKER |
ACTIVE`; center `{label, action, href}` where action ∈ `NONE | START | NAVIGATE | FINISH |
CAPTURE_BEFORE | CAPTURE_AFTER | PICK_BOOKING`. Behaviour ported from web `useProSession.ts`:
pulse when live, `PICK_BOOKING` opens a booking picker sheet, `START`/`FINISH` POST then route to
`center.href`, `CAPTURE_*` shows a camera icon and routes to the photo screen. Endpoints:
`POST /api/v1/pro/bookings/{id}/session/{start,finish}`, `PATCH .../session/step`,
`GET .../session/state`. **Decision (2026-06-28): build the FULL live-session flow now** — incl.
the before/after photo-capture screens — not a stub.

## 📸 The "AI Photographer" camera — design (decided 2026-06-28)

The pro session camera is NOT a plain camera — it's a real-time **AI photographer** that coaches
the pro to pro-quality images, service-aware, and learns what does well. Decomposed by latency tier:

- **Tier 1 — on-device real-time coach** (Vision + CoreImage + AVFoundation + CoreMotion, every
  frame, no network — keeps `media-private` images on device). Coaches: **lighting** (luma histogram
  + face-vs-background, backlit/over/under), **composition** (saliency + face/subject → rule-of-thirds,
  headroom, framing; CoreMotion horizon), **background** (`VNGeneratePersonSegmentation` → score
  clutter/brightness behind subject), **poses** (`VNDetectHumanBodyPose`/`HandPose` + face landmarks →
  compare to a target template), plus sharpness + shake. Surfaces **one prioritized nudge at a time**
  + a **readiness ring** (green → optional auto-capture). Architecture: a `ShotCoach` protocol; a
  coordinator aggregates to one nudge + readiness.
- **Tier 2 — service awareness** — a backend-served **ShotGuide** per profession/service selects
  WHICH coaches matter + targets + a **shot list** + **pose templates** + per-shot tips. v1 =
  **curated** guides (deterministic, ships now); v2 learns from Looks/portfolio engagement.
- **Tier 3 — Claude vision critique** (server-side, ~seconds) — structured critique + quality score +
  exemplar comparison ("what top balayage shots do that this misses"). **Gated behind explicit consent**
  (client session images are `media-private`). Build in Phase D. Use the latest vision-capable Claude
  model — confirm via the `claude-api` skill when implementing.

**Before/after auto-comparison slider** (user-requested, first-class): pair a BEFORE↔AFTER, show an
interactive slider, and let the pro **publish it to their portfolio** (a `LOOKS_PUBLIC`/
`PORTFOLIO_PUBLIC` upload — distinct from the private session media). This is the bridge from session
capture → marketing.

**Decisions (2026-06-28, user-confirmed):** on-device first (Claude critique later, behind consent) ·
curated ShotGuides now (learn later) · **custom AVFoundation camera** (needed for overlays/onion-skin/
auto-capture) · **build Phase A first** (capture + upload foundation).

**Camera build ladder:** **A.** ✅ capture + upload foundation (committed `e9296b5`) → **B.** on-device
real-time coach [**B1 ✅**: toggles + lighting/composition + nudge/ring/grid + voice/haptics;
**B2 ✅**: auto-harvest "best shots" tray (staged review → upload keepers; ≥1/2.5s, cap 24, readiness
≥0.85); **B3a ✅**: on-demand **silent** video clip (AVCaptureMovieFileOutput, NO mic — never records
salon audio) → frame-by-frame scrubber (AVAssetImageGenerator) to extract the best still or save the
whole clip, both into the same session media (VIDEO via `uploadSessionVideo`); **B3b next**: client
per-session media-use consent toggle in aftercare] → **C.** ShotGuides + onion-skin + **comparison
slider + portfolio publish** →
**D.** Claude critique (consented) → **E.** engagement learning loop.

**The "Session Reel" capture model (user-refined 2026-06-28):** instead of recording the entire
multi-hour appointment (storage-prohibitive), the always-on coach **auto-harvests high-res stills when
quality peaks** (B2) + the pro can shoot manually + record **on-demand video clips** that save as VIDEO
portfolio assets and get **best-frame extraction** (B3). Backend already supports VIDEO via the same
presign→PUT→confirm pipeline (`mediaType:"VIDEO"`, content-type video/mp4).

**Guidance is toggleable (`CoachSettings`, UserDefaults):** on-screen tips · spoken tips
(AVSpeechSynthesizer) · haptics · readiness ring · thirds grid · auto-capture. The pro chooses how it
guides them. `CoachEngine` (MainActor) + `CoachAnalyzer` (AVCaptureVideoDataOutput delegate, ~6 fps,
Vision face + CoreImage luma) → one prioritized nudge + a 0–1 readiness driving the shutter ring.
Coaches so far: **Lighting** (exposure/backlit) + **Composition** (face centering/headroom); sharpness/
background/pose next. Extend by adding a `ShotCoach` to the engine's coach list.

**Phase A contracts (verified in tovis-app):** sign `POST /api/v1/pro/uploads {kind:"CONSULT_PRIVATE",
bookingId, phase, contentType, size}` → `MediaUploadInitDTO {bucket, path, token, signedUrl, uploadSessionId, …}`;
upload **PUT** `${SUPABASE_URL}/storage/v1/object/upload/sign/{bucket}/{path}?token=…` headers
`apikey: <publishable>` + `Content-Type` + `x-upsert:false` (⚠️ **MUST be PUT** — POST → RLS 403, see
`lib/media/uploadWithProgress.ts`); confirm `POST /api/v1/pro/bookings/{id}/media {uploadSessionId,
phase, mediaType, caption?}` → `ProBookingMediaItemDTO`; list `GET …/media?phase=` →
`ProBookingMediaListResponseDTO`. All typed DTOs exist → contract entries possible.

## ✅ Progress (2026-06-28) — footer/shell milestone SHIPPED (committed, build green)

The pro footer now WORKS end-to-end. Built + verified (`swift test` **25**, contract **24**,
`xcodebuild` Debug **AND** Release green):
- **Role routing** — `SessionToken.role(from:)` reads the JWT acting-role claim; `SessionModel`
  tracks `activeRole` (login response + cold-launch JWT); `RootView` shows `ProMainTabView` when
  `role == .pro`, else the client `MainTabView`.
- **Pro shell + footer** — `ProTab`/`ProNav`, `ProMainTabView` (mirror of `MainTabView`), `ProTabBar`
  with the 5 web slots (Looks · Calendar · [center] · Messages · Profile). **DRY:** extracted the
  shared `FooterNavItemLabel`/`FooterBadgeDot` (now used by BOTH bars) and the `BrandCoin`
  ring/coin/shadow (now used by both `LooksMark` and the pro center) — no forked footer code.
- **Live-session center button** — `ProSessionModel` is the native port of `useProSession`:
  GET `/pro/session` (foreground + 60s poll), correct label/camera/pulse, START/FINISH (idempotent
  POST), PICK_BOOKING picker sheet, NAVIGATE/CAPTURE → routes to the booking's session hub. TovisKit
  `ProSessionService` (session/state/start/finish/step) + `Models/ProSession` + fixture + decode test.
- **Calendar tab (priority)** — `ProCalendarService` (`GET /pro/calendar`) + `ProCalendarView`: stats
  header, pending-requests section, agenda grouped by day; a booking → session hub.
- **Session hub** — `ProSessionHubView` shows the authoritative `/session/state` (status · step ·
  checkout) + a **Finish session** control.
- **Profile tab** — `ProProfileTabView`: identity, **Switch to client** workspace (real
  `POST /workspace/switch` re-mint via `AuthService.switchWorkspace` → `SessionModel.switchWorkspace`
  flips `activeRole` → shell swaps), theme, sign out.
- Looks + Messages tabs **reuse** the existing `LooksView`/`InboxView` (role-agnostic).

**🔭 Remaining in Phase 1 (next build):**
- **Before/after photo capture** — a NEW upload subsystem (none exists in iOS yet): `/pro/uploads`
  presign (typed `MediaUploadInitDTO` already exists) → PUT bytes → `POST /pro/bookings/{id}/media`
  confirm (uploadSessionId + storagePath `bookings/<id>/<phase>/` + phase + mediaType), plus a
  camera/PhotosPicker capture UI. The session hub has the entry point; CAPTURE_BEFORE/AFTER center
  actions already route there. It's self-contained — worth a focused, verifiable pass.
- **Backend tovis-app companion PR** — typed `ProSessionDTO` + a pro-calendar DTO so the new fixtures
  get ajv contract entries (today they're decode-only, like the early add-ons fixture). Same pattern
  as #421/#422; re-run `gen:api-schema`.

## Phases

**Phase 0 — Foundation (role routing + shell). ✅ DONE 2026-06-28.**
- `SessionToken.role(from:)`; `RootView` branches `signedIn` → `MainTabView` (client) vs
  `ProMainTabView` (pro) on `currentUser.role`/JWT.
- `ProNav` (mirror `ClientNav`/`ClientTab`), `ProTabBar` (mirror `TovisTabBar`, reuse its
  NavItemLabel/BadgeDot/LooksMark — extract shared bits rather than copy), `ProMainTabView`
  (mirror `MainTabView`: hidden system bar + `safeAreaInset` overlay, messages badge, push deep
  link, refreshTick).
- Workspace switcher entry (Me/Profile menu) → `POST /workspace/switch` → re-bootstrap.

**Phase 1 — Live-session center button (FULL). 🟡 center button + hub DONE; photo capture NEXT.**
- TovisKit `ProSession/ProSessionService` (session GET + start/finish/step) + `Models/ProSession`
  + fixture + decode test + contract entry.
- Center button: full `useProSession` port (poll on foreground + 60s, picker sheet, start/finish,
  navigate, capture). Session screens: **session hub**, **before-photos**, **after-photos**
  (camera/photo-picker → `POST /api/v1/pro/uploads` presign → `POST /pro/bookings/{id}/media`
  phase=BEFORE/AFTER; reuse the client upload + `MediaLoading` patterns). Step advancement via
  `PATCH .../session/step`; finish → final-review.

**Phase 2 — Calendar (priority screen). 🟡 agenda v1 DONE 2026-06-28.**
- ✅ TovisKit `ProCalendar/ProCalendarService` (`GET /pro/calendar`) + models; `ProCalendarView`
  agenda (stats + pending requests + day-grouped events; booking → session hub).
- ⏭️ Later: full day/week grid, block-time create/edit, location switcher.

**Phase 3 — Pro booking detail + bookings list.**
- `GET /pro/bookings`, `GET /pro/bookings/{id}`; consult proposal, manage (cancel/rebook),
  session entry. Reuse client `BookingDetailView` structure where the data overlaps.

**Phase 4 — Pro profile (Profile tab) + reviews + portfolio.**
- `GET/PUT /pro/profile`, `/pro/looks`, `/pro/reviews`. The Profile tab target.

**Phase 5+ — Clients/chart, aftercare, services/offerings, locations, availability/working-hours,
notifications (reuse client `NotificationsService` shape), reminders, membership/payments, last-
minute, waitlist, referral-rewards, verification/onboarding, migrate.** Sequence by daily-use
value: clients + aftercare next, settings/billing later.

## Backend (tovis-app) DTO work — REQUIRED per phase

Unlike the client port (most aggregate DTOs already existed), **most pro routes have NO typed DTO**
(`lib/dto/` only has `proBookingNew.ts` + partial calendar; session is inline). So each phase ships
a companion tovis-app PR: extract a typed DTO (`lib/dto/pro*.ts`), `satisfies` it on the route,
`npm run gen:api-schema`, and add a contract fixture + entry on the iOS side (same pattern as
#421/#422/#423/#425). Phase 1 needs a `ProSessionDTO` (+ session media/state). ⚠️ Remember: a DTO
JSDoc edit changes the generated schema — always re-run `gen:api-schema` (see memory).

## Guardrails (carry from the client port)

- **No duplicated logic** (CLAUDE.md house rule). Reuse `BrandColor/BrandFont/Theme`,
  `LooksMark`, the footer `NavItemLabel`/`BadgeDot`, `APIClient`, `Formatters`, the upload helpers,
  `NotificationsService`. Extract shared footer bits into a common file rather than copying
  `TovisTabBar`.
- **Web parity 1:1** — port from the web components, don't reinvent (brand is exact).
- **Contract or it didn't ship** — every pro screen gets a fixture + decode test + ajv contract
  entry so backend DTO drift fails loudly (`scripts/contract`).
- **Pro screens are `requirePro`** — a CLIENT token 403s them (mirror of the client `requireClient`
  note). Role routing must be correct before these screens are reachable.

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
`feat/client-notifications-dto`, **PR #419**) adds `lib/dto/clientNotifications.ts`,
retypes the feed + summary routes (Date→ISO mapper), and re-exports the prefs payload through the DTO
barrel so the schema captures the contract.

**✅ Preferences editor DONE 2026-06-28** — `NotificationPreferencesView.swift` (reached via the **gear**
in NotificationsView) is the native match of the web client's Settings → Notifications (the shared
`NotificationPreferencesForm`): a "how would you like to hear from us?" quick-pick (Email/Text/Push-soon,
porting the web's `deriveActivePreference` + `applyPreferredChannel`), quiet hours (toggle + From/To,
start≠end), and per-category per-channel toggles with email-locked events locked on. GET/PATCH via
`NotificationsService`; live PATCH round-trip verified. **NOTE — the web client already has this editor**
(`app/client/(gated)/settings/page.tsx` → Notifications), so **no web work was needed for prefs parity**.
The only thing iOS has that the web client lacks is the **notification-center feed list** itself (web
uses the Activity social feed + per-surface) — adding a web client center would be optional parity work
(the pro side already has one at `/pro/notifications`).

**Track B — push / APNs — ✅ APP SIDE WIRED 2026-06-28 (needs Apple capability + operator creds to fire).**
`Tovis/PushManager.swift` (PushManager + `AppDelegate` via `@UIApplicationDelegateAdaptor`) is now
LIVE: on every sign-in path (`SessionModel.startPush()` in login/apple/phone/bootstrap) it requests
notification permission, `registerForRemoteNotifications()`, and on the APNs callback calls
`DeviceService.register(apnsToken:deviceId:)` with the SAME per-install `deviceId` as login (per-device
revocation lines up). Logout → `stopPush()` → `unregister`. Foreground pushes show a banner; any incoming
push bumps `refreshTick` (the live-sync seam). The backend pipeline (APNs sender + cron drain + token
invalidation) is **already built/deployed + dormant** — NO backend code needed. Verified: Debug
xcodebuild + a live register/list/unregister round-trip vs POST/DELETE `/api/v1/devices`.
🔴 **To actually deliver a push (human/operator — can't be done from code):**
1. **Xcode**: Tovis target → Signing & Capabilities → set **Team** → **+ Capability → Push Notifications**
   (creates the `aps-environment` entitlement + provisioning). `didFailToRegister` fires until this is done
   (and always on the plain simulator) — non-fatal.
2. **Operator**: set `APNS_AUTH_KEY`/`APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_BUNDLE_ID` (= `app.tovis.Tovis`)
   (+ `APNS_ENV`) in Vercel and **redeploy** — runbook `tovis-app/docs/mobile/push-go-live-runbook.md`.
   `APNS_ENV=sandbox` for **Debug** (Xcode) builds, `production` for **TestFlight/App Store**.
3. **Smoke test on a REAL device** (simulator APNs tokens differ): sign in → grant permission → token
   registers → trigger a booking confirmation → push arrives. Per-event push + opt-out already honor
   Track A's preferences (`pushEnabled` + quiet hours).

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
  `feat(discover)` grid pin clustering · `feat(discover)` search-bar place autocomplete ·
  `feat(booking)` rebook-confirm CTA (#5b) · `feat(booking)` Places autocomplete for service address ·
  `feat(discover)` radius/sort/mobile filter sheet · `feat(booking)` mobile mode + address selection (#5a) ·
  `feat(looks)` AVPlayer video playback · `feat(booking)` deposit-pay CTA · `feat(push)` deep-link tap →
  booking · `feat(booking)` add-on selection — then the earlier v1 work (notifications, checkout, etc.).
- **`tovis-app`** — branch `main`, **clean + level with `origin/main`** (`03430e0a`), DEPLOYED to Vercel
  prod. **5 polish-companion PRs MERGED**: add-ons DTO (**#421**), deposit DTO (**#422**), client-address
  DTO (**#423**), E2E CI fix chromium-on-PRs (**#424**), rebook-confirm DTO (**#425**). Migrate-on-deploy
  wired; no pending migrations. **No open tovis-app PRs.** ⚠️ Prod hasn't been re-deployed since the polish
  DTOs merged — if a Release/TestFlight build needs the new DTO fields (deposit/rebook/addresses on the
  client bookings list, etc.), redeploy: `cd ~/Dev/tovis-app && npx vercel@latest --prod --yes`.
- **Local backend** for the iOS **Debug** build: `cd ~/Dev/tovis-app && pnpm dev` (serves
  `localhost:3000` against **local** Postgres `:5434`, Docker `tovis-dev-postgres`, NOT prod — see the
  env/DB note). **Seed login: `client@tovis.app` / `password123`** (CLIENT, local DB only — does NOT
  exist in prod, so TestFlight/Release needs a real prod account: web signup, Apple, or phone-OTP).
- **Build/verify commands:**
  - iOS unit + contract: `cd ~/Dev/tovis-ios/TovisKit && swift test` (**24 pass**);
    `cd ~/Dev/tovis-ios/scripts/contract && npm run validate` (**24 objects** vs backend schema).
  - iOS app build: `cd ~/Dev/tovis-ios && xcodebuild build -scheme Tovis -project
    tovis-ios.xcodeproj -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.
  - Backend: `cd ~/Dev/tovis-app && npm run typecheck && npm run lint && npm run
    check:static-guards` + `npx vitest run`.
- **#1 next action: LIVE VERIFICATION of the polish stack** (nothing left to build) — run the local
  stack + sim and walk add-ons → mobile booking + Places → deposit → rebook → Looks video → Discover
  filters/clustering/place-jump. See "Suggested next steps".

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

**✅ In-app phone verification (2026-06-28)** — `isFullyVerified = phone && email`, and Sign in with
Apple verifies the email but NOT a phone, so a new Apple client was signed-in-but-gated. Added a
`.needsVerification` root state + `PhoneVerificationView` (enter phone → `/auth/phone/correct` sets it
+ sends OTP → `/auth/phone/verify` mints the ACTIVE token). Sign-in routes via
`SessionModel.handleAuthResult` (fully-verified → app; else → verify step); cold launch reads the JWT
`sessionKind` (ACTIVE vs VERIFICATION) to route with no network call. NO backend change (same authed
`/auth/phone/*` endpoints the web verify-phone page uses). 🔴 Apple sign-in needs **`APPLE_CLIENT_ID`**
set in the **prod** Vercel env to work on device — confirm it's set. Native email/password **sign-UP**
is still web-only (register has captcha/TOS/SMS-consent/ZIP gates); **Apple + phone-OTP are the native
onboarding paths** (both auto-create accounts).

⚠️ **Native MUST be cookieless (fixed 2026-06-27).** The login response sets a `tovis_token`
cookie for web. `URLSession.shared` has a shared cookie jar that would store it and silently
resend it — and the backend's CSRF gate (`tovis-app/proxy.ts`) only exempts native requests
when they carry **no cookie**. A stale cookie → the Origin check runs → native sends no Origin →
**403 "Invalid request origin." (INVALID_ORIGIN)** on the NEXT login. Fix: `TovisClient` now runs
on a **cookieless `URLSession`** (`makeCookielessSession()`: nil cookie storage,
`httpShouldSetCookies=false`, accept policy `.never`). Verified: a no-cookie login → 200; the
same login with a `Cookie: tovis_token=…` header → 403. Don't reintroduce `.shared`.

## Backend PR status (in `tovis-app`)

**Polish-companion DTO/CI PRs (2026-06-28) — ALL MERGED:**
- **#421 — typed `OfferingAddOnItemDTO`** (add-ons) + web `AddOnDTO` dedup onto the shared type.
- **#422 — `depositStatus` + `depositAmount`** on `ClientBookingCheckoutDTO` (+ list-route select).
- **#423 — typed `ClientAddressDTO`** (client addresses; pins `mapClientAddress`).
- **#424 — E2E CI fix:** chromium-only on PRs, full matrix on `main` (cuts the runner-preemption flake).
- **#425 — `hasPendingRebookConfirmation` + `rebookProposedFor`** on `ClientBookingDTO` (+ list-route select).
  All used the OPTIONAL-builder-input pattern (deposit/rebook/address selects optional on
  `buildClientBookingDTO` → zero web churn; only the bookings LIST route selects them).
  💡 LESSON saved: a DTO **JSDoc-comment edit** changes the generated schema (ts-json-schema-generator emits
  comments as `description`s) — re-run `npm run gen:api-schema` after ANY DTO edit or CI `check:api-schema`
  fails (bit us on #422). Places autocomplete used EXISTING proxies (`/api/v1/google/places/*`), no new DTO.

**Earlier auth/live-sync PRs — MERGED:**
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

## Live-sync (web ⇄ iOS) — built, PR #416 MERGED + deployed

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

## ✅ Operator + Xcode setup — ALL DONE (2026-06-28)

Everything below is set up; recorded here so the next session knows the live config.

1. ✅ **`APPLE_CLIENT_ID`** (= bundle id `app.tovis.Tovis`) **set in prod Vercel** — Apple sign-in
   verifies tokens. (User confirmed set.)
2. ✅ **Xcode capabilities** — Team set (`DEVELOPMENT_TEAM = SB3J675LNU`); **Sign in with Apple** +
   **Push Notifications** capabilities added (`Tovis/Tovis.entitlements` has `aps-environment` +
   `applesignin`). **App icon** added (`Tovis/Assets.xcassets/AppIcon`) so the archive passes validation.
3. ✅ **APNs creds set in prod** (`APNS_AUTH_KEY`/`KEY_ID`/`TEAM_ID`/`BUNDLE_ID`). ⚠️ **`APNS_ENV`
   must be `production` for TestFlight/App Store** builds (distribution archives are production-signed);
   use `sandbox` only for a development build run straight from Xcode onto a device.
4. ✅ **Twilio Verify** for phone-OTP set in prod. ✅ **tovis-app `main` deployed to Vercel prod.**
   ✅ **Live on TestFlight.**

> Reminder: env-var changes only take effect on a **redeploy** (`cd ~/Dev/tovis-app && npx vercel@latest --prod --yes`).

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

> **🟢 THE BUILD BACKLOG IS EMPTY.** Polish items #1–#6 are all shipped (per-item ✅ detail below).
> The ONE remaining task is **LIVE VERIFICATION** — none of the polish features have been exercised on a
> device/sim against the backend; some (map cluster tap-to-zoom, place-jump, push-tap routing, Stripe
> `tovis://` redirect) genuinely can't be confirmed by a compile.

### 🔬 Live-verification checklist (the actual #1 next action)

1. **Start the stack:** `docker start tovis-dev-postgres` (or `pnpm db:dev:up`) → `cd ~/Dev/tovis-app &&
   pnpm dev`. If signed-in screens 500 with "table … does not exist", run the `prisma db push` from the
   env/DB note. Open Xcode (`~/Dev/tovis-ios/tovis-ios.xcodeproj`), iPhone sim, **⌘R (Debug → localhost)**.
   Sign in `client@tovis.app` / `password123`.
2. **Add-ons (#1):** open a pro/offering with add-ons → toggle add-ons → confirm total-duration pill
   updates + the booking finalizes with the add-ons. ⚠️ local seed may lack add-ons — may need to seed an
   `OfferingAddOn`, or point Debug at prod.
3. **Mobile booking + Places (#5a):** pick a mobile-capable offering → "Where" → Mobile → add a service
   address via **Places autocomplete** (type → pick suggestion → exact coords) → book. Confirm
   out-of-radius surfaces the backend message.
4. **Deposit (#3):** a booking with `depositStatus=PENDING` → "Secure your booking" card → Pay deposit →
   Stripe → returns via `tovis://` → flips to "Deposit paid".
5. **Rebook-confirm (#5b):** a booking with a pro-proposed BOOKED_NEXT_APPOINTMENT → Confirm/Decline card.
6. **Push deep-link (#2):** REAL DEVICE only (sim has no APNs) — booking push → tap → opens that booking.
7. **Looks video (#4):** a feed with VIDEO looks (local seed is sparse — point Debug at prod) → autoplay,
   loop, tap-to-mute.
8. **Discover (#6):** filter sheet (radius/sort/mobile) re-searches; **search-bar place autocomplete**
   recenters; **pin clustering** count bubbles → tap zooms + splits.
9. **Stripe `tovis://` redirect on-device** (the one non-built item): confirm `SFSafariViewController`
   auto-follows the bounce, else the "Return to the app" button.

---

**✅ DONE 2026-06-28 (latest session — all committed, build green, much verified live):**
- **Notifications** — in-app **center** (Track A) + **preferences editor** + **push/APNs registration**
  (Track B). Backend: typed DTOs **#419 merged** + **web client notification center #420 merged**.
- **Booking v2 — reschedule + cancel** (`BookingDetailView` Manage section; live round-trip verified).
- **App icon asset catalog** (unblocked TestFlight validation) → **SHIPPED TO TESTFLIGHT**.
- **In-app phone verification** (smooth Apple onboarding — `.needsVerification` + `PhoneVerificationView`).
- **tovis-app `main` deployed to Vercel prod**; `APPLE_CLIENT_ID` + APNs creds confirmed set.

**✅ DONE 2026-06-27 (prior session):**
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

**✅ The polish backlog (#1–#6) is COMPLETE — per-item detail below (all build/contract-verified; "Verified
live? No" on each → see the checklist above). Nothing here is left to build:**

1. ✅ **Add-ons in booking DONE 2026-06-28** — `BookingFlowView` now fetches `/offerings/add-ons`
   (`BookingService.addOns`, SALON/MOBILE-aware), shows a toggle-able **Add-ons (Optional)** section with
   per-add-on minutes/price + a live total-duration pill, and passes the selected **link ids** into
   `finalize(addOnIds:)` (was hard-coded `[]`). Matches web: add-ons don't touch the hold (only finalize),
   the server derives real duration/price, and reschedule keeps the original add-ons (section hidden).
   TovisKit: `BookingAddOn` model + `OfferingAddOnsResponse`; decode test + `offeringAddOns.json`;
   Debug+Release `xcodebuild` green. ✅ **Contract-validator entry added** — backend now exposes a typed
   `OfferingAddOnItemDTO` (**tovis-app PR #421**: `lib/dto/offeringAddOns.ts` + `satisfies` on the route +
   regenerated schema; also DRY'd the web's two duplicate local `AddOnDTO`s onto the shared one). iOS
   validator now schema-checks the fixture: **22 objects** (was 20). Verified live? **No —** still
   decode-only (round-trip a real `GET /offerings/add-ons` against a seed pro that has add-ons to confirm).
   ✅ **PR #421 MERGED.**
2. ✅ **Push deep-linking DONE 2026-06-28** — a push tap now opens the specific booking. `PushManager`
   reads the payload's **`href`** (the only custom key the backend sends — `lib/notifications/delivery/
   sendPush.ts`; e.g. `/client/bookings/bk_1`), parses it to a `PushDeepLink` (ContentView), the session
   publishes it, and `MainTabView` resolves the booking (via `bookings.fetch()`) and presents
   `BookingDetailView` over the shell. **Cold-launch taps** are buffered in `PushManager` and flushed once
   sign-in wires the handler. Unknown paths no-op (foreground + refresh). Booking is the only actionable
   client `href` today; the parser has a clean extension point. Debug+Release green; 22 tests. Verified
   live? **No —** needs a real-device push tap (simulator can't receive APNs); parser is build-checked only.
3. ✅ **Deposit-pay CTA DONE 2026-06-28** — `BookingDetailView` shows a "Secure your booking" card with a
   **Pay $X deposit** button when `checkout.depositStatus == "PENDING"`, opening the hosted Stripe deposit
   checkout (`CheckoutService.createDepositSession`, already existed) and handed back via the `tovis://`
   return (its `.deposit` kind flips the card to **Deposit paid**). TovisKit: `ClientBookingCheckout` gains
   `depositStatus` + `depositAmount`. Backend **tovis-app PR #422** adds both to `ClientBookingCheckoutDTO`
   + the client bookings list-route select (deposit columns optional on `buildClientBookingDTO` so other
   callers emit null — no web churn); schema regenerated. Fixture/decode updated; contract **22 objects**;
   Debug+Release green; 22 tests. ✅ **PR #422 MERGED.** Verified live? **No —** needs a booking with a real
   PENDING deposit to round-trip the deposit checkout.
4. ✅ **Looks video playback DONE 2026-06-28** — VIDEO looks now play like a native social feed.
   `Tovis/LookVideoPlayer.swift`: a **chromeless `AVPlayerLayer`** in a `UIViewRepresentable`
   (`LookVideoView`) — deliberately NOT `VideoPlayer`/`AVPlayerViewController` (those add transport
   chrome). `AVQueuePlayer`+`AVPlayerLooper` loop seamlessly; `.resizeAspectFill` fills the slide.
   `LooksView` plays **only the snapped slide** (via `.scrollPosition(id:)` → `isActive`); off-screen
   pauses + seeks to zero (one decoder at a time). **Muted by default** (shared so an unmute sticks
   while scrolling), tap toggles mute (speaker badge), unmute flips the audio session to `.playback`.
   Poster (`thumbUrl`) under the player until the first frame → no black flash. Debug+Release green;
   22 tests. Verified live? **No —** build-checked; needs a device/sim run on a feed with VIDEO looks
   (local seed feed is sparse — point Debug at prod to see real videos).
5. 🟡 **Booking v2 — MOBILE MODE DONE 2026-06-28; rebook-confirm DEFERRED.**
   ✅ **Mobile mode + address selection:** `BookingFlowView` now shows a **"Where" SALON/MOBILE switch**
   (when the offering offers both) and, for MOBILE, a **"Service address"** section listing the client's
   saved `SERVICE_ADDRESS` rows (default selected) + an **Add-address sheet** (`AddServiceAddressSheet`,
   typed form — backend geocodes on save). Switching mode re-bootstraps availability + add-ons; the hold
   carries `locationType` + `clientAddressId` (required for MOBILE); out-of-radius/verify errors surface
   the backend `userMessage`; Book is gated until a mobile booking has an address. TovisKit: `ClientAddress`
   model + `AddressesService` (`client.addresses`: list/serviceAddresses/create); `createHold` gains
   `clientAddressId`. Backend **tovis-app PR #423** adds typed `ClientAddressDTO` + schema (contract **24
   objects**). Fixture/decode added; Debug+Release green; 23 tests. ✅ **PR #423 MERGED.** Verified live?
   **No** — needs a pro with mobile enabled + a saved/added service address. NOTE: address add is a typed
   form (no Places autocomplete yet — that rides with #6).
   ✅ **Rebook-confirm DONE 2026-06-28** — there IS an authed path (no token needed):
   `POST /client/bookings/[id]/aftercare-rebook {action:"CONFIRM"|"DECLINE"}` (idempotency-key). CONFIRM
   creates the booking at the pro's proposed time + returns it; DECLINE sets `rebookDeclinedAt`.
   `BookingDetailView` shows a **rebook card** (proposed time + Confirm/Decline) when
   `hasPendingRebookConfirmation`. TovisKit: `ClientBooking` gains `hasPendingRebookConfirmation` +
   `rebookProposedFor`; `BookingsService.decideRebook(confirm:)`. Backend **tovis-app PR #425** adds both
   DTO fields (computed from `aftercareSummary` + the rebook chain: pending iff BOOKED_NEXT_APPOINTMENT ∧
   rebookedFor ∧ not-declined ∧ no active rebooked booking — hides after confirm) + the list-route select.
   Fixture/decode; contract **24 objects**; Debug+Release green; 24 tests. ✅ **PR #425 MERGED.** Verified
   live? **No** — needs a pro-proposed BOOKED_NEXT_APPOINTMENT to confirm/decline. **Booking v2 is now
   COMPLETE (mobile mode + rebook-confirm).**
6. 🟡 **Discover — FILTER SHEET + PLACES AUTOCOMPLETE DONE 2026-06-28; clustering DEFERRED.**
   ✅ **Radius/sort/mobile filter sheet** (`DiscoverFilterSheet`) — filter button (active-dot) → radius
   (5/10/15/25/50 mi), sort (Distance/Top rated/Price/Name), mobile-pros-only, Reset/Apply. Pure UI —
   `DiscoverService.searchPros` already accepted `radiusMiles`/`sort`/`mobileOnly` and the backend already
   honors them (NO backend/DTO work). ✅ **Google Places autocomplete** — `PlacesService` (`client.places`:
   autocomplete + details) over the **existing** backend proxies (`/api/v1/google/places/*`, server-only
   key — NO new backend). Wired into **`AddServiceAddressSheet`** (the mobile-booking address form): search
   → pick a suggestion → resolve to exact lat/lng via details → save with `placeId`+coords so the backend
   keeps them as-is (removes the typed-form re-geocode + "couldn't verify" failures). `AddressesService`
   gained `createServiceAddress(from: PlaceDetails)`. Decode test (**24 tests**); Debug+Release green.
   Places routes are Google-proxy passthroughs (not typed DTOs) → decode-only, no contract entry.
   ✅ **Places autocomplete in the Discover SEARCH BAR DONE 2026-06-28** — typing shows "jump to a place"
   suggestions (`PlacesService`, biased to map center, kind ANY); tap → details → recenter map + search pros
   near there (clears the text → location search). Free-text pro search still runs in parallel. Reuses
   PlacesService, no new backend. Debug+Release green.
   ✅ **Pin clustering DONE 2026-06-28** — grid clustering on the SwiftUI `Map` (no MKMapView rewrite):
   pins in the same camera-span-scaled cell merge into a count bubble (`ClusterPin`); tap zooms in and the
   cluster splits as cells shrink. Single-pin cells keep the selectable `ProPin` (selection unchanged).
   Debug+Release green. **#6 Discover build items are all complete.**
   🟡 Only remaining #6 item: **confirm the Stripe `tovis://` redirect on-device** (verification, not code).
   ⚠️ Map interactions (cluster tap-to-zoom, de-cluster on zoom, place-jump recenter) are **build-verified
   only** — exercise on a device/sim.

**Onboarding note:** native **email/password sign-UP** is still web-only (register has
captcha/TOS/SMS-consent/CLIENT_ZIP gates). **Apple + phone-OTP are the native account-creation paths**
(both auto-create accounts); Apple now finishes via the in-app phone-verify step (see the Auth section).

⚠️ **Xcode synchronized-folder note:** new Swift files in `Tovis/` only join the build once
Xcode's synchronized folder picks them up. CLI `xcodebuild` already sees them (build is green),
but if Xcode itself can't find a new view, open the project once so it registers.

## Key references

- Backend native-readiness handoff: `tovis-app/docs/mobile/native-readiness-handoff.md`
- Brand source of truth: `tovis-app/lib/brand/brands/tovis.ts`, `lib/brand/eyeSvg.ts`
- Wire contract for native models: `tovis-app/schema/api/tovis-api.schema.json` (+ `lib/dto/`)
- Push runbook: `tovis-app/docs/mobile/push-go-live-runbook.md`
