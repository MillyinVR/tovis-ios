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

---

### Note on superseded docs
This backlog replaced `HANDOFF.md`, `HANDOFF-PRO-CAMERA.md`, and `docs/PRO-WEB-PARITY.md`
(their open items are captured above; the evergreen setup/gotchas moved into `README.md`;
history is in git).
