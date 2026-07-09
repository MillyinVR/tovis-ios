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
- **Tier 3:** §7 messaging **M3–M5** · §6 post-payment read-endpoint follow-up.
- **Tier 4:** §5 **A1** residual (pro onboarding checklist + license/doc verification —
  the rest of A1 is SHIPPED, see the ⚠️ note on A1 below) · **A8** Google Sign-In
  (`tovis-app §15`) · §5 **A2** client screens · **A3** booking detail · **A4/A5** pro parity.
- **Tier 7/8:** §1 live-verification · §2 launch train (**App Store upload**) · §3–§4
  deferred pro polish · camera polish (`tovis-app §17`) · **A9** TikTok (parked, `tovis-app §15`).

### ✅ Recently shipped (iOS, through 2026-07-09)
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
- [ ] Pro aftercare-detail screen.
- [ ] In-app Message deep-link from the clients list.
- [ ] Per-tab chart write forms + technical-record decryption.
- [ ] Looks/followers profile stat tiles.
- [ ] Orphaned `ProClientDetailView` — re-link or delete.
- [ ] Pro sub-screens: locations editor (create/edit/set-primary/publish), payment-settings/membership, offering CREATE/DELETE (only toggle/edit shipped).
- [ ] Calendar parity: working-hours shading, drag/resize + tap-to-create, `ManagementModal` (full pending/waitlist list), booking-override retry dialog, side-by-side overlap columns.
- [ ] Client card-on-file (needs the Stripe iOS SDK).

## 5. Web↔iOS parity epic (audit 2026-07-08)
Comprehensive screen-by-screen audit of both apps (findings + Tori's layout
decisions in tovis-app memory `HANDOFF-web-ios-parity`; master roadmap +
web-side workstreams in `tovis-app/docs/BACKLOG.md §9`). Goal: every page matches
across web + iOS (camera / IAP / NFC / SEO excepted); parity = level **up**.
§4 above (the old PRO-WEB-PARITY tail) folds into A4/A5 below — this §5 is the
superset (adds auth + the full client surface). One screen/PR per session.

**Accepted divergences (leave as-is):** camera / best-shots / frame-scrubber +
wrap-up AI photographer-review (iOS-only, correct); membership purchase stays
web-only (Apple IAP — iOS display-only is right); NFC card/short-code + claim
ACCEPTANCE stay web (iOS generates claim links, web accepts); public SEO
`/p` pro-vanity mirror stays web (iOS renders the native pro profile instead).
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
- [ ] **A2 — first-class client screens** (today folded into Me/Home/Notifications
  or absent): **Settings hub** (biggest — profile edit, public handle, discovery
  location, saved addresses, payment methods, notif prefs) · Activity feed ·
  Aftercare inbox · Priority Offers (claim) · standalone Openings feed · Referrals
  activity list · Boards detail + create + share/event-countdown (iOS shows
  read-only preview tiles today) · **public client profile `/u/[handle]` viewer**
  (looks / stats / follow; guest + client viewer modes — no native equivalent
  exists today) · Share-your-look publish flow.
- [ ] **A3 — client booking detail** rebuild `BookingDetailView` to web's tabbed IA
  (Overview / Consultation / Aftercare) + add the missing pieces: before/after
  compare, aftercare care-notes, product-recommendations checkout, review section
  (leave rating/photos), recommended-window rebook CTA, add-to-calendar.
- [ ] **A4 — full pro parity** (build all): Last Minute EDITOR (iOS is read-only —
  create openings + settings/tiers) · Waitlist outreach workspace · pro's private
  client view — `ProClientChartView` per-tab write forms + technical-record
  decryption + a **`view=public` toggle** (chart ↔ that client's public profile;
  web has it, iOS doesn't) · calendar reschedule/
  edit-service-items + "offer a time" modals · booking-detail money-trail
  inspector · manual reminders creator/list (distinct from cadence settings) ·
  referral-REWARD config (iOS has activity-only) · data-migration wizard (5
  screens) · consolidated media manager + fuller owner-menu edit · review
  "feature media in portfolio" toggle.
- [ ] **A5 — pro home → Calendar**: land on Calendar like web (iOS lands on the
  Overview home today); delete the never-instantiated `Tovis/ProOverviewView.swift`.
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
  **Deferred (needs a backend follow-up — read endpoints don't expose the fields):** the
  confirm button in the pro booking-DETAIL Payment section, the coupled card on the next
  booking's detail page, and the client coupled "Pending confirmation" label — all need
  `checkoutStatus` + `rebookOfBookingId` on `GET /pro/bookings/[id]` + the client booking read.

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
- [ ] **M3 — inbox filters + context eyebrows**: mirror web's 4 filter tabs
  (All/Bookings/Waitlists/Pros) + per-row context eyebrow (booking time / waitlist status /
  service name). (Folds in the A6 inbox-filter item.)
- [ ] **M4 — pro→client entry points**: iOS has NO way to start a conversation with a
  client from a booking / `ProClientChartView` / `ProBookingDetailView` (web does, via
  `/messages/start`). Add a "Message" action + wire `resolveThread(clientId:)`.
- [ ] **M5 — attachment composer + history paging**: send media (both platforms only
  RENDER attachments today — no compose UI) + "load older" using the server cursor
  (`nextCursor`/`hasMore`) that both UIs currently ignore. Also a message deep-link target
  so a notification can open the thread.

---

### Note on superseded docs
This backlog replaced `HANDOFF.md`, `HANDOFF-PRO-CAMERA.md`, and `docs/PRO-WEB-PARITY.md`
(their open items are captured above; the evergreen setup/gotchas moved into `README.md`;
history is in git).
