# Tovis iOS — PRO app + AI Photographer camera — RESUME HERE

> **Fresh-session entry point for the active workstream** (pro side + the AI camera).
> The big `HANDOFF.md` is the deep reference (client app history + full per-phase detail);
> this file is the short, current "where we are / what's next." Written 2026-06-28.
> Companion memory: `ios-pro-app-and-ai-camera` (auto-loaded via MEMORY.md).

## TL;DR

The **client** iOS app was already feature-complete (on TestFlight). This workstream added the
**PRO** side to the same app + an **"AI photographer" session camera**. All shipped work is committed
on `tovis-ios` `main`; the one backend change is **merged** (`tovis-app` PR #427).

## Repos & how to run / verify

| Repo | Path | Role |
|------|------|------|
| iOS app | `~/Dev/tovis-ios` | SwiftUI app + `TovisKit` package (this repo). **No git remote** — local commits only. |
| Backend | `~/Dev/tovis-app` | Next.js `/api/v1`. Branch per feature off `origin/main`; PRs. |

- **Run:** `docker start tovis-dev-postgres` → `cd ~/Dev/tovis-app && pnpm dev` (localhost:3000, local DB `:5434`). Open `~/Dev/tovis-ios/tovis-ios.xcodeproj`, iPhone sim, ⌘R (Debug→localhost). Sign in **as a PRO** to see the pro shell (a CLIENT lands on the client shell). Seed client: `client@tovis.app`/`password123` (CLIENT only — for a pro, use a real APPROVED pro account; role decides the shell).
- **Verify (run before committing):**
  - iOS: `cd ~/Dev/tovis-ios/TovisKit && swift test` (**50**); `cd ~/Dev/tovis-ios/scripts/contract && npm run validate` (**26 objects**); `cd ~/Dev/tovis-ios && xcodebuild build -scheme Tovis -project tovis-ios.xcodeproj -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO` (and `-configuration Release`).
  - Backend: `npm run typecheck && npm run lint && npm run check:static-guards` + `npx vitest run <paths>`.

## ✅ DONE (committed on `tovis-ios` `main`)

**Pro shell + footer** (`d2efa11`): role-based routing (`SessionToken.role` from JWT → `ProMainTabView`
vs client `MainTabView`); `ProTabBar` = web `ProSessionFooter` 1:1 (Looks · Calendar · live-session
center · Messages · Profile); `ProSessionModel` = native port of `useProSession` (GET `/pro/session`
+ poll, START/FINISH/PICK_BOOKING, session hub); `ProCalendarView` agenda (`GET /pro/calendar`);
`ProProfileTabView` (workspace switch via `POST /workspace/switch`). DRY: shared
`FooterNavItemLabel`/`FooterBadgeDot` + `BrandCoin` used by both bars.

**AI camera ladder:**
- **A** (`e9296b5`) — custom AVFoundation camera + before/after capture + upload pipeline
  (`ProMediaService`: presign→PUT→confirm) + hub gallery.
- **B1** (`ee494eb`) — on-device coach: `CoachEngine`/`CoachAnalyzer` (Vision face + CoreImage luma,
  ~6 fps) → one prioritized nudge + readiness ring; **Lighting + Composition** coaches; toggles
  (`CoachSettings`: tips/voice/haptics/grid/ring/auto-capture).
- **B2** (`48827d6`) — "Session Reel": auto-harvest best stills at readiness peaks (≥0.85, ≥1/2.5s,
  cap 24) → staged `BestShotsReviewView` (keep/upload).
- **B3a** (`11fe284`) — **silent** video clips (no mic) + `FrameScrubberView` (AVAssetImageGenerator)
  to extract the best still or save the whole clip (VIDEO) into session media.
- **B3b** (`1c4591c` iOS + `tovis-app` PR **#427 MERGED**) — client per-session **media-use consent**:
  `Booking.mediaUseConsentAt` + `publicShareGuard` honors it (3 call sites) + `POST
  /client/bookings/[id]/media-consent` + `ClientBookingDTO.mediaUseConsent`; iOS toggle in
  `BookingDetailView`. **Consent UNLOCKS the pro's publish action; never auto-publishes.**
- **More coaches** (this session) — `SharpnessCoach` (CoreImage edge energy on the subject
  region), `BackgroundCoach` (`VNGeneratePersonSegmentation` → background edge clutter),
  `PoseCoach` (`VNDetectHumanBodyPose` → level-shoulders / subject-clipping) added to
  `CoachEngine`'s coach list; the deferred **faceLuma backlit** signal is now computed so
  `LightingCoach`'s backlit branch is live. `FrameContext` gained `sharpness`/
  `backgroundClutter`/`pose`; the heavy Vision requests (segmentation + pose) run on a slower
  ~2–3 fps cadence (cached between runs) over a downscaled working image. Tuning divisors are
  hand-set heuristics (need on-device tuning). Builds Debug+Release; 26 TovisKit tests + 26
  contract objects green.
- **B4 calibration plan** (`7a7ef51`) — designed, NOT built (see below).

## ✅ PRO UI SUITE — Phases 3–5 (added 2026-06-28, committed on `tovis-ios` main)

The pro-side UI was built out beyond the shell. Each surface ships a TovisKit service +
wire models + fixture + decode test — all **decode-only** (like `proSession.json`: most
pro routes return inline shapes, so no ajv contract entry). Consolidated contract map =
**`docs/PRO-BACKEND-CONTRACTS.md`**. `swift test` **32** · contract **26** · `xcodebuild`
Debug **AND** Release green.

- **Phase 3 — booking detail** (`ProBookingDetailView`, `ProBookingService`): calendar
  agenda is the list (`GET /pro/bookings` doesn't exist); a row opens the detail
  (`GET /pro/bookings/[id]`) with **accept** / **cancel** (auto-refunds) / **propose next
  appt** (rebook) / contact tap-actions / **Open·Resume session** → hub.
- **Phase 4 — profile** (`ProProfileTabView` reworked + `ProProfileManageViews` +
  `ProProfileService`): header + stats + services + portfolio + reviews (read via existing
  `GET /professionals/{id}`, keyed by new **`GET /pro/profile`**), **Edit profile**
  (`PATCH /pro/profile`), **Manage services** (`GET/PATCH /pro/offerings` — toggle active +
  edit salon/mobile price+duration). 🔶 **Backend companion: tovis-app PR #428** adds
  `GET /api/v1/pro/profile` — **MERGE + redeploy prod before Release/TestFlight uses the
  profile tab** (Debug→localhost works once the branch is running).
- **Phase 5c — notification center** (`ProNotificationsView`, `ProNotificationsService`):
  web `/pro/notifications` parity (distinct shape: priority/seenAt/reviewId) — feed +
  icon/tint + unread dot + mark-read/all + pagination; a **bell w/ unread dot** on the
  Calendar nav bar (`GET /pro/notifications/summary`).
- **Phase 5b — working hours** (`ProWorkingHoursView`, `ProScheduleService`): per-day
  open/close + start/end pickers, save (`GET/POST /pro/working-hours`). Profile → Business.
- **Phase 5a — clients** (`ProClientsView`, `ProClientsService`): searchable directory
  (`GET /pro/clients/search`, view-gated) → detail (contact + service addresses + append-only
  **add note**). Profile → Business.

**🔲 Pro-UI sub-screens DEFERRED** (need backend aggregate GETs or lower-value): client
chart **HISTORY** read (server-rendered, no read API → needs `GET /pro/clients/[id]/chart`
DTO); aftercare **LIST** (per-booking `GET /pro/bookings/[id]/aftercare` exists; list needs
a DTO); pro **locations editor**, **payment-settings/membership**, **notification-preferences
editor** (prefs service methods already exist on `ProNotificationsService`); calendar
**day/week grid + block create/edit**; offering **CREATE/DELETE** (only toggle/edit shipped).
**Next pro step:** merge+redeploy PR #428 (✅ MERGED 2026-06-29), then live-verify the pro suite on the sim.

### 🔍 Web-parity — ✅ ALL 5 PAGES COMPLETE (2026-06-29 pass 2)

> **Full per-page detail = `docs/PRO-WEB-PARITY.md`** (status header updated). Every page now
> builds Debug+Release; `swift test` **38** green. The pass read the real web components and
> ported each 1:1 (copy quoted verbatim). Commit map (all on `tovis-ios` main):

- **Notification preferences** ✅ `f56697d` — `NotificationPreferencesView(surface:.pro)` reached
  from a gear in the pro notification center (DRY: one view serves client + pro).
- **Profile** ✅ — payment-settings sheet `94a2d9d`; fuller edit form (live handle check +
  suggestions, nameDisplay cards, profession type, avatar upload via AVATAR_PUBLIC) `26bd389`;
  tabbed shell (portfolio/services/reviews) + Your-link card (locked/reserve/live) + approval
  notice + stats + quick actions `71267fa`; services CRUD add(library picker)/delete/add-ons/
  image `93c3e08`.
- **Booking detail** ✅ `9ac2397` — rebuilt: header (Booking·#id + TOTAL + tap-for-directions),
  Timing timeline, Payment breakdown, Aftercare snapshot, Refund flow, web action set
  (PENDING→Accept/Cancel · ACCEPTED→Start booking/Cancel · IN_PROGRESS→Continue session). The
  **invented "propose next appointment" rebook card was REMOVED**.
- **Clients** ✅ — Add-a-client form `a74ddf3`; native **8-tab chart** + safety strip + do-not-rebook
  banner `a8066d0` (list now opens the chart for viewable clients).

**✅ DONE 2026-06-29 — backend PRs merged + first side-by-side sim walkthrough.**
The three additive backend PRs are **MERGED + prod redeployed**: **#431** `GET /pro/services/catalog`,
**#432** expanded `GET /pro/bookings/[id]`, **#433** aggregate `GET /pro/clients/[id]/chart`.
Did the first real Debug→localhost side-by-side walkthrough as a logged-in pro. Fixes (all on `tovis-ios` main):
- **Footer** — Looks tab renders the brand `TovisEye` mark (was `sparkles`) `41a5643`; center coin
  geometry matched to web `footers.css` 1:1 (bar 80 / coin 72 / raised ~20pt) `b7d146d`; **even 5-slot
  spacing** (reserved empty center slot — side buttons were crowding center), **brighter full-color ring**
  (thicker + blurred bloom + brightness lift), **readable cream START label** (was faint teal on the
  translucent coin), state-driven coin opacity (translucent idle / solid live), client `TovisTabBar`
  brought to the same geometry `b8244a0`.
- **CRITICAL notifications decode bug** `dd24af9` — `GET /pro/notifications` serializes `priority` as the
  enum NAME ("HIGH") but the native model had `priority: Int?` → the **whole feed threw** the moment a pro
  had any notification (empty feed + red "We couldn't read the server response."). The decode test passed
  only because the fixture used a numeric priority. Model→`String?` + fixture corrected; this also restored
  the `Unread(n)` chip + `Mark all read` button that the failed decode had suppressed.
- **Verified ✅:** booking-detail (verbatim copy, #432 data live), profile (Messages quick action
  **intentionally omitted** from a pro's view of their OWN profile per user), notifications.

**🔶 STILL OPEN — Clients list** (vs `app/pro/clients/page.tsx`):
- Copy drifts: missing header subtitle "Only clients you currently have access to (pending/active/upcoming).",
  missing "Client list" section header + `{n} visible` count, empty-state copy ("No clients with active
  visibility right now." + desc + **View profile** action) vs native "No clients yet.".
- **Functional Q (resolve before fixing copy):** web lists pending/active/upcoming-booking clients (the
  seeded Test Client has a *pending* booking → shows on web), but native `GET /pro/clients/search` shows
  "No clients yet." → investigate the search endpoint's default behavior. **Blocks live chart (#433)
  verification** (need a listed client to open the 8-tab chart).

**Deferred polish (unchanged):** pro **aftercare detail** screen (web "View full aftercare" link omitted —
no native destination); in-app **Message** deep-link from the clients list; per-tab chart **write forms**
beyond Add-a-note + technical-record encrypted-note **decryption** (web-only by design); **looks/followers**
profile stat tiles (web stat grid = 5: Rating·Reviews·Favs·Looks·Followers, native = 3; needs a small
`GET /pro/profile` stat add); contact/service-addresses view (`ProClientDetailView` is orphaned — re-link
or delete).

**⚠️ Sim-workflow gotchas (2026-06-29):** `xcrun simctl install` **wipes the Keychain session** every
reinstall → the pro is logged out after each rebuild (TokenStore = Keychain); batch fixes to minimize
rebuilds, and the user must re-login after each. Driving the sim via `osascript`/System Events is **blocked
by TCC** (`-25204`/`-25211`, even with Accessibility toggled on — the spawned osascript isn't the authorized
app) → fall back to user-navigates / `xcrun simctl io booted screenshot`. (A `simctl shutdown` mid-session
also logs out? No — reboot KEEPS the keychain; only reinstall wipes it.)

---

## ▶️ NEXT UP — CALENDAR full mobile parity (user: "the calendar is important", scope = **FULL mobile parity**, 2026-06-29)

**Decision (user-confirmed):** build the native pro Calendar out to **full web mobile parity**, not just polish.
This is the **biggest web↔native gap** of the pro pages and a **large, multi-step build** — do it incrementally,
commit per increment, `swift test` + `xcodebuild` Debug+Release each.

**Current native = agenda only** (`Tovis/ProCalendarView.swift`): stats tiles (Today / Requests / Open) →
"Pending requests" section → upcoming bookings+blocks grouped by day; tap a booking → `ProBookingDetailView`.
Bell → notifications sheet. Polls every 60s + refresh-tick. That's a *subset* of the web.

**Web mobile target = `app/pro/calendar/_components/CalendarMobileShell.tsx`**, which composes:
`MobileCalendarHeader` · `MobileCalendarControls` (Month/Week/Day **view switcher** + prev/next/**Today**) ·
`MobileMonthGrid` · `DayWeekGrid` (time-slot columns) · `MobilePendingRequestBar` · `MobileAutoAcceptBar` ·
`MobileCalendarFab` (+ block-time create) · `CalendarStatsPanel` · location bar. Modals:
`BlockTimeModal` (create), `EditBlockModal` (edit/delete), `BookingModal`. View state: `view: 'month'|'week'|'day'`,
`currentDate`, `onPrev/onNext/onToday`. Quote copy verbatim from these files.

**Backend — READY (verified 2026-06-29):**
- `GET /api/v1/pro/calendar` — returns `events[]` (BookingEvent|BlockEvent) + `stats` + `management`
  buckets `{todaysBookings, pendingRequests, waitlistToday, blockedToday}` + `timeZone`/`viewportTimeZone`.
  Uses `DEFAULT_CALENDAR_RANGE_DAYS` window. **✅ RESOLVED (inc.1): the route accepts `from`/`to` ISO query
  params** (`route.ts:437-452`, clamped to `MAX_CALENDAR_RANGE_DAYS`) — month nav needs **no** backend
  change; the native client just passes the view's range. Native model in `TovisKit/.../Models/*alendar*.swift`
  (`ProCalendarResponse/Event/Stats/Management`), service = `session.client.proCalendar.calendar(from:to:)`.
- **Block CRUD endpoints EXIST:** `POST/GET /pro/calendar/blocked` (create/list), `…/blocked/[id]`
  (edit/delete) → wire a native `ProCalendarBlockService` (or extend the calendar service) for the FAB +
  BlockTime/EditBlock modals.
- Availability: `GET /pro/availability/busy-days` (month dots), `…/availability`.

**Suggested increments (each its own commit, web copy verbatim, decode fixture + test per new DTO):**
1. ✅ **DONE 2026-06-29 (`c97b027`)** — **Month grid + view switcher.** `ProCalendarControls` (Day/Week/Month
   toggle + prev/Today/next + range label) + `ProCalendarMonthGrid` (6×7 Monday-start, per-day event dots);
   tap a day → that day's agenda. The visible range now drives the fetch (`calendar(from:to:)`). Pure date
   math (range/cells/header/step) in `TovisKit/.../ProCalendar/ProCalendarGrid.swift` + 6 unit tests
   (`ProCalendarGridTests`). Day/Week reuse the existing agenda rows. `swift test` **43** · Debug+Release green.
   ⚠️ NOT yet sim-verified (keychain wipe on reinstall → re-login needed). Default view = `.day` (web parity).
2. ✅ **DONE 2026-06-29 (`d33c20b`)** — **Block-time CRUD.** A "+" FAB (web `MobileCalendarFab`) opens
   `ProBlockTimeSheet` create; tapping a BLOCK row opens the same sheet in edit mode (fetches `GET
   …/blocked/[id]` for the note) with Save + Delete (confirm). Start/End pickers render in the calendar zone,
   client-side 15min–24h guard mirrors the server; server conflict/validation messages surface inline.
   New `ProCalendarBlock` + `ProLocationSummary` models, `ProCalendarService.{locations,createBlock,block,
   updateBlock,deleteBlock}`, 2 fixtures + 3 decode/encode tests. Create pins to a bookable location
   (`GET /pro/locations`, primary default, picker when >1); FAB hidden if none. `swift test` **46** ·
   contract **26** · Debug+Release green. ⚠️ NOT yet sim-verified.
3. ✅ **DONE 2026-06-29 (`1b1e18d`)** — **Day/Week time-grid.** `ProCalendarTimeGrid` ports the web
   `DayWeekGrid` (+ `_grid/TimeGutter`/`DayColumn`/`DayHeaderRow`/`EventCard`): a 24h vertical timeline at
   `PX_PER_MINUTE=1.5`, time gutter, 1 col (day) / 7 cols Mon-start (week), hour rules, a now-line on today,
   and event tiles positioned by their minutes-since-midnight window. Auto-scrolls to 8am. Tiles tap →
   booking detail (programmatic push) or block editor; **replaced the inc.1 agenda fallback for Day/Week**.
   Pure layout math (`eventDayMinutes`/`snap`/`minutesSinceMidnight`/`timelineDays`) added to
   `ProCalendarGrid` + 4 tests (`swift test` **50**). Contract **26** · Debug+Release green. ⚠️ NOT sim-verified.
   **Web parity gaps (deferred to polish):** working-hours shading (needs per-location `workingHours`), event
   drag/resize + tap-to-create (mouse-oriented; native uses the FAB + detail screen), side-by-side overlap
   columns (web also stacks full-width), sticky header inside the scroll.
4. **Bars/panels** ← **NEXT** — `MobilePendingRequestBar`, `MobileAutoAcceptBar`, `CalendarStatsPanel`,
   location bar. (Native already shows a stats strip + pending-requests section + bell; this increment is the
   auto-accept toggle, the dismissible top pending bar, and the location selector for multi-location pros.)

**House rules carry over:** web-parity 1:1 · no dup logic (reuse BrandSurface/Section/Pill/Avatar + the
agenda row) · decode-only fixtures unless an ajv contract entry is warranted · `requirePro` · backend changes
(if month-param needed) branch off `origin/main`, re-run `gen:api-schema` after DTO edits, typecheck+lint+
static-guards+vitest before push. Re-login after every reinstall (keychain wipe).

**Why booking-detail + clients weren't done this pass:** both need backend route work, and the
`tovis-app` checkout was on another active session's branch — branch-switching + `prisma generate`
during typecheck would clobber the sibling. Do these when the checkout is free (or in an isolated
worktree with its own node_modules to avoid the shared-prisma-client clobber).

## ⚠️ Make it FULLY FUNCTIONAL — device run + tune pass (do this FIRST)

The whole camera ladder **builds + unit-tests green but has never run against a real camera** — the
iOS Simulator has no camera, so `CameraController.start()` just lands in `.failed` there. Signing is
already set up (`DEVELOPMENT_TEAM SB3J675LNU`, automatic), so this is a device run, not more code.

**0a. End-to-end loop on a physical iPhone** (the functional proof). `docker start tovis-dev-postgres`
   + `pnpm dev`; build to a real device (Debug → localhost; the Mac + phone on the same network, or
   point at prod with Release). Sign in as a **real APPROVED pro** with an active session → session hub
   → camera. Walk: **shutter** → presign→PUT→confirm → photo lands in session media + shows in the hub
   gallery; **silent video** → frame scrubber → save still/clip; **auto-harvest** → best-shots review →
   upload. The upload contract + publish guard are live (#427 merged), so the backend is ready.

**0b. Tune the coach against real salon light.** Every perception threshold now lives in ONE file —
   **`Tovis/CoachTuning.swift`** — so tuning is edit-one-file → rebuild → re-watch. Watch the readiness
   ring + nudges on device and adjust: `sharpnessReference` (is everything called "soft"?),
   `clutterReference` (is a clean wall called "busy"?), `lumaTooDark/Bright/Ideal`, `shoulderTiltDegrees`,
   `harvestThreshold`/`readyThreshold`. Per-coach SCORE weights stay inline in `ShotCoach.swift` (design,
   not calibration). Defaults were set without a device — expect to move several.

## ▶️ NEXT (after it's functional)

1. **Web-client consent toggle** (closes B3b) — backend is **live on main** now (#427 merged); just add
   the same toggle to the web client aftercare/booking-detail surface (`app/client/(gated)/aftercare`
   + booking detail) calling `POST /client/bookings/[id]/media-consent { granted }`.
2. ~~**More coaches**~~ ✅ DONE this session (Sharpness/Background/Pose + faceLuma backlit). Still
   open from the original idea: a **HandPose** coach (`VNDetectHumanHandPose`). Extension point is the
   `ShotCoach` protocol — pure, Sendable, one per aspect; heavy per-frame Vision goes in `CoachAnalyzer`
   (throttled) and lands on `FrameContext`. **On-device tuning is now item 0 below.**
3. **Phase C** — before/after **comparison slider** → **publish to portfolio** (now unlocked by B3b
   consent) + the pro-facing "client allowed sharing" indicator (expose consent on
   `ProBookingMediaItemDTO`). Plus service-aware **ShotGuides** (curated shot lists/pose templates per
   profession/service) + onion-skin before/after alignment.
4. **B4 — NFC-card ColorChecker calibration** — full design + printable card spec in `HANDOFF.md`
   ("NFC card camera calibration"). Decided: full ColorChecker swatches → WB + exposure + 3×3 color
   matrix; NFC (CoreNFC) triggers + identifies card version. ⚠️ **Blocked on the physical card**: each
   print batch's swatch values must be measured + keyed by NFC card-version id.
5. **Phase D** — Claude vision critique (consent-gated; latest vision model; check the `claude-api`
   skill when implementing).

## Key contracts / recipes

- **Media upload (A):** sign `POST /pro/uploads {kind:"CONSULT_PRIVATE",bookingId,phase,contentType,size}`
  → **PUT** `${SUPABASE_URL}/storage/v1/object/upload/sign/{bucket}/{path}?token=` (headers `apikey`
  + `Content-Type` + `x-upsert:false` — ⚠️ **MUST be PUT**, POST → RLS 403) → confirm `POST
  /pro/bookings/{id}/media {uploadSessionId,phase,mediaType,caption?}`. Photos=IMAGE, clips=VIDEO.
- **Publish guard (B3b):** `lib/media/publicShareGuard.ts` — pro may make session media public iff
  public-bucket **OR** `reviewId` **OR** `Booking.mediaUseConsentAt`. All publish call sites must select
  `booking.mediaUseConsentAt` and pass it as the candidate's `clientUseConsentAt`.
- **Coach extension:** implement `ShotCoach { category; evaluate(FrameContext) -> CoachSignal }`, add to
  the `CoachEngine` init coach list. `FrameContext` carries pre-computed signals (extend it as needed).
- **Camera:** `CameraController` (AVFoundation; photo + video-data + movie outputs) — frame delegate =
  `CoachAnalyzer`. Video is **silent by design** (no mic input → no salon audio, no mic permission).

## Decisions log (user-confirmed 2026-06-28)

On-device coaching first (Claude critique later, consent-gated) · curated ShotGuides now (learn from
Looks engagement later) · custom AVFoundation camera · **video records silent** · best shots **staged
for review** (not auto-uploaded) · B3b consent = **per-session, client-granted, unlock-not-auto-publish**
· calibration card = **full ColorChecker + NFC trigger/identify**, built as Phase B4.

## House rules (carry over — from `tovis-app/CLAUDE.md`)

Web parity 1:1 · **no duplicated logic** (reuse brand/components/services) · contract fixture + decode
test + ajv entry per new screen/DTO · pro screens are `requirePro` (CLIENT 403s them) · backend: branch
off `origin/main`, no stacked PRs, re-run `gen:api-schema` after any DTO edit, run typecheck+lint+
static-guards+vitest before push. End of session: `tovis-app` local `main` level with `origin/main` +
clean tree.
