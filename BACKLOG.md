# Tovis iOS — open-work backlog

> Single source of truth for what's left to do on the native app. Created 2026-07-07
> by consolidating `HANDOFF.md`, `HANDOFF-PRO-CAMERA.md`, and `docs/PRO-WEB-PARITY.md`.
> The **client** app is feature-complete + on TestFlight; the **pro** side + AI camera
> are the active build track. Backend/DTO counterpart work lives in `tovis-app/docs/BACKLOG.md`.
> Evergreen reference stays put: `README.md` (setup + services map), `docs/PRO-BACKEND-CONTRACTS.md`
> (pro `/api/v1` contract index), `docs/calibration/README.md`, `scripts/contract/README.md`.
>
> `[ ]` open · `[~]` partial · **(device)** needs a real device (sim has no camera/APNs).

---

## ⭐ Work order — priority sequence

**Master cross-repo sequence lives in `tovis-app/docs/BACKLOG.md` (⭐ Work order,
Tori 2026-07-08).** We work that tier order, not section number. Where the iOS items land:
- **Tier 1:** **A7** — email-verification completion (blocks email/password signup;
  detail in `tovis-app §15`).
- **Tier 3:** ~~§7 messaging **M3–M5**~~ ✅ DONE (#14–#17) · ~~§6 post-payment read-endpoint
  follow-up~~ ✅ DONE (#24). Tier 3 is clear on iOS.
- **Tier 4:** §5 **A1** residual (pro onboarding checklist + license/doc verification —
  the rest of A1 is SHIPPED, see the ⚠️ note on A1 below) · ~~**A8** Google Sign-In
  (`tovis-app §15`)~~ ✅ DONE 2026-07-11 (iOS-only; see A8 entry) · §5 **A2** client
  screens · **A3** booking detail · **A4/A5** pro parity.
- **Tier 7/8:** §1 live-verification · §2 launch train (**App Store upload**) · §3–§4
  deferred pro polish · camera polish (`tovis-app §17`) · **A9** TikTok (parked, `tovis-app §15`).

### ✅ Recently shipped (iOS, through 2026-07-09)
- **§6 PF5 — booking-detail payment-confirm surfaces (#24)** — consumes the new
  `checkoutStatus` + `rebookOfBookingId` read fields (web #550): pro `ProBookingDetailView`
  Payment card gains "Confirm payment received" (AWAITING_CONFIRMATION → confirm-payment route,
  auto-approves the coupled next booking); client `BookingDetailView` shows a "Pending — your pro
  will confirm" notice on a coupled aftercare PENDING rebook. Clears all §6 deferred niceties.
- **§7 messaging M3–M5 — inbox/thread refinement (#14–#17)** — filter tabs + context eyebrows
  (#14), "load earlier" paging (#15), image attachment composer (#16), thread deep-link +
  pro→client entry points (#17). The §7 epic is complete on iOS.
- **A7 — in-app email-verification completion screen (#18)** — resend + status re-check
  advancing to `.signedIn` (pairs web #546). Clears the Tier-1 email/password dead-end.
- **§12 NC4 — in-app notification-string parity (#19)** — server-fed strings mirror web copy;
  fixed the stale "Push — Coming soon" preferences label.
- **§12 NC5 — push deep-link routing + cross-shell switch (#20)** — `URLComponents` parse
  (`?step=`/`#review` survive), full Target→href map, role-aware client↔pro workspace switch;
  both `MainTabView` + `ProMainTabView` route symmetrically. **Tap path still device-verify only**
  (no APNs on sim — see §1 device checklist).
- **§12 NC5 residual — per-screen step-jump (#22)** — destinations now open scrolled to the
  deep-linked section instead of at the top: `ProReviewsListView` → the tapped review (parser
  now lifts the id from the `/pro/reviews#review-{id}` fragment, which was being dropped),
  `BookingDetailView` → consult / aftercare (Photos & sharing), `ProBookingDetailView` →
  aftercare. Reuses the `ThreadView` proxy-into-loader scroll pattern; one-shot per load. Tap
  path stays device-verify only.
- **A1 residual — native license/document verification screen (#9)** — shrinks A1 to the pro
  onboarding-readiness checklist (see the A1 note below).

---

## 1. Live-verification pass (nothing below is a build — it exercises shipped code)
Start the stack (`docker start tovis-dev-postgres` → `cd ~/Dev/tovis-app && pnpm dev`), Xcode ⌘R (Debug → localhost), sign in `client@tovis.app`/`password123`.
- [ ] Client polish #1–#6 live-verify: add-ons total-duration + finalize · mobile booking + Places autocomplete · deposit-pay CTA (`tovis://` return) · rebook-confirm card · Looks video autoplay/loop/mute · Discover filter sheet + place-jump + pin cluster tap-to-zoom.
- [ ] **(device)** Stripe `tovis://` redirect: confirm `SFSafariViewController` auto-follows the bounce (else the "Return to the app" button) — the one item a compile can't confirm.
- [ ] **(device)** Push deep-link tap → opens the specific booking (sim has no APNs).
- [ ] Pro suite sim-verify: Phase S session flow end-to-end (consult→send→approve→before→service→finish→after→wrap-up→mark-paid→aftercare), header tabs, calendar block CRUD + pending Approve/Deny (needs a PENDING booking in range), client 8-tab chart. None sim-verified.
- [ ] Camera on-device tune pass — never run against a real camera. Tune `Tovis/CoachTuning.swift`; hardware-verify level sign, face-exposure point mapping `(x,y)→(y,1−x)`, onion-skin alignment, EXIF orientation in the web gallery, WB gains, card-scan flow.
- [ ] Supabase Realtime ws smoke test: does the `sb_publishable_…` key authenticate the Realtime websocket? (Falls back safely to poll/focus if not — see `tovis-app/docs/runbooks/live-sync.md`.)

## 2. Launch train (outshine step-9)
- [ ] **(Tori/Xcode)** Archive → Validate → Upload (+ version/build bump).
- [ ] Optional: D3 board viewer on iOS.
- [ ] Board-creation context parity (web PR tovis-app#511, personalization spec §7–8): board type chips + event date + skippable chip questions in the board create/save-to-board flow, and the "N days until …" countdown on a board. API is additive (`type`/`eventDate`/`answers` on POST/PATCH `/api/v1/boards*`; question sets in `tovis-app/lib/boards/context.ts` are the SSOT) — iOS keeps working untouched, boards it creates default to GENERAL, so parity is deferred, not blocking.
- [ ] Self-profile parity (web PR tovis-app#513, personalization spec §6.6): a "Get better matches" settings screen (hair type/length/color, skin type/concern, category-interest chips — all optional, tap-to-clear) backed by additive `GET/PATCH /api/v1/client/self-profile`, plus the board-creation "save these details to my profile" opt-in (`writeThroughSelfProfile: true` on POST `/api/v1/boards`). Chip questions/values in `tovis-app/lib/personalization/selfProfile.ts` are the SSOT. Server-side ranking effects (affinity decay, interests boost, per-category prior) apply to iOS clients automatically — parity is deferred, not blocking. Natural pairing: build together with the board-context parity item above.
- [ ] Board-feed "Recommended for this board" parity (web PR tovis-app §4.4, personalization spec §4.4): a ranked recommendations section on a board detail screen, backed by the additive owner-only `GET /api/v1/boards/{id}/feed` (returns the standard looks-feed DTO — same card model iOS already renders elsewhere; supports `?limit=&cursor=&seen=`). DEFERRED because iOS has no board detail screen yet (only `SaveToBoardSheet.swift`); it pairs with the "D3 board viewer on iOS" + board-context parity items above. The endpoint personalizes to the board's purpose/answers/saved-look taste server-side, so once a board viewer exists on iOS this is just wiring one more fetch — not blocking.
- [ ] Source-tagged view impressions parity (web PR tovis-app §5.6, personalization spec §5.6): tag `recordViews` with where the view happened. iOS currently posts `POST /api/v1/looks/views` as the legacy `{ lookPostIds: [...] }` shape (`LooksView.swift` → `LooksClient.recordViews`), which the server reads as **FEED**-sourced — so iOS feed impressions are already correctly attributed and **nothing is broken**. Parity = switch to the source-tagged body `{ impressions: [{ lookPostId, source }] }` (source `"FEED"` / `"DETAIL"`; server enum `LookImpressionSource`, coerces unknown→FEED) and tag detail-screen opens as DETAIL if/when iOS records them. Small, additive, non-blocking — the windowed per-source aggregate that backs the anti-gaming velocity check is a server concern.

## 3. Pro-side build work
- [ ] **Workstream 2 — multiple co-equal BASE services per booking**: core backend invariant change; investigate every `baseCount===1` assumption and get sign-off before implementing.
- [ ] **B4 — NFC ColorChecker calibration** (`docs/calibration/README.md`): blocked on physical cards — measure each print batch's swatch values, key by NFC card-version id, wire CoreNFC (`CameraCalibration` module: WB/exposure lock + `CIColorMatrix`).
- [ ] Web-client media-consent toggle (closes B3b): backend live (#427 merged); only the web UI remains (this is a tovis-app task — mirrored in `tovis-app/docs/BACKLOG.md`).

## 4. Deferred web-parity polish
Source: `docs/PRO-WEB-PARITY.md` (all 5 pages parity-complete; these are the tail).
- [x] **A-VIS1** Pro "Your visibility" — native parity for the web §6.5 pro
  transparency section on `/pro/dashboard` (tovis-app PR #643, personalization
  Step 15). `ProVisibilityView` (Profile tab → Growth) renders the ranked
  visibility levers off the new `GET /api/v1/pro/visibility` — the same loader
  the web page uses, so the two can never tell a pro a different story. New
  `TovisKit/ProVisibility/` model + service; `ProVisibilityStatus` decodes with
  an `.unknown` fallback so a status added server-side degrades to "not measured
  yet" instead of blanking the screen on an older build. The screen holds NO
  thresholds and no ranking knowledge — it renders generically from server
  status + copy, so a new lever needs no client release. Fixture
  `proVisibility.json` registered in `scripts/contract` (validates green).
  **SHIPPED (PR #144)**
  - [ ] **A-VIS1a — deferred:** the levers' fix actions render as guidance TEXT,
    not buttons. Each `action.href` is a WEB pro path (`/pro/calendar`,
    `/pro/services`, `/pro/media/new`, …) and the native equivalents live in
    OTHER tabs, so deep-linking needs cross-tab navigation plumbing plus an
    href→destination map that would rot as either side moves. The labels are
    written to stand alone, so v1 loses only the tap. Wire it when a general
    web-path→native-route resolver exists (the same primitive several deferred
    items want).
- [x] **A-AC1** Pro aftercare-detail screen — renders the before/after visual
  record (new shared `AftercareBeforeAfterPair`, also adopted by the aftercare
  list). Fed by the `media` pass-through on `GET .../aftercare` (tovis-app #554);
  screen stays text-only until that deploys. **SHIPPED (PR #27)**
- [x] **A-AC2** Aftercare featured-pair PICKER on the pro authoring screen —
  parity with web #561/#562 (tovis-app §24 AF3a). `ProAftercareAuthorView` loads
  the before/after candidates (existing `GET .../media`), shows Before/After grids
  with a "Feature" pill (image-only, one per phase, re-tap to clear), seeds from
  the saved pair, and sends the validated ids on save. New DTO fields
  (`featuredBefore/AfterAssetId` on the summary + save request) + pure
  `AftercareFeaturedPair` helper (partition + `resolveValidFeaturedId`, unit-
  tested). **Also fixes a cross-platform regression:** iOS previously omitted the
  featured ids, so any native aftercare save wiped a web-set pair (the server
  always writes them, coercing an absent field → null). No web/server change, no
  migration. **SHIPPED (PR #31)**
- [ ] In-app Message deep-link from the clients list.
- [x] Per-tab chart write forms + technical-record decryption. ✅ #31 (write forms) + #48 (technical record).
- [ ] Looks/followers profile stat tiles.
- [ ] Orphaned `ProClientDetailView` — re-link or delete.
- [ ] Pro sub-screens: locations editor (create/edit/set-primary/publish), payment-settings/membership, offering CREATE/DELETE (only toggle/edit shipped).
- [x] Calendar parity: **tap-to-create ✅, drag-to-reschedule ✅ (#99/#100), booking-override retry dialog ✅, passive double-book warning ✅ (#104 tiles/reschedule + #105 new-booking form), side-by-side overlap columns ✅ (#116), working-hours shading ✅ (#117), `ManagementModal` message + confirm-deny ✅ (#118), drag haptics ✅ (#119), bottom-edge resize ✅ (#121), cross-day week drag ✅ (#122), drag blocks ✅ (#123), cross-WEEK drag ✅ (#127), salon+mobile working-hours merge ✅ (#130).** Drag follow-ups all done — the day/week time-grid is at web parity. **⚠️→✅ #124: the drag/resize/cross-day/blocks (#121-#123) were BROKEN on a physical device — tiles were untappable (tapping opened New Booking) because tile `.offset` was applied before `.contentShape`+gestures, pinning the hit target to the un-offset frame ([[swiftui-offset-hittest-order]]). #124 fixes it (offset outermost) + decoupled simultaneous arm-then-drag + all-bookings-draggable (web parity) + live cross-day horizontal follow. Device-verified by Tori: tap/lift/drag/resize/cross-day all work.**
  - **Cross-WEEK drag ✅ (#127).** Dwelling a lifted tile at the week-view left/right edge paginates one week and the drag KEEPS GOING, so it drops on a day in a different week (web parity, tovis-app #610). The move gesture was hoisted OUT of the events/column-keyed subtree into a grid-level UIKit `UILongPressGestureRecognizer` (`TimelineMoveDrag`, installed on the enclosing UIScrollView) so it survives the SwiftUI re-render a page-turn triggers — a per-tile SwiftUI gesture tears down when the dragged booking leaves the refetched `events` array. `CalendarDragState` now carries a full `ProCalendarEvent` snapshot + a floating proxy tile (`dragProxy`) draws it independent of `events`/`days`; pure `ProCalendarGrid.edgePageDirection(globalX:…)` + `EdgePageDirection` pick the edge band (7 tests); the Coordinator runs the ~0.6s edge-dwell timer (one page per dwell, re-armed on leaving the band). Bottom-edge resize stays per-tile (never crosses columns). Gesture needs a manual device pass.
  - **ManagementModal message + confirm-deny ✅ (#118).** The four-tab sheet already had lists + actions; closed the last web gaps — a "Message" action on booking + waitlist rows (reuses `openBookingThread` / `openWaitlistThread` → `ThreadView`) and a two-step Deny→Cancel/Confirm-deny guard. iOS-only. Eyeballed pending (default + armed) + waitlist.
  - **Side-by-side overlap columns ✅ (#116).** Overlapping bookings/blocks used to stack (only the amber double-book ring signalled it); now they lay out in Google-Calendar-style columns. Pure `ProCalendarGrid.overlapColumnLayout(_:)` sweep-line packer in TovisKit (cluster by transitive overlap → first-fit column → `columnCount` = cluster peak concurrency; bookings AND blocks included; 8 tests); `ProCalendarTimeGrid.dayColumn` wraps a `GeometryReader` and gives each tile `frame(width: colWidth)` + `offset(x:)`. Amber conflict ring kept on top. iOS-only enhancement (web also shows only the amber signal — no web PR). Eyeballed day + week on the simulator.
  - **Working-hours shading ✅ (#117).** Each day column dims the hours outside the pro's working window. Pure `ProCalendarGrid.offHoursSegments(week:date:timeZone:)` in TovisKit (closed day → whole column; same-day → before-open + after-close; overnight → middle gap; bad times → no shade; 6 tests); `ProCalendarTimeGrid` takes an optional `workingHours: ProWeekHours?` and draws dimmed non-interactive Rectangles behind the grid; `ProCalendarView` loads the primary bookable location's week (reusing `ProWorkingHours.locationToEdit`). No new endpoint. Eyeballed day + week.
    - **Salon+mobile working-hours merge ✅ (#130).** Closed the #117 deferral: the grid now dims outside the UNION of every bookable location TYPE's window (web `_grid/DayColumn` `mergeWindows` of salon + mobile), so a dual-location pro who works the salon by day and mobile in the evening sees BOTH windows un-shaded. New pure `ProCalendarGrid.workingIntervals` + `mergedOffHoursSegments(weeks:date:timeZone:)` in TovisKit (single-week fast-path = byte-identical to the old `offHoursSegments`, incl. bad-data-no-shade; multi merges working intervals then inverts; all-closed → whole column; 8 new tests). `ProCalendarView.loadWorkingHours` now fetches the primary bookable salon AND mobile-base week → `workingWeeks: [ProWeekHours]`; `ProCalendarTimeGrid` takes `workingWeeks`. iOS-only enhancement (no web PR). Single-location pros unchanged. ⚠️ The merged shading needs a logged-in DUAL-location pro to eyeball (this env's sim session is expired); unit-tested + builds clean.
    - The other #117 deferral — **location-vs-viewport timezone — is a no-op for parity, NOT open.** Web's `viewportTimeZone` IS the selected location's tz (`selectedLocationTimeZone ?? profileTimeZone ?? 'UTC'`), and iOS already feeds `calendarTimeZone (= viewportTimeZone)` into the shading. Web treats both salon/mobile `HH:MM` as wall-clock in that single display tz (no per-location conversion), so iOS is already at parity. Per-location tz conversion would be over-parity + risk a working feature — intentionally not done.
  - **Passive double-book warning follow-up ✅ (#105).** #104 shipped the overlap ring/glyph on calendar tiles + the "overlaps {client}" note in the drag-reschedule confirm (paired web tovis-app#584; conflict-detection audit finding #1, "passive warning only"). #105 adds the same heads-up in the **new-booking form** (`ProNewBookingView`) when a pro places a brand-new booking on a colliding time: a debounced `GET /pro/calendar` fetch around the proposed window (scoped to the picked location — same source as the grid signal) → new pure `ProCalendarGrid.overlappingClientNames(proposedStart:proposedEnd:events:fallbackName:)` (native mirror of web `overlappingClientNamesForRange`, half-open, dedup'd, BLOCK events filtered) → soft amber "This overlaps {client}. You can still book it." note under the time picker. Non-blocking; the server still allows the overlap. Paired with web tovis-app#607.
  - **Drag-to-reschedule follow-ups** — #99 shipped drag-to-MOVE a PENDING/ACCEPTED booking (long-press to lift → vertical drag → confirm → PATCH `/pro/bookings/{id}`, snapped 15-min, time-only within a day column); #100 hardened the gesture to `.global` coordinate space; **#111 fixed the gesture never arming at all** (field test 2026-07-11 / tovis-app §26): the long-press→drag lost arbitration to the tile's inner tap + the ScrollView pan — now `.highPriorityGesture` + `.scrollDisabled` while lifted. ⚠️ Dropping onto an *occupied* slot also needs web #593 deployed (server-side pro-overlap gate). Deferred:
    - [x] **Resize ✅ (#121)** — drag a tile's bottom edge to change duration. New pure `ProCalendarGrid.resizedDurationMinutes` (start fixed, snap the end, clamp to `[step, min(maxDuration 12h, day-remaining)]`; mirrors web `resizeDurationFromPointer`, +8 tests) + `ProBookingService.resizeDuration` (PATCH `/pro/bookings/{id}` `{durationMinutes}`, same override/idempotency contract as `reschedule`). A bottom-edge grab handle (long-press-armed like the move gesture, high-priority overlay sibling so it wins the edge vs the move gesture; ScrollView disabled while active) sets `pendingResize`; the move + resize confirm/override/error flows were unified into one `PendingCalendarChange` (move|resize) machine. Guards a no-drag release against the zero-drag resting duration so an off-grid tile doesn't spuriously resize. ⚠️ **Gesture arbitration (edge-resize vs move vs tap) needs a manual device pass** — this env can't inject drags.
    - [x] **Cross-day drag in week view ✅ (#122)** — a week-view drag can now land in a different day column. Each day column publishes its global x-extent via a `DayColumnFramesKey` preference; on drop, new pure `ProCalendarGrid.dayColumnForX` (half-open bands, +4 tests) resolves the release x → target `dayYmd`, and the move lands at the same dropped time-of-day on the new day (the confirm names the new date). Day view keeps its single column. ⚠️ v1 has **no live horizontal follow** (the dragged tile would render behind sibling columns without a grid-level overlay lift) and **no optimistic cross-day render** (the target column has no tile for the event until the reschedule lands) — the confirm dialog is the feedback; both are polish follow-ups. Gesture needs a manual device pass.
    - [x] **Drag blocks ✅ (#123)** — blocks now drag (move + bottom-edge resize) like bookings; both route to `updateBlock` (PATCH `/pro/calendar/blocked`, absolute window) instead of the booking endpoint, branched in `submitChange` (no notify/override flags; note preserved by omitting it; server hard-rejects overlaps so no passive double-book note). **Also fixed a latent block-id bug:** the calendar API namespaces a block event's `id` as `block:{id}` and sends a bare `blockId`; iOS was passing the namespaced `id` straight to `…/blocked/{id}` (would 404). Added `blockId` + a `calendarBlockId` resolver (prefer `blockId`, else strip the prefix, else raw — backward-compatible) and routed `openBlockEditor` / `openBlockFromManagement` / the new drag through it. Cross-day block moves work too (shared move gesture). Gesture needs a manual device pass.
    - [x] **Drag haptics ✅ (#119)** — `DragHaptics` ViewModifier on the grid: firm impact on lift, light selection tick on each 15-min snap, solid impact on drop. (Also extracted the ScrollView into a `timeline` computed property — the inline `.sensoryFeedback` closures pushed `body` past the type-checker limit.) Device-only feel; extraction verified render-identical on the sim.
- [ ] Client card-on-file (needs the Stripe iOS SDK).
- [ ] **Looks feed badge pill** (deferred parity with web tovis-app
  `feat/algo-badge-engine`, personalization spec §5): `GET /api/v1/looks` items
  now carry an optional `badge: { kind, label, tone } | null` — a server-computed
  live-data badge ("Booking fast" · "N bookings in 30 days" · "% of clients
  rebook" · "New to {brand}" · "Booked N× this week" · "42 days until your
  wedding" · "About N miles away"), one per card, already commitment-tier-guarded
  and holdout-sampled server-side. iOS decoding ignores the unknown key today, so
  nothing breaks. Parity = (1) decode the field in TovisKit's feed DTO and render
  a pill on the feed card (label is pre-composed — render verbatim, map `tone`
  accent/info/success/warn/neutral onto the token palette); (2) optionally send
  `viewerLat`/`viewerLng` query params (same location the availability drawer
  uses) to light up the distance badge. No write path; server does all selection.
- [ ] **Looks feed "Not for me" hide control** (deferred parity with web tovis-app
  `feat/algo-hide-control`, personalization spec §2.2): web added a one-tap
  "Not for me" control on every feed card (action rail, `EyeOff` icon) that removes
  the card and `POST`s `/api/v1/looks/{id}/hide` (idempotent; `DELETE` un-hides;
  response `{ lookPostId, hidden }`). A hidden look is then excluded server-side
  from that viewer's personalized, chronological, AND board feeds, and repeated
  hides in a category apply a decayed category-level suppression to ranking —
  all server-side, so an iOS viewer's hides made on web already shape their feed.
  Parity = (1) a hide/"not for me" affordance on the iOS feed card (overflow or
  rail) calling the additive `POST .../hide` and dropping the card locally; the
  server excludes it from every subsequent serve. Requires being signed in
  (`requireUser` → 401 for guests, bounce to login). Small, additive, non-blocking.
- [ ] **ACCOUNT_EXISTS log-in bridge on client signup** (deferred parity with web
  tovis-app #593 / `tovis-app §27 C1`): when signup hits "account already exists,"
  web now offers a "log in to continue" link prefilled with the typed contact;
  `ClientSignupView` just shows `session.errorMessage` with no bridge. Needs the
  error `code` plumbed through TovisKit (`AuthService`/`SessionStore`) so the view
  can distinguish `ACCOUNT_EXISTS`, then a button into the existing login screen.

## 5. Web↔iOS parity epic (audit 2026-07-08)
Comprehensive screen-by-screen audit of both apps (findings + Tori's layout
decisions in tovis-app memory `HANDOFF-web-ios-parity`; master roadmap +
web-side workstreams in `tovis-app/docs/BACKLOG.md §9`). Goal: every page matches
across web + iOS (camera / IAP / NFC / SEO excepted); parity = level **up**.
§4 above (the old PRO-WEB-PARITY tail) folds into A4/A5 below — this §5 is the
superset (adds auth + the full client surface). One screen/PR per session.

**Accepted divergences (leave as-is):** camera / best-shots / frame-scrubber +
wrap-up AI photographer-review (iOS-only, correct); membership purchase stays
web-only (Apple IAP — iOS display-only is right); NFC card/short-code stays web;
public SEO `/p` pro-vanity mirror stays web (iOS renders the native pro profile
instead). ~~claim ACCEPTANCE stays web~~ — **SUPERSEDED 2026-07-11:** native
now accepts claims (`/claim/<token>` Universal Link → `ClaimView` → signup with
intent=CLAIM_INVITE + inviteToken adopts the profile; cold self-serve
`CLAIMABLE_HISTORY` handled in `ClientSignupView`). Backed by web
`GET /api/v1/public/claim/[token]` (tovis-app #587) + adopt/self-serve
(#585/#586).
NOT accepted divergences (they're A2 build items): the public *client* profile
`/u/[handle]` + public boards are social surfaces (looks/stats/follow), not SEO.

- [ ] **A1 — native auth.** ⚠️ **"Biggest structural gap" framing is STALE —
  reconciled by `tovis-app §15` (2026-07-08 audit):** native signup/login is largely
  SHIPPED (role chooser · client + pro 3-step signup on real `POST /auth/register` ·
  phone OTP · Sign in with Apple · forgot/reset · **App Attest landed** in lieu of
  Turnstile). **Remaining A1 = pro onboarding readiness checklist + pro license/document
  verification only.** The two real auth gaps are separate items: **A7** (email-verify
  completion — Tier 1) + **A8** (Google Sign-In — `tovis-app §15`). Original pre-build
  scope kept for reference: signup role chooser → client
  signup (name/ZIP-geocode/phone/SMS-consent/email/password/TOS + Turnstile) →
  pro 3-step signup (work → about → account) → phone verify (already exists) +
  email-verify half → forgot/reset password → pro onboarding readiness checklist
  → pro license/document verification. Endpoints exist on web
  (`/api/v1/auth/register`, `/password-reset/*`, `/email/verify`, verification-docs).
- [x] **A8 — Google Sign-In (web-parity port)** — ✅ **DONE 2026-07-11 (iOS-only, no
  web change).** Cloned the Apple path: added **GoogleSignIn-iOS 9.2.0** as the app
  target's second remote SPM dep (project.pbxproj 6-edit recipe, memory
  `ios-first-remote-spm-dependency`) — SDK stays OFF TovisKit (UI SDK). TovisKit:
  `GoogleLoginRequest` + `AuthService.googleLogin(identityToken:deviceId:)` → the
  already-live `POST /api/v1/auth/google`; `TovisConfig`/`TovisClient` gained
  `googleClientID` (iOS OAuth id) + `googleServerClientID` (web OAuth id). App target:
  `GoogleSignInFlow.idToken(...)` presents the SDK sheet (shared
  `UIApplication.topPresentedViewController()` extracted from the Stripe view),
  `SessionModel.googleLogin` routes the result through `handleAuthResult`, and
  `LoginView` shows a "Continue with Google" button **gated on both ids being set**
  (inert otherwise — parity with web's `NEXT_PUBLIC_GOOGLE_CLIENT_ID`). Verifier
  detail: the SDK stamps `serverClientID` as the id-token's `aud`, which
  `lib/auth/googleIdentity.ts` pins, so no web change. +2 TovisKit tests (suite 400
  green); `xcodebuild build` green. **⚙️ Provisioning (deferred, not blocking — the
  button is hidden until then):** in one Google Cloud project set `googleIOSClientID`
  + `googleWebClientID` in `TovisConfig.swift` (both nil today) and add the iOS
  client's reverse-client-id (`com.googleusercontent.apps.<id>`) as a
  `CFBundleURLSchemes` entry in `Tovis/Info.plist`.
- [ ] **A2 — first-class client screens** (today folded into Me/Home/Notifications
  or absent): **Settings hub** (biggest — profile edit, public handle, discovery
  location, saved addresses, payment methods, notif prefs) · Activity feed ·
  Aftercare inbox · Priority Offers (claim) · standalone Openings feed · Referrals
  activity list · Boards detail + create + share/event-countdown (iOS shows
  read-only preview tiles today) · ~~public client profile `/u/[handle]` viewer~~
  ✅ **SHIPPED 2026-07-10 (iOS #78)** — `PublicClientViewerView(handle:)` +
  `PublicClientService` (GET `/u/{handle}` reusing `ProClientPublicProfile`; POST
  `/client/follow/{handle}` toggle reusing `FollowState`). Shared render extracted
  to `PublicClientProfileContent` + `PublicProfileStats` (native mirror of web
  `PublicProfileView`/`ProfileStats`); `ProClientPublicProfileView` now reuses it
  (mode `.hidden`). Follow modes own/client/hidden (native is always authed → no
  guest). Entry point: Looks-feed client-author `@handle`/avatar now
  `NavigationLink`s (was a dead-end); `LooksClientAuthor` made `Hashable`.
  **iOS-only** (web routes are the frozen native surface #388/#389). +4 tests,
  swift test 294. · Share-your-look publish flow.
- **A3 — client booking detail** — add web's aftercare pieces to `BookingDetailView`.
  Scoped 2026-07-09 (audit of web `app/client/(gated)/bookings/[id]/page.tsx` +
  `_data/loadClientBookingPage.ts` + each named component). **IA decision (Tori
  2026-07-09): keep the native single-scroll, state-gated layout — do NOT rebuild
  to web's top tabs** (native idiom; the view already surfaces consultation/
  aftercare/payment by state). Add the new pieces inline in the existing
  `aftercareCard` region. Increments (each backend-carrying one is a paired
  web+iOS PR — the `GET .../aftercare` `ClientAftercareDetailDTO` is iOS-only, so
  extending it is low-risk and touches no web render):
  - [x] **before/after compare** — already shipped (§24 AF3b / iOS #32,
    `AftercareBeforeAfterPair`).
  - [x] **aftercare care-notes** — already shipped (§24 AF3b, `careNotesCard`).
  - [x] **A3-cal add-to-calendar** — native `.ics` via `BookingCalendar` (TovisKit)
    + `ShareSheet`; upcoming, non-terminal bookings only. No backend. **iOS PR
    (this session).**
    - [x] **A3-cal-tz timezone-correct `.ics`** — follow-up to web PR #569.
      `BookingCalendar.icsDocument` now takes `timeZone: String?` and, for a valid
      IANA zone, emits a self-contained `VTIMEZONE` (DST-aware `TZOFFSET*` at the
      booked instant) + `DTSTART;TZID=<zone>:<localWallClock>` (no trailing `Z`);
      nil/invalid keeps the bare-UTC `…Z` fallback. Caller passes `booking.timeZone`.
      Mirrors web `lib/calendar/bookingInvite.ts`. No backend. **iOS PR (this session).**
  - [x] **A3-prod product-recommendations checkout** — ✅ shipped (web #567 `703bb6de`
    / iOS #35 `7ebd818`). Aftercare DTO grew `recommendedProducts` + `checkoutProducts`
    + editable gate; native −/+ picker + external-link rows + locked state.
  - [x] **A3-rebook recommended-window rebook CTA** — ✅ shipped (web #568 `90d64c10`
    / iOS #38 `2fcdf1a`). DTO grew `rebook{mode,window*,rebookedFor,declinedAt,nextBooking}`;
    native RECOMMENDED_WINDOW "Time to rebook" CTA + confirmed/pending next-appointment states.
  - [x] **A3-rev review section (leave rating/photos)** — ✅ shipped both parts.
    **4a** (rating + headline/body) — web #570 / iOS #40 `f16b034`: DTO grew
    `existingReview` text-slice + `reviewEligible`; native `ReviewsService`
    (create/edit/delete) + stars/text UI. **4b** (photos) — web #571 `f8f0456e` /
    iOS #41 `f942635`: DTO grew `existingReview.mediaAssets[]` (render URLs via
    `renderMediaUrlsBatch`); `ReviewsService` gained reviewMediaOptions /
    uploadReviewPhoto (reuses `SupabaseSignedUpload.put`) / attach / remove +
    create-time `attachedMediaIds`+`media` on submit; native Photos section =
    session-photo grid (create) + PhotosPicker upload-on-pick + attached grid w/
    remove (edit). Caps = 6 images + 1 video (server-enforced); fresh uploads are
    images-only on native, session videos still attachable by id.
  - ✅ **A3 COMPLETE 2026-07-10** — the whole §5 A3 client-booking-detail / payment-parity
    epic is done. Web #567/#568/#569/#570/#571 all merged, PENDING a prod deploy (held for Tori).
- [ ] **A4 — full pro parity** (build all): Last Minute EDITOR (iOS is read-only —
  create openings + settings/tiers) · Waitlist outreach workspace · pro's private
  client view (✅ DONE — write forms #31, technical-record decryption #48,
  `view=public` toggle #49) · calendar reschedule/
  edit-service-items + "offer a time" modals · booking-detail money-trail
  inspector · manual reminders creator/list (distinct from cadence settings) ·
  referral-REWARD config (iOS has activity-only) · data-migration wizard (5
  screens) · consolidated media manager + fuller owner-menu edit · review
  "feature media in portfolio" toggle.
  - [x] **A4-svc edit-service-items** — ✅ shipped 2026-07-10 (iOS #44 `ff06c47`,
    iOS-only — the web `PATCH /pro/bookings/{id}{serviceItems}` route + recompute +
    calendar `BookingModal` editor already existed). New `ProBookingService.editServiceItems`
    (minimal `serviceId+offeringId+sortOrder`; server re-derives price/dur/itemType; no
    `durationMinutes` → avoids `DURATION_MISMATCH`; idempotent) + `sellableServices(locationType:)`
    (`GET /pro/services`) + `ProSellableService`. `ProEditServiceItemsView` sheet (flat
    base-swappable picker = web's looser calendar editor, **not** the consultation single-BASE
    lock) off a new **Services card** in `ProBookingDetailView` (Edit shown while non-terminal,
    incl. IN_PROGRESS → the mid-session entry point). Since shipped: Last Minute
    editor ✅, pro private client-view (writes + `view=public`) ✅, waitlist-outreach ✅,
    waitlist "offer a time" ✅, money-trail inspector ✅, calendar RESCHEDULE ✅, money-trail
    refund/waive WRITE ✅. Rest of A4 (manual reminders, referral-reward, data-migration
    wizard, media manager, portfolio-feature toggle) still open.
  - [x] **A4-chart-writes pro private-client-view, increment 1 (non-technical write forms)** —
    ✅ shipped 2026-07-10 (iOS #46 `982c028`, iOS-only — the web `/pro/clients/{id}/{alert,
    allergies,do-not-rebook,profile-context}` routes already existed; free text is encrypted
    server-side so the client sends plaintext). `ProClientsService` gained `addAllergy` (POST
    …/allergies), `updateAlertBanner` (PATCH …/alert, blank clears), `setDoNotRebook`/
    `clearDoNotRebook` (PUT/DELETE …/do-not-rebook), `updateProfileContext` (PATCH
    …/profile-context). New `ProClientChartEditSheets.swift` (edit-alert · do-not-rebook w/
    factual-reason copy · edit-context occupation+social pre-filled from the chart header ·
    add-allergy label/description/severity) reached from contextual affordances on
    `ProClientChartView` (header Edit-context, safety-strip Edit-alert, always-present
    do-not-rebook flag/edit, allergies-tab Add-allergy); each write reloads the chart on save
    (`ProAddNoteSheet` got the same `onSaved` reload → fixes stale-after-add-note). +7 tests
    (swift test 198). ✅ **Increment 2 = technical record SHIPPED** (iOS #48 +
    paired web `GET …/technical` · `POST …/formula` · `POST …/consent` ·
    `PATCH …/photo-release`) — `ProClientTechnicalView` + `ProClientTechnicalEditSheets`
    decrypt + write formula/consent entries, founder-gated. ✅ **Increment 3 = `view=public` toggle
    SHIPPED** (iOS #49 + web #574) — a segmented Chart ↔ Public-profile control on
    `ProClientChartView` flips to the new `ProClientPublicProfileView` (avatar · @handle · bio ·
    follower/following/looks counts · 3-col looks grid, tap→fullscreen; read-only, no follow —
    web passes `followMode="hidden"`), loaded lazily from a paired native
    **`GET /pro/clients/{id}/public-profile`** over `loadPublicClientProfileByClientId` (neutral
    viewer, no viewer opts). `profile: null` (200) = "no public profile yet" empty state; a 404
    (route not deployed) falls back to a web pointer. New `ProClientPublicProfile` decode models
    (forward-compat `decodeIfPresent ?? default`). This shared view also seeds **A2's
    `/u/[handle]` public-client viewer** (add a handle-based entry point + guest/client follow
    modes later to finish A2). swift test 206 (+4). **➡️ The pro private-client-view slice is now
    COMPLETE (all 3 increments).**
  - [x] **A4-lastminute-editor, increment 1 (settings / tiers / rules / blocks)** —
    ✅ shipped 2026-07-10 (iOS #50 `f38dd04`, **iOS-only** — the web `/pro/last-minute`
    settings editor routes already exist: `PATCH .../settings`, `PATCH .../rules`,
    `POST`/`DELETE .../blocks`; no backend change, no migration). Turns the read-only
    `ProLastMinuteView` into an editor. `ProScheduleService` gained `updateLastMinuteSettings`
    (PATCH settings — whole "Last-minute defaults" form), `updateLastMinuteServiceRule`
    (PATCH rules), `addLastMinuteBlock` (POST) + `deleteLastMinuteBlock` (DELETE) reusing
    the already-decoded `ProLastMinuteWorkspace`; new `Encodable` request DTOs
    (`ProLastMinuteSettingsPatchRequest` / `…ServiceRulePatchRequest` / `…BlockCreateRequest`)
    that always emit `minCollectedSubtotal` (explicit JSON `null` clears the floor — a
    dropped key wouldn't). New `ProLastMinuteEditSheets.swift`: **settings sheet**
    (master toggle · visibility menu · min-subtotal · tier 2/3 send-time pickers via a
    shared `LastMinuteAnchor` minutes↔wall-clock helper · priority-offer toggle + claim-window
    stepper · 7-day disable grid, one Save), **service-rule sheet** (enabled + optional floor),
    **add-block sheet** (start/end pickers + reason). `ProLastMinuteView` gains the Edit
    affordances (status-card Edit + tappable tiers/service cards) + per-block Remove
    (confirm → DELETE); every write reloads the workspace. swift test 213 (+7 write-path
    tests).
  - [x] **A4-lastminute-editor, increment 2 (openings CREATE / list / cancel)** —
    ✅ shipped 2026-07-10 (**iOS-only** — the `/api/v1/pro/openings` routes already exist:
    `GET` list, `POST` create, `DELETE ?id=` cancel; no backend change, no migration).
    Ports the heavier web `OpeningsClient.tsx` surface. New `ProOpening.swift` in TovisKit:
    `ProOpeningDto` (a display-subset decode of `mapOpeningDto`) + `ProOpeningCreateRequest`
    / `ProOpeningTierPlanRequest` (a discriminated union — only the field for the chosen
    offer type is emitted, nils drop out). `ProScheduleService` gained `listOpenings(hours:take:)`,
    `createOpening(_:)` → the created opening, and `cancelOpening(id:)`. New
    `ProOpeningCreateSheet.swift`: offering multi-select · location segmented · visibility menu ·
    start/end pickers (workspace zone, `ProCalendarGrid.iso`) · note · three tier-plan cards
    (offer-type menu + conditional percent/amount/free-add-on fields, client-validated like
    web `buildTierPlanRequest`). `ProLastMinuteView` grew an **Upcoming openings** section
    (loaded independently of the workspace) — Create button → sheet, per-opening cards
    (service summary · when · location · status pill · recipient count · tier-plan rows via
    shared `describeOpeningTierPlan`), and per-opening **Cancel** (confirm → DELETE). Shared
    `EditField`/`editFieldBox` promoted to module-internal (no copy). swift test 218 (+5
    openings-path tests); `xcodebuild build` clean. **A4 Last Minute EDITOR slice COMPLETE.**
  - [x] **A4-waitlist waitlist-outreach workspace** — ✅ shipped 2026-07-10 (**iOS-only** —
    the web `GET /api/v1/pro/waitlist` route + the `WAITLIST` message-resolve context both
    already exist; no backend change, no migration). Ports the web `/pro/waitlist` outreach
    feed: the clients waiting for this pro's services, grouped by service and FIFO-ranked
    (whoever waited longest is rank #1), with a per-client **Message** action to fill a spot —
    read-only otherwise (the "offer a concrete time" flow is the separate calendar slice). New
    TovisKit `ProWaitlist.swift` (`ProWaitlistOutreach` services+total, `isEmpty` on total==0 /
    `ProWaitlistServiceGroup` / `ProWaitlistEntry` — display decode of the grouped feed);
    `ProScheduleService.waitlistOutreach()` (grouped with last-minute + openings, the other
    fill-a-spot surfaces); `MessagesService.openWaitlistThread(waitlistEntryId:)` (resolves the
    `WAITLIST` thread — backend derives client & pro from the entry, so only the entry id is
    sent — and returns the full thread to push into `ThreadView`). New `ProWaitlistView.swift`
    (grouped service cards · per-client rows: rank badge · `BrandAvatar` · name ·
    `preference · joined Mon D` · Message → `ThreadView`; loading/error/empty states) reached
    from the pro profile's **Business** section ("Waitlist"), mirroring web's account-menu
    entry. New reusable `Wire.monthDay` edge-resolved "joined Mon D" label. +3 tests (read-path
    decode incl. empty feed; `WAITLIST` resolve body). swift test 221; `xcodebuild build` clean.
  - [x] **A4-waitlist-offer "offer a time"** — ✅ shipped 2026-07-10 (iOS #56 `25bca55`,
    **iOS-only** — the web `POST /api/v1/pro/waitlist/{entryId}/offer` route already exists,
    plus the availability + sellable-services routes it leans on; no backend change, no
    migration). Closes the loop on the waitlist-outreach workspace: each waitlist row now
    **offers a waiting client a concrete in-salon slot** (client gets a PENDING offer to
    Confirm/Decline — it does NOT book), alongside Message. Ports the web `WaitlistOfferModal`.
    New TovisKit `ProWaitlistOfferRequest`/`ProWaitlistOfferResponse`/`ProWaitlistOffer` +
    `ProScheduleService.offerWaitlistSlot(waitlistEntryId:scheduledFor:endsAt:locationId:
    durationMinutes:)` — the route derives client + service from the entry, so only the slot
    + in-salon location travel; idempotency **mirrors web exactly** (`scope "pro-waitlist-offer"`,
    entity = entry, action = the ISO start, no nonce → same slot dedupes, different slot mints a
    fresh key). New `ProWaitlistOfferSheet.swift`: resolves the pro's own context itself (unlike
    the web modal the calendar hands it) — `professionalId` (myProfile), bookable **SALON/SUITE**
    location primary-first (mirrors web `offerSalonLocation`), `offeringId`+duration from
    `sellableServices("SALON")` matched on the group's serviceId (absent ⇒ "no in-salon offering"
    blocked state = web's null-offering empty state); reuses `ProOpenSlotPicker` for live
    availability, `endsAt = start + offering duration`. `ProWaitlistView` rows grew an **Offer a
    time** primary action + a brief "Offer sent to …" confirmation banner (the entry stays ACTIVE
    until the client confirms). +1 offer write-path test (path · POST · body · idempotency-key
    reconstruction · decode). swift test 222; `xcodebuild build` clean. **A4 calendar "offer a
    time" slice COMPLETE** (the calendar *reschedule* half shipped after this — iOS #60 — but via
    the pro `PATCH /pro/bookings/{id}` route, **not** `BookingService.reschedule`, which is the
    client-only hold flow; see the A4-reschedule entry below).
  - [x] **A4-money-trail booking money-trail inspector** — ✅ shipped 2026-07-10 (iOS #58
    `d2b5825`, **iOS-only** — the web `GET /api/v1/bookings/{id}/money-trail` route + the
    `BookingMoneyTrail` DTO (`lib/booking/moneyTrail.ts`) already exist; no backend change, no
    migration). Read-only native port of the web `MoneyTrailInspector`
    (`app/_components/booking/MoneyTrailInspector.tsx`), reached from a **View money trail**
    button on the Payment card of `ProBookingDetailView` (→ sheet). One trustworthy view of a
    booking's money: the **Captured / Refunded / Net to pro** summary chips + a flattened
    timeline of the deposit → final-bill charge → platform discovery fee → no-show / late-cancel
    fee → every refund row (renders the server's numbers verbatim — never re-derives money rules).
    New TovisKit `ProBookingMoneyTrail`/`ProBookingMoneyTrailResponse` (1:1 with the web DTO —
    cents as `Int`, instants as ISO `String?`, server enums kept raw `String` + compared
    case-insensitively in the view, the `ProBookingDetail` idiom) + `ProBookingService.moneyTrail(
    bookingId:)` (GETs the shared `/bookings/{id}/money-trail` route like `refund`, not a `/pro`
    route; PRO sees own bookings only, a foreign booking 404s). New `ProMoneyTrailView.swift`
    (`buildEntries` ported 1:1) + reusable `Wire.moneyCents` (integer cents → currency, mirrors
    web `formatCents`, honors the trail's currency code). The **refund / waive WRITE actions** the
    web inspector also offers are a **later increment** — the `capabilities` flags are decoded
    already, so wiring them is additive. +2 write-path/decode tests (full trail + minimal
    all-null); swift test 224; `xcodebuild build` clean.
  - [x] **A4-money-trail refund / waive WRITE increment** — ✅ shipped 2026-07-10 (**iOS-only** —
    the web `POST /api/v1/bookings/{id}/refund` + `POST /api/v1/bookings/{id}/no-show-fee/waive`
    routes already exist; no backend change, no migration). Turns the read-only money-trail
    inspector into the **single native refund + no-show-waive surface**, matching web where
    `MoneyTrailInspector` (not `BookingActions`) is the only place refund lives. TovisKit gained
    `ProBookingService.waiveNoShowFee(bookingId:idempotencyKey:)` → POST the shared
    `/bookings/{id}/no-show-fee/waive` (empty `{}` body; **stable** idempotency key —
    `scope "booking" · action "no-show-waive"`, no body to vary and the fee is a server-side no-op
    on repeat, so a double-tap dedupes); the existing `refund(...)` method is now called from the
    inspector. `ProMoneyTrailView` grew an **actions block** gated on the server's
    `capabilities.canRefund` / `canWaiveNoShowFee` (never a client guess): a **Refund…** form
    (amount — blank = full via `refundableRemainingCents` — + optional reason → confirm dialog
    "…This cannot be undone.") and a **Waive no-show fee** confirm, each POSTing then reloading the
    trail + a `flash`/`error` banner; a refund also `signalRefresh`es so the booking detail behind
    the sheet refreshes. **Consolidation:** removed the detail's old inline `refundForm` + header
    **Refund** button + its state/helpers (`refundForm`/`refundConfirmCopy`/`parseRefundCents`/
    `fullAmountPlaceholder`/`startRefund`/`refund`/`ghostLabel`) — that was an iOS-only divergence
    (web has no detail-level refund) whose `booking.canRefund` (client-side `stripePaymentStatus ==
    SUCCEEDED`) is a weaker gate than the inspector's server `capabilities.canRefund` (it wrongly
    offered refund on an already-fully-refunded / disputed booking). +5 write-path tests (refund:
    full bare-body / partial amount+reason / key-tracks-body; waive: empty-body path / stable-key);
    swift test 232; `xcodebuild build` clean. **A4 money slices COMPLETE** (inspector read + refund
    + waive).
  - [x] **A4-reschedule calendar reschedule** — ✅ shipped 2026-07-10 (iOS #60 `51bb9df`,
    **iOS-only** — the web `PATCH /api/v1/pro/bookings/{id}` route already handles reschedule; no
    backend change, no migration). Native port of the web calendar's **pro reschedule** (the
    `/pro/calendar` BookingModal / drag-to-move), reached from a **Reschedule** action on
    `ProBookingDetailView` while a booking is PENDING/ACCEPTED. **⚠️ Corrected the handoff's premise:**
    the pro reschedule is NOT the client hold-based `POST /bookings/{id}/reschedule`
    (`BookingService.reschedule` — that route is `requireClient` and a pro can't use it on their own
    booking). It's a **direct time move** — `PATCH /pro/bookings/{id}` with a new `scheduledFor` —
    that keeps the existing services + location and creates **no hold** (like `accept`/`editServiceItems`).
    New `ProBookingService.reschedule(bookingId:scheduledFor:notifyClient:allow*:overrideReason:
    idempotencyKey:)` + `ProBookingRescheduleRequest` DTO, mirroring `createBooking`'s override-flag
    shape + body-derived idempotency key (an override retry that adds an `allow*` flag re-mints the key,
    no 409). New `ProRescheduleView.swift`: a trimmed `ProNewBookingView` — no client/service pickers
    (the booking already has those); pick a real open slot via `ProOpenSlotPicker` (sized to
    `totalDurationMinutes` so add-ons fit) or a **custom time seeded to the current start**;
    `notifyClient` toggle (default on) + collapsible scheduling overrides; off-grid times trip the same
    override "save it anyway?" retry as new-booking (intent `.edit`, copy already in
    `BookingOverridePrompt`). On success `signalRefresh` + dismiss (detail auto-reloads). +3 write-path
    tests (headers/body/no-serviceItems-leak · override flags+reason · key-tracks-body); swift test 227;
    `xcodebuild build` clean. The **refund/waive money-trail write increment** remains the last named
    money slice; other A4 slices below still open. **A4 calendar bundle (offer-a-time + reschedule +
    edit-service-items) COMPLETE.**
  - [x] **A4-reminders manual reminders (creator / list / mark-done)** — ✅ shipped 2026-07-10
    (**web + iOS** — the web `/api/v1/pro/reminders` list/create/complete routes already exist; the
    one paired web change is required, see below; no migration). Native port of the web
    `/pro/reminders` page — the pro's own follow-up / rebook / product-check-in **to-dos** ("Check in
    on color fade", "DM bridal party count"), **distinct from the appointment-reminder CADENCE**
    (`ProReminderSettings`, the "Appointment reminders" business link). New TovisKit `ProReminder.swift`
    (display-subset decode: `ProReminder` + nested `ProReminderClient`/`…Booking`/`…BookingService`;
    `ProRemindersResponse`) + `ProRemindersService` (`list()` GET · `create(...)` **form-encoded** POST
    — the route parses `req.formData()`, so it sends `application/x-www-form-urlencoded`, not JSON;
    optional `body`/`clientId` dropped when empty; `type` stays `GENERAL` like the web form · `complete(id:)`
    POST). New `ProRemindersView.swift`: intro + **Add a reminder** button → `ProReminderCreateSheet`
    (title · notes · **DatePicker** → a real ISO instant via `ProCalendarGrid.iso`, unlike web's naive
    `datetime-local` · optional linked-client menu filtered to `canViewClient` from `proClients.directory()`),
    an **Upcoming & open** list (title · due · client · "Booking: <service> on <when>" · notes · type
    pill · **Mark done**), and a **Recently completed** list (newest-first, cap 20). Reached from a new
    **Reminders** entry in the pro profile's Business section. **⚠️ Required paired web change** — the
    complete route (`/pro/reminders/{id}/complete`) *always* did `NextResponse.redirect('/pro/reminders')`,
    which **defaults to 307** → the follow-up re-POSTs to the page route → **405** (broke the native call,
    and the browser "Mark done" too). Fixed by mirroring the sibling **create** route's Accept branch:
    JSON `{ id }` for API callers, explicit **303** (POST→GET) for `text/html` browsers. +5 web vitest
    (`complete/route.test.ts`: auth · 404 not-owned/missing · JSON-200-id · 303-for-html) — web
    typecheck+lint+static-guards green. +4 iOS write/decode tests (`ProRemindersTests`: list decode ·
    form-encoded create body + id · empty-optional omission · complete path); the cross-repo form-encode
    seam verified against the real `req.formData()`. swift test 236; `xcodebuild build` clean. **⚠️ web
    change (`complete` route JSON branch) is no-migration but PENDING a prod deploy — held for Tori.**
    Rest of A4 (referral-reward config, data-migration wizard, media manager, portfolio-feature toggle)
    still open.
  - [x] **A4-referral-reward referral-REWARD config** — ✅ shipped 2026-07-10 (**iOS-only** — the web
    `GET`/`PATCH /api/v1/pro/settings/referral-rewards` routes already exist; no backend change, no
    migration). Ports the web `ReferralRewardsClient` editor onto the existing read-only
    `ProReferralActivityView`, so that screen is now the whole web `/pro/referral-rewards` page (config
    on top of the activity feed). New TovisKit `ProReferralRewardSettings.swift`: `ProReferralRewardSettings`
    (decode `enabled`/`tier`/`discountPercent`/`creditAmount`) + `ProReferralRewardSettingsResponse`
    `{ settings }` wrapper + `ProReferralRewardSettingsPatch` (partial encodable). `ProReferralsService`
    gained `rewardSettings()` (GET) + `updateRewardSettings(_:)` (PATCH → canonical settings). **⚠️
    Cross-repo wire asymmetry** (the notable seam of this slice): the route persists `referralCreditAmount`
    as a Prisma `Decimal`, which serializes to a JSON **string** (`"12.5"`) on the way OUT but the PATCH
    validator requires a JSON **number** on the way IN — so the DTO decodes a string (lenient: also accepts
    a number) and the patch encodes a number. The patch is **partial**: only the master switch + tier +
    the active tier's value are sent (nil optionals dropped), so switching tiers never wipes the other's
    stored value — matching web's per-field save. New `ProReferralRewardSettingsSheet` (Save-applies, the
    native idiom, not web's per-field auto-save): enable toggle · 3 tier radio cards (Recognition only /
    Percentage discount / Dollar credit, web copy verbatim) · conditional discount **Stepper** (1–100) ·
    conditional credit `$` field, clamped/validated like web (discount int 1–100, credit > 0). A **Reward
    settings** summary card + Edit affordance sit above the activity feed; the Growth link renamed
    "Referral activity" → "Referral rewards". +5 iOS tests (`ProReferralRewardSettingsTests`: decode credit
    Decimal-string / RECOGNITION nulls · PATCH sends credit as a NUMBER not string · discount as an integer ·
    nil optionals dropped). swift test 241; `xcodebuild build` clean. **Rest of A4 (data-migration wizard,
    media manager, portfolio-feature toggle) still open.**
  - [x] **A4-portfolio-feature review "feature media in portfolio" toggle** — ✅ shipped 2026-07-10
    (iOS #65 `6b10828`, **iOS-only** — the shared `POST`/`DELETE /api/v1/pro/media/{id}/portfolio`
    route already exists; no backend change, no migration). Ports the web `MediaPortfolioToggle` on
    `/pro/reviews` — the per-tile "feature this review photo in my portfolio" pill — onto the native
    `ProReviewsListView` media grid. The reviews-list DTO already carried `isFeaturedInPortfolio`
    (decoded since PR #438), so this is purely the write path + affordance that was web-only. New
    `ProProfileService.setMediaFeaturedInPortfolio(mediaId:featured:)` → POST (feature) / DELETE
    (un-feature), sending **no body** — matching web exactly, so the route auto-pairs the featured
    "after" with the booking's "before" server-side. Review media is already publish-consented (client
    attached it → `reviewId` set) so the public-share consent gate passes; a boolean set is naturally
    idempotent → no idempotency key. Per-tile pill under each **non-paired** review photo (filled accent
    "In Portfolio" when featured / outline "Add to Portfolio" when not / "Saving…" mid-flight — copy
    verbatim from web); a featured tile that auto-pairs renders as the before/after slider, which — as on
    web — carries no toggle. On success the list reloads (reflects the flag + auto-pairing); a failed
    toggle (e.g. the consent gate 403) surfaces via an alert. +3 write-path tests (`PortfolioFeatureTests`:
    feature POSTs no body · un-feature DELETEs · server error surfaces). swift test 244; `xcodebuild build`
    clean. **Rest of A4 (data-migration wizard, media manager) still open.**
  - [x] **A4-media-manager media manager, increment 1 (list / edit / delete)** — ✅ shipped 2026-07-10
    (iOS #67 `ade610b` + **REQUIRED paired web #576** `8e88ad12` — the web manager is RSC-only, so it
    needed a native read API). Ports the web `/pro/media` grid + `app/_components/media/OwnerMediaMenu.tsx`
    editor onto a native `ProMediaManagerView`, reached from the Profile tab's Business section
    ("My media"). ⚠️ **The scoping seam of this slice:** the web media manager has **no JSON list/detail
    route** — `app/pro/media/page.tsx` + `[id]/page.tsx` are React Server Components querying Prisma
    directly. So this needed a **paired web read API** (like #573/#574): new
    `GET /api/v1/pro/media` (PRO-only, owner-scoped) returning the pro's 60 most-recent media across all
    visibilities **plus** the taggable service options (the active `Service` taxonomy the PATCH validates
    `serviceIds` against) in one envelope; URLs via `renderMediaUrlsBatch`. New `ProManagedMediaItemDTO`/
    `ProManagedMediaListResponseDTO` in `lib/dto/mediaAttach.ts` (reuse `ProMediaServiceTagDTO`) + barrel
    export + `gen:api-schema`. The existing `PATCH`/`DELETE /api/v1/pro/media/{id}` routes are reused
    unchanged. TovisKit: new `ProManagedMedia.swift` (`ProManagedMediaItem` · `ProMediaServiceTag` ·
    list response · `ProMediaUpdateRequest`) + `ProMediaService.listManagedMedia()`/`updateMedia(...)`/
    `deleteMedia(...)`. App: `ProMediaManagerView` grid (plain thumbnails + ★-portfolio/Looks/video
    badges — matches web `MediaTile`; the before/after slider lives only on the public portfolio/reviews
    views) → tap opens `ProMediaEditSheet` (caption ≤300 · derived **Public / Client + you** segmented ·
    Looks + portfolio toggles · searchable service-tag multi-select · Delete w/ confirm). **Wire contract
    (matches OwnerMediaMenu):** visibility is **derived** from the two flags, never sent (server
    recomputes it); the PATCH sends the **full field set**, a nil caption is **omitted → the server clears
    it**; `serviceIds` is the full replacement set (Save gated on ≥1); **no idempotency key** (replacing
    state is naturally idempotent, matching the portfolio toggle); a core edit **omits `beforeAssetId`** so
    it never clobbers server auto-pairing. A 403 consent gate (unpromoted private photo → public) surfaces
    via alert. +4 web route tests + +5 iOS tests (`MediaManagerTests`: list decodes items + options · PATCH
    full body · caption omitted when nil · DELETE · server error surfaces). swift test 249; `xcodebuild
    build` clean; web typecheck+lint+static-guards+vitest green. **⚠️ Increment 2 = before/after PAIRING
    picker** (reuses the existing `GET /api/v1/pro/media/{id}/before-options` route + `BeforeAfterCompareView`;
    the `pairingTouched`/omit-when-untouched semantics make it safely separable). **After that, A4 media
    manager is COMPLETE; only data-migration wizard remains.**
  - [x] **A4-media-manager media manager, increment 2 (before/after PAIRING picker)** — ✅ shipped
    2026-07-10 (iOS #69, **iOS-only** — the `GET /api/v1/pro/media/{id}/before-options` route + the PATCH's
    3-state `beforeAssetId` contract already existed, so no web/DTO/schema change). Adds the before/after
    pairing affordance to `ProMediaEditSheet` (images only; hidden for video), completing the media-manager
    slice. New `ProMediaService.beforeOptions(mediaId:)` (GET → `[ProMediaBeforeOption]` = `{ id, thumbUrl,
    phase }` candidate befores from the after's booking, phase-ranked). New `ProMediaBeforeOption` /
    `ProMediaBeforeOptionsResponse` models + a 3-state `ProMediaPairingEdit` enum (`.untouched` / `.set(id?)`);
    `ProMediaUpdateRequest` grew a custom `encode(to:)` because plain `Encodable` can't express "omit vs
    explicit-null" — `.untouched` **omits** `beforeAssetId` (server leaves auto-pairing alone), `.set(id)`
    encodes the id (pair), `.set(nil)` encodes an **explicit JSON null** (unpair). `updateMedia(...)` gained a
    `pairing:` param defaulting to `.untouched` (source-compatible; the increment-1 call sites + tests are
    unchanged). **Editor UX mirrors web `OwnerMediaMenu`:** lazy-load the options on first appear (`.task`,
    images only), a **None** chip + candidate thumbnails, selection flips `pairingTouched`, and Save sends
    `pairing: pairingTouched ? .set(beforeAssetId) : .untouched` — so a normal save never clobbers server
    auto-pairing. Loading + "No before photos from this booking to pair" empty states match web. **iOS
    enhancement over web** (which shows no live slider in its editor): when a before is chosen and resolvable,
    the section previews the result with the existing `BeforeAfterCompareView` slider — the transformation
    payoff, in-editor. +3 iOS tests (`MediaManagerTests`: before-options GET decodes candidates + phase ·
    PATCH sends `beforeAssetId` when `.set(id)` · PATCH sends **explicit null** when `.set(nil)`); the
    increment-1 "omits beforeAssetId" test still covers the `.untouched` default. swift test 252; `xcodebuild
    build` clean. **NOT simulator-driven** (needs a live authed pro with a booking's before/after photos).
    **✅ A4 media manager COMPLETE; only the data-migration wizard remains in A4.**
  - [x] **A4-migration data-migration wizard, increment 1 (entry + review bookends)** — ✅ shipped
    2026-07-10 (iOS #71 + **paired web #577** `feat(pro-migrate)…summary read API`). Ports the web
    `/pro/migrate` flow's two **RSC-only** "bookend" screens — the entry/landing progress + the
    review/go-live summary. ⚠️ **Scoped web-first** (per the per-slice rule): the web entry + review
    pages query Prisma directly via `loadMigrationReviewSummary` and pass a view-model into a client
    component → **no JSON route**, so this needed a **paired web read API** (like the media manager,
    NOT iOS-only). The three working import steps (services/clients/calendar) ARE JSON-backed but
    **POST-only** (preview/commit) with client-side CSV/ICS parsing — those are later increments.
    **Web #577** (no migration): new `GET /api/v1/pro/migrate/summary` → `{ summary: { offerings,
    clients, importedBookings, importedBlocks, raises[] } }`, guards `requirePro()` then
    `isProMigrationEnabled()` → **404 while flag off**; new `lib/dto/proMigration.ts` + barrel +
    regen'd api-schema; +3 route tests. **Build-dark:** `ENABLE_PRO_MIGRATION` HELD, so the route 404s
    in prod → the entry screen shows a "not available yet" state (same pattern as ProNoShowSettings).
    **TovisKit:** `ProMigrationSummary`/`ProMigrationRaise`/`ProMigrationSummaryResponse` (derive the
    entry progress counts — `calendar = importedBookings + importedBlocks` — + review raise labels
    `fromLabel`/`toLabel`/`cadenceLabel` to match web `buildReviewViewModel`) + `ProMigrationService.summary()`
    (`GET /pro/migrate/summary`), wired on `TovisClient`. **App:** `ProMigrateView` (entry — hero +
    source-app picker → per-source **export guide** = 1:1 port of `_exportInstructions.ts` + "what
    you'll bring over" progress cards; owns the load + 404/error states; navigates to review) +
    `ProMigrateReviewView` (review — three tone-coded summary cards + price-grace raise recap +
    preflight checklist + go-live confirmation; presentational given the loaded summary) + a Business-
    section entry "Import from another app". +3 iOS tests (`ProMigrationTests`: GET route/decode +
    derived progress/labels · flag-off 404 · empty-migration `hasAnyImport`). swift test 255; `xcodebuild
    build` clean. **NOT simulator-driven** (dark; needs a live authed pro + the flag on). **⚠️ Increments
    2–4 REMAIN** = the guided import steps (Clients CSV · Services CSV+fuzzy-match+price-ramps · Calendar
    ICS/feed), each POST-only preview/commit with on-device CSV/ICS parsing (no PapaParse — native CSV
    parser + `.fileImporter`). Scope each web-first (route + client) per the per-slice rule.
  - [x] **A4-migration data-migration wizard, increment 2 (clients import)** — ✅ shipped
    2026-07-10 (iOS #73, **iOS-only** — the web `POST /api/v1/pro/migrate/clients/preview` + `/commit`
    routes already exist as JSON endpoints with **no DTO/zod** (contract in
    `tovis-app/lib/migration/clientImportServer.ts`), behind the same `ENABLE_PRO_MIGRATION`
    404-when-off gate the entry screen handles → **no web change**, unlike increment 1's RSC-only
    bookends). Native port of the web `/pro/migrate/clients` flow (`MigrateClientsClient.tsx`): the
    four phases **upload → map columns → preview dedupe → commit**, reached from `ProMigrateView`'s
    footer. **TovisKit:** `CsvParser` — on-device CSV parser matching the web PapaParse config
    (`header:true`, `skipEmptyLines`): quoted fields, embedded commas/newlines, escaped `""`, CRLF, BOM
    (scans Unicode **scalars**, not `Character`s, so a CRLF isn't swallowed as one grapheme). +
    `ProMigrationClientImport` (Encodable request — `rows`/`mapping`/`excludeIndices` via
    `encodeIfPresent`; Decodable preview/commit shapes hand-mirroring the server types; `ClientImportField`
    enum; `guessClientImportMapping` = 1:1 port of the web `guessMapping`). + `ProMigrationService`
    `previewClientImport`/`commitClientImport` POSTs (via `JSONEncoder.canonical`). **App:**
    `ProMigrateClientsView` (upload → `.fileImporter` CSV pick + parse → column-map menus seeded by the
    guess → preview list with per-row include toggles, non-importable rows auto-excluded (web parity) →
    commit → done tally). Import is **silent** — `upsertProClient` never messages a client. `ProMigrateView`
    footer now offers "Import your clients" (primary) alongside the review CTA (secondary). +11 iOS
    `CsvParserTests` + +6 `ProMigrationClientImportTests` (preview POST route/verb/headers/body + decode ·
    excludeIndices omitted for preview · commit POST + discriminated `ok` rows · flag-off 404 · guess +
    required-field gate). swift test **272**; `xcodebuild build` clean. **NOT simulator-driven** (dark; needs
    a live authed pro + the flag on). **⚠️ Increments 3–4 REMAIN** = Services (CSV + fuzzy-match + price-ramp
    editor — most complex) · Calendar (ICS file / feed URL → `/calendar/fetch` → `/calendar/preview`+`/commit`;
    the feed-URL path avoids on-device ICS parsing). Scope each web-first per the per-slice rule.
  - [x] **A4-migration data-migration wizard, increment 4 (calendar import)** — ✅ shipped
    2026-07-10 (iOS #75, **iOS-only** — the web `POST /api/v1/pro/migrate/calendar/fetch` +
    `/preview` + `/commit` + `/subscription` routes already exist as JSON endpoints with **no DTO/zod**
    (contract in `tovis-app/lib/migration/calendarImportServer.ts` + `calendarFeed.ts` +
    `calendarFeedSubscription.ts`), behind the same `ENABLE_PRO_MIGRATION` 404-when-off gate → **no web
    change**, like increment 2). Native port of the web `/pro/migrate/calendar` flow
    (`MigrateCalendarClient.tsx`): the three phases **upload (.ics file OR read-only feed URL) → review →
    done**, reached from `ProMigrateView`'s footer. ⚠️ **Key realization:** the web client **never parses
    the .ics** — for *both* the file-upload and feed-URL paths it just shuttles the raw text to the
    server's `/preview` (which parses it), so **no on-device ICS parser was needed** and **both** input
    paths ship together (fuller web parity than the handoff's feed-URL-only floor). File path = read the
    picked file's text; URL path = `POST /calendar/fetch` (server pulls the .ics, SSRF-guarded) → then
    `/calendar/preview` classifies each event (booking / blocked time / client history / skipped) → the
    pro toggles off any row → `/calendar/commit`. A feed-URL source can be **kept in sync** (`POST
    /calendar/subscription`) after commit. Import is **silent** — the import-mode booking/client/block
    writes never message a client. **TovisKit:** `ProMigrationCalendarImport` (Decodable
    fetch/preview/commit/subscription shapes hand-mirroring the server types — `CalendarImportPreviewRow`
    with derived `kind`/`title`, `CalendarImportCommitCreated`, `CalendarFeedSubscription`; Encodable
    request bodies — `{ url }` and `{ ics, excludeUids? }` via `encodeIfPresent`). +
    `ProMigrationService` `fetchCalendarFeed`/`previewCalendarImport`/`commitCalendarImport`/
    `connectCalendarSubscription` POSTs (via `JSONEncoder.canonical`). **App:** `ProMigrateCalendarView`
    (upload — `.fileImporter` .ics pick + read text, OR feed-URL field + "keep synced" toggle + fetch →
    review list with per-row include toggles + live booking/blocked/history stats → commit → done tally,
    with a "kept in sync" confirmation). `ProMigrateView` footer now offers "Import your calendar"
    (secondary) alongside clients + review; the "coming soon" note narrows to just the service menu.
    +5 `ProMigrationCalendarImportTests` (fetch POST route/body/decode · preview POST + `excludeUids`
    omitted + decode/derived helpers · commit POST + `excludeUids` + decode · subscription POST + decode ·
    flag-off 404). swift test **277**; `xcodebuild build` clean. **NOT simulator-driven** (dark; needs a
    live authed pro + the flag on). **Only increment 3 (Services) remained after this — now ✅ shipped
    below; the wizard + all of A4 is COMPLETE.**
  - [x] **A4-migration data-migration wizard, increment 3 (services import)** — ✅ shipped
    2026-07-10 (iOS #76, **iOS-only** — the web `POST /api/v1/pro/migrate/services/preview` + `/commit`
    routes already exist as JSON with **no DTO/zod** (contract in
    `tovis-app/lib/migration/serviceImportServer.ts`), behind the same `ENABLE_PRO_MIGRATION`
    404-when-off gate → **no web change**; `services/page.tsx` does no server data fetch, so nothing is
    RSC-only, unlike increment 1's summary bookends). Native port of the web `/pro/migrate/services` flow
    (`MigrateServicesClient.tsx`): **upload .csv → map (match + tune raises) → done**, reached from
    `ProMigrateView`'s footer. **The last and most complex wizard step — closes the wizard + §5 A4.**
    The **server runs the fuzzy match**, so iOS consumes `suggestions` + `bestServiceId` rather than
    porting `serviceMatch`. Ported client-side (all pure, from the web client): the **CSV column
    heuristic + number parsing** (`parseServiceMenuRows`/`parseMenuNumber`, reusing `CsvParser`), the
    **row-status derivation** (OK / PRICE_GRACE / NEEDS_ATTENTION + the commit-eligibility rule — any
    unmatched row blocks commit, web parity), and the **price-grace ramp math** (`ServicePriceRamp` — a
    port of `lib/migration/priceRamp` + the web `buildRampSchedule`, so the on-device raise editor previews
    exactly what the server persists: 10%/10-week policy floor, whole-dollar, clamps never gentler). Commit
    is **silent** (import-mode offering write never messages a client), idempotent on
    [professionalId, serviceId]. **TovisKit:** `ProMigrationServiceImport` (Encodable `ServiceMenuInputRow`
    / `ServiceImportDecision` incl. nested `ramp`; Decodable catalog/preview/commit shapes — commit row is
    a flattened `ok`-discriminated union) + the CSV helpers; `ServicePriceRamp`; `ProMigrationService`
    `previewServiceImport`/`commitServiceImport` (POST via `JSONEncoder.canonical`). **App:**
    `ProMigrateServicesView` (upload → **map**: per-row catalog-picker Menu grouped by category + live
    to-add / raises-unlocked / need-a-match stat pills + a **raise configurator** per below-minimum service
    — percent/dollars toggle, step & cadence sliders, live metrics + step-by-step schedule → commit → done
    tally). `ProMigrateView` footer now **leads with "Import your services"** (primary) then clients /
    calendar / review, and drops the obsolete "service menu coming soon" note. +13 tests (6
    `ProMigrationServiceImportTests`: preview/commit route+body+decode, flag-off 404, CSV helpers; 7
    `ServicePriceRampTests`: floor/clamp/step/`nextStepPrice`/`needsRamp`/schedule parity). swift test
    **290**; `xcodebuild build` clean. **NOT simulator-driven** (dark; needs a live authed pro + the flag
    on). **✅ §5 A4 pro-parity umbrella COMPLETE.**
  - [x] **A4 wizard robustness parity** (2026-07-16, `feat/migrate-import-robustness` — counterpart of
    web #639 + #641): export guides re-ported 1:1 after the web fact-check audit (per-app strings +
    `calendarFeed` flags: Vagaro/Square → false, GlossGenius/Fresha → true); clients+services pickers
    accept Excel (`.xlsx/.xlsm/.xls`) + multi-file (`migrationSpreadsheetContentTypes`); binary files
    route to the shared `POST /pro/migrate/parse` via `SpreadsheetFileLoader` (TovisKit — magic-byte
    sniff, security-scoped reads, web `tablesShareHeaders` parity; pick/parse logic de-duplicated out
    of both views); clients mapping gains `fullName` ("Full name (one column)", auto-guessed for bare
    Name/Client/Customer headers, server splits; gate = first+last OR fullName). Still dark behind the
    server flag; NOT simulator-driven.
  - ↪ **Predecessor for mid-session service change** (`tovis-app §22`, MS-iOS): A4's
    **edit-service-items** modal is the first place iOS gains a TovisKit method to change
    services on an existing booking (today only `sendConsultationProposal` exists — no
    PATCH-with-serviceItems). Build A4 before/with §22-iOS so the client method isn't
    written twice. `ProConsultationFormView`'s single-BASE constraint (can't swap the base
    service) also needs a decision there — web is looser; keep both consistent.
- [x] **A5 — pro home → Calendar** — ✅ shipped 2026-07-10 (iOS #80, **iOS-only**, no
  web change / migration / DTO — web `/pro` already redirects to `/pro/calendar`).
  `ProMainTabView` default tab `.overview` → `.calendar`; the Overview home (host for
  the web top-header tab strip) stays reachable via the Calendar bar's Home control (it
  was never a footer slot). Deleted the never-instantiated `Tovis/ProOverviewView.swift`
  (only caller of `proOverview.overview()`; the Overview-home's Overview tab already
  renders `ProFinanceView`) and retired the orphaned `ProOverviewService` +
  `TovisClient.proOverview` (zero callers/tests). Kept `ProOverviewResponse` model +
  `proOverview.json` fixture + decode test (Finance reuses the nested types). swift test
  294; `xcodebuild build` clean. NOT simulator-driven (needs a live authed pro).
- [ ] **A6 — minor drift**: ✅ **Inbox role-awareness FIX shipped** (PR #11, see §7) — rows
  + thread title now show the correct counterparty via the new `isViewerPro`. Still open:
  web's inbox filter tabs (All/Bookings/Waitlists/Pros) + context eyebrows (→ §7 increment 4) ·
  Home `InviteFriendCard` + two-column · Notifications day-grouping + filter chips
  (All/Unread/Bookings/Payments/Social).
- Stale-code cleanup surfaced: `ProNewBookingView` header says "SALON only" but
  handles mobile; `AppFiles/{LoginView,SessionModel}.swift` are stubs (live auth
  is in `ContentView.swift`).

## 6. Post-appointment payment confirmation + aftercare rebooking (audit 2026-07-08)
Backend + web build tracked in `tovis-app/docs/BACKLOG.md §10` (locked decisions there).
For off-platform / unverifiable payment methods (Venmo / Zelle / Cash / Apple Cash /
PayPal) the current appointment's checkout enters a new `AWAITING_CONFIRMATION` state
(client attests, pro confirms receipt to close it out); the client can still book the next
appointment immediately, and for **aftercare-sourced** next appointments approval is
**coupled to payment confirmation** (stays `PENDING` until the pro approves the payment,
which auto-`ACCEPTED`s it). Backend is additive — iOS keeps working until this ships.
- [x] **PF4 — iOS parity** — SHIPPED (PR #10, merged 2026-07-08). Client checkout shows the
  "Payment sent — waiting on your pro" banner (AWAITING_CONFIRMATION); pro session wrap-up
  gains "Confirm payment received" → `POST /pro/bookings/{id}/checkout/confirm-payment`
  (auto-approves the coupled next booking); PAYMENT_CONFIRMATION_REQUIRED notif labelled.
  Followed the repo's stringly-typed checkout-status/event-key convention (no new enum).
- [x] **PF5 — booking-detail surfaces (read-endpoint follow-up)** — SHIPPED (PR #24, pairs web
  #550). The web PR exposed `checkoutStatus` + `rebookOfBookingId` on `GET /pro/bookings/[id]` +
  the client bookings read; iOS now consumes them: the pro booking-DETAIL Payment card shows
  "Confirm payment received" when AWAITING_CONFIRMATION (same confirm-payment route as the wrap-up,
  auto-approves the coupled next booking), and a coupled aftercare PENDING next appointment shows a
  "Pending — your pro will confirm" notice on `BookingDetailView`. Both fields decode optionally
  (dark until the web prod deploy of #550 lands — held for Tori). Clears all §6 deferred niceties.
- [x] **PF6 — rebook affordance + truthful copy at AWAITING_CONFIRMATION (iOS)** — SHIPPED
  (audit 2026-07-10; pairs web §10 PF6). On `BookingDetailView` the "waiting on your pro" banner
  and the rebook-window card already share one scroll, but the card was suppressed: `hasContent`
  (`ClientAftercareDetail`) counted only notes/photos/products, so a rebook-only summary
  (recommended window, no other content) hid the whole aftercare card + its "Rebook now" CTA.
  Fix: (1) new `ClientAftercareRebook.hasRenderableRebook` (recommended window OR active coupled
  next booking) folded into `hasContent`, and reused as the rebook-card render gate; (2) the
  `AWAITING_CONFIRMATION` banner copy is now conditional (`hasRebookOption`) so it points at
  rebooking instead of claiming "nothing else to do". Decode-only model change; DecodingTests
  cover the rebook-only `hasContent`.

## 7. Messaging refinement epic (2026-07-08)
Refine the Inbox/messaging surface for BOTH roles, web + iOS in parity. Root cause of the
"feels off" was a real bug: iOS showed the wrong counterparty (a pro saw their own name)
because the thread list DTO omitted participant user ids. Web + backend counterpart:
`tovis-app/docs/BACKLOG.md` messaging epic. 5 planned increments, one PR-pair each:
- [x] **M1 — role-aware counterparty + thread polish** — SHIPPED (web `tovis-app #531` +
  iOS PR #11). Backend added `isViewerPro` (thread list) + `counterpartyLastReadAt`
  (thread detail); iOS decodes `isViewerPro` → `MessageThread.counterpartyName/AvatarUrl`
  (rows + thread title + neutral empty-state); read receipts ("Read"), Today/Yesterday/date
  separators, optimistic send + "Failed · Retry". Web extracted a shared counterparty helper.
- [x] **M2 — realtime on the messages screens** — ALREADY DONE on iOS (no PR needed). The
  app-global `user:{id}` Realtime subscriber (commit `5033dc0`, `ContentView.startRealtime`)
  bumps `refreshTick` on any `changed` broadcast, and both `InboxView` and `ThreadView` observe
  it — so realtime already reaches the messages screens. The 30s inbox / 15s thread polls remain
  as a fail-open safety net. The real M2 gap was on web (shipped `tovis-app #533`).
- [x] **M3 — inbox filters + context eyebrows** — SHIPPED (PR #14). The 4 filter tabs
  (All/Bookings/Waitlists/Pros, server `?filter=`) + per-row context eyebrow (server-computed
  `eyebrow`/`isAccentContext`). Cleared the A6 inbox-filter item.
- [x] **M4a — "load earlier" history paging** — SHIPPED (PR #15). `ThreadView` pages backward
  via the server cursor (`nextCursor`/`hasMore`), preserving scroll position.
- [x] **M4b — image attachment composer** — SHIPPED (PR #16). `PhotosPicker` stage → upload →
  send; optimistic row + retry.
- [x] **M4c/M4d — thread deep-link + pro→client entry points** — SHIPPED (PR #17). A tapped
  new-message push opens the specific thread (`/messages/thread/{id}` → sheet in both shells);
  "Message" action wired via `resolveThread(clientId:)` from `ProBookingDetailView` /
  `ProClientChartView`. (Together #14–#17 cover the originally-scoped M3/M4/M5 items; the §7
  epic is complete on iOS.)

---

### Note on superseded docs
This backlog replaced `HANDOFF.md`, `HANDOFF-PRO-CAMERA.md`, and `docs/PRO-WEB-PARITY.md`
(their open items are captured above; the evergreen setup/gotchas moved into `README.md`;
history is in git).
