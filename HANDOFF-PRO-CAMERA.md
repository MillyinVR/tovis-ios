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
  - iOS: `cd ~/Dev/tovis-ios/TovisKit && swift test` (**26**); `cd ~/Dev/tovis-ios/scripts/contract && npm run validate` (**26 objects**); `cd ~/Dev/tovis-ios && xcodebuild build -scheme Tovis -project tovis-ios.xcodeproj -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO` (and `-configuration Release`).
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

## ▶️ NEXT (pick up here)

1. **Web-client consent toggle** (closes B3b) — backend is **live on main** now (#427 merged); just add
   the same toggle to the web client aftercare/booking-detail surface (`app/client/(gated)/aftercare`
   + booking detail) calling `POST /client/bookings/[id]/media-consent { granted }`.
2. ~~**More coaches**~~ ✅ DONE this session (Sharpness/Background/Pose + faceLuma backlit). Still
   open from the original idea: a **HandPose** coach (`VNDetectHumanHandPose`) and **on-device tuning**
   of the heuristic divisors (`sharpness` /0.12, `clutter` /0.18) + pose thresholds against real salon
   frames. Extension point is the `ShotCoach` protocol — pure, Sendable, one per aspect; heavy
   per-frame Vision goes in `CoachAnalyzer` (throttled) and lands on `FrameContext`.
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
