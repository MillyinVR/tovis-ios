# PRO web-parity audit — gap lists + plan (resume here)

> Goal the user set: each native pro page should **look and work exactly like the web page**.
> This session built functional, brand-consistent native ports (Phases 3–5, all committed +
> green) but they are *renditions*, not verified 1:1 copies. Below is the per-page gap list
> from reading the actual web components, plus what needs backend work. **Exact copy/labels
> live in the web source files cited per section — quote them verbatim when implementing.**
> Backend contract map = `docs/PRO-BACKEND-CONTRACTS.md`. Web repo = `~/Dev/tovis-app`.

Status (2026-06-29): specs captured for all 5 pages. **DONE: working hours ✅ + notifications feed ✅**
(commit `b6ea3c3`). **REMAINING: booking detail, profile, clients** (booking-detail + clients chart need
backend route expansions first; profile needs a tabbed shell + edit/payment forms + services CRUD).
Pro notification-PREFERENCES screen still not built (service methods exist).

---

## 1. Booking detail — `Tovis/ProBookingDetailView.swift`  ⚠️ needs backend expansion

Web source: `app/pro/bookings/[id]/page.tsx` (+ `BookingActions`, `RefundButton`).

**Web layout (top→bottom):** back "‹ BOOKINGS" + status pill · header card (`Booking · #{last6}` eyebrow,
service name + **TOTAL** right, client avatar+name+contact, timing line w/ tz badge, location
"tap for directions" tile, **Open session** + **Refund** buttons, then `BookingActions` row) ·
2-col grid: **Timing** card (Scheduled/Started/Finished timeline w/ check dots, sub "State
timestamps for this booking.") + **Payment** card (status box Paid/Awaiting + money rows
Services/Discount/Tax/Tip/**Total**) · **Aftercare** snapshot card (SENT/DRAFT badge, notes or
"No aftercare notes yet.", "View full aftercare" → `/pro/bookings/{id}/aftercare`).

**Web actions** (`buildLifecycleActionViewModel`, role PRO): PENDING→**Accept**+**Cancel**(confirm
"Cancel this booking? This will notify the client.") · ACCEPTED→**Start booking**(POST
`/session/start`)+Cancel · IN_PROGRESS→**Continue session**(→`/session`) · terminal→status text only.
Refund shown iff stripe payment SUCCEEDED → `POST /api/v1/bookings/{id}/refund` (amount optional=full,
reason optional, window.confirm).

**Gaps in my native screen:**
- ❌ Built an **invented "propose next appointment" rebook card** — NOT on the web booking detail
  (rebook lives on the aftercare page). **Remove it.**
- ❌ Missing Timing timeline, Payment breakdown (only shows Subtotal), Aftercare snapshot card.
- ❌ Header: no `Booking · #id` eyebrow, no TOTAL, no location "tap for directions" tile.
- ❌ Actions: I have "Accept request"/"Open·Resume session"/Cancel. Web wants Accept+Cancel,
  **Start booking** (POST session/start — I don't call it), Continue session, + **Refund**.
- 🔶 **BACKEND**: `GET /pro/bookings/[id]` returns a slim shape. Must expand to add `totalAmount`,
  `serviceSubtotalSnapshot`, `taxAmount`, `tipAmount`, `discountAmount`, `paymentCollectedAt`,
  `stripePaymentStatus`/`stripeAmountTotal`/`stripeCurrency`, `selectedPaymentMethod`,
  `startedAt`, `finishedAt`, `aftercareSummary{notes,sentToClientAt,draftSavedAt,version}`.
  (Refund endpoint `POST /api/v1/bookings/{id}/refund` already exists.) → one tovis-app PR; then
  expand `ProBookingDetail` model + fixture + the view.

## 2. Profile — `Tovis/ProProfileTabView.swift` + `ProProfileManageViews.swift`

Web source: `app/pro/profile/public-profile/page.tsx` + `_components/*` (ProProfileCard, ProProfileTabs,
ProReviewsSection, EditProfileButton, EditPaymentSettingsButton) + `_sections/ServicesManagerSection*`.

**Web layout:** header (‹ Back · "Public Profile" · notif bell) · approval notice (if !approved,
"Your profile is under review") · profile card (avatar, name, subtitle·location, bio or "Add a short
bio…", **Edit** + **Payment settings** + "View as client ›") · **Your link** card (locked/reserve/
live vanity .tovis.me states) · stats grid (rating/reviews/favorites/looks/followers) · quick actions
(+ Add services / Messages / + Upload) · **Tabs: portfolio · services · reviews** (lowercase) · tab content.

**Gaps:**
- ❌ No **tabbed shell** (portfolio/services/reviews) — mine is one scroll. Add the 3-tab switch.
- ❌ Edit form: web has **handle w/ live availability check** (`GET /pro/profile/handle-available`,
  suggestions), **nameDisplay as 3 cards w/ hints**, profession type, avatar upload, bio. Mine has
  businessName/handle/bio/location/nameDisplay(segmented) — missing live handle check + avatar upload
  + profession type field + the descriptive nameDisplay cards.
- ❌ **Payment settings** modal not built at all (collection timing, deposits, accepted methods w/
  handles, tips + suggestions, client note). Backend `GET/PATCH /pro/payment-settings` exists (see
  contracts doc) — pure iOS build + a `ProPaymentSettingsService`.
- ❌ **Your link / vanity** card not built (locked/reserve/live + copy/QR/share).
- ❌ Services manager: web supports **add service** (library picker → POST /pro/offerings), **remove**,
  **add-ons manager** (GET/PUT `/pro/offerings/{id}/add-ons`), **custom image upload**, description +
  salon/mobile editor. Mine only **toggles active + edits price/duration**. Add create/delete/add-ons/image.
- ✅ Approval-notice, "View as client", stats labels are close; align copy verbatim.

## 3. Clients — `Tovis/ProClientsView.swift`  ⚠️ chart needs backend aggregate GET

Web source: `app/pro/clients/page.tsx` (list) + `app/pro/clients/[id]/page.tsx` (chart).

**Web list:** header title+subtitle · **"Add a client"** card form (firstName/lastName/email/phone +
validation) · client list w/ Message + View chart quick actions · empty state. **My native** has
search + recent/other + contact + addresses + add-note. Gaps: ❌ no "Add a client" form; ❌ no
Message/View-chart quick actions on rows; align list copy.

**Web chart (`/pro/clients/[id]`):** header w/ access-countdown badge · **Chart / Public profile** view
toggle · client header card w/ stats (total/last/next bookings) · **safety strip** (alert banner +
allergies, color-coded severity) · **do-not-rebook** banner (author-scoped) · smart-flags + relationship-
intelligence card · context controls (occupation, social handle, do-not-rebook) · **8 TABS: Notes ·
Allergies · History · Products · Reviews · Pro feedback · Photos · Technical record** (flag-gated). Each
tab has its own add/edit forms + copy.
- 🔶 **BACKEND**: there is **no chart read API** — the page server-renders a big Prisma query. To port
  the chart, add an aggregate **`GET /pro/clients/[id]/chart`** DTO (notes/allergies/history/products/
  reviews/feedback/photos + header stats + alert + do-not-rebook), respecting `assertProCanViewClient`
  + the technical-record founder flag. Big PR. Then build the 8-tab chart natively.
- My native client detail is a **subset** (contact + addresses + add-note). Keep, then expand to the
  full chart once the aggregate GET exists.

## 4. Working hours — `Tovis/ProWorkingHoursView.swift`  ✅ PARITY DONE (b6ea3c3)

Web source: `app/pro/calendar/_components/WorkingHoursForm.tsx`.

**Web:** header eyebrow "◆ Salon hours" + title **"Base schedule"** + description ("Fixed location
availability…") + **"{n} Days on"** badge · table header Day/On/Start/End · per-day row: full name +
**summary "9:00 AM → 5:00 PM" or "Off"** + toggle (role=switch) + Start/End as **Hour(1–12)/Minute
(00/15/30/45)/AM-PM** selects · save **"Save schedule"**/"Saving…"/**"Saved"** · validation **"{Day}:
End time must be after start time."** Days Mon→Sun. Defaults Mon–Fri 09:00–17:00 on, Sat/Sun off.

**Gaps:** ❌ no header eyebrow/title/description/days-on badge; ❌ no per-day summary line; ❌ time
editing uses a DatePicker (web uses 3 dropdowns w/ 15-min minutes — acceptable as native idiom OR
build hour/min/period menus for literal parity); ❌ button copy ("Save hours"→"Save schedule"); ❌
add per-day end>start validation w/ exact message. Title nav can stay "Working hours".

## 5. Notifications — `Tovis/ProNotificationsView.swift`  ✅ FEED PARITY DONE (b6ea3c3); prefs screen still TODO

Web source: `app/pro/notifications/page.tsx`, `NotificationCard.tsx`, `MarkAllReadButton.tsx`,
`settings/page.tsx` → `app/_components/NotificationPreferencesForm.tsx`.

**Web feed:** sticky header (eyebrow "{Brand} Pro", title "Notifications", status "Showing N of M …") ·
**filter chips: All · Unread(n) · Requests · Updates · Cancelled · Reviews · Social** (category query) ·
**date-grouped sections** (Today/Yesterday/"Thu, Jun 28" + per-day count) · **NotificationCard**: event
**badge text** ("Booking request"/"Booking cancelled"/"Review"/"Booking update" via eventKey map) +
"Unread" badge + title + 2-line body + time "2:45 PM" + "Open details →" hover · **Mark all read** ·
**Show more** (take +60, max 200) · empty "You're caught up."

**Gaps:** ❌ no filter chips/category filter; ❌ no date grouping; ❌ uses icon/tint instead of the
event **badge label**; ❌ "Unread" text badge; ❌ empty copy. (My feed has icon+dot+mark-all+paging+tap→
detail — keep, restyle to match.) ❌ **Pro notification-preferences screen not built** — web settings has
SMS-consent note, quiet hours (toggle + From/To, "Start and end times can't be the same."), per-category
per-event channel toggles (IN-APP/SMS/EMAIL, email-locked "(always on)"), "Save preferences". The iOS
`ProNotificationsService` already has `preferences()/updatePreferences()` — just build the view (mirror
the client `NotificationPreferencesView`, point at the pro service).

---

## Suggested order for the REMAINING parity pass
(working hours ✅ + notifications feed ✅ already done)
1. **Profile** — tabbed shell (portfolio/services/reviews) + edit-form completeness (live handle check,
   profession type, avatar upload, nameDisplay cards) + **payment-settings** screen (`ProPaymentSettingsService`)
   + services create/delete/add-ons/image. Mostly iOS; endpoints exist. Also: notification-PREFS screen.
2. **Booking detail** — tovis-app PR to expand `GET /pro/bookings/[id]` (totals/payment/timestamps/aftercare),
   then rebuild the screen (timeline/payment/aftercare/actions/refund, **remove invented rebook card**).
3. **Clients chart** — tovis-app PR for aggregate `GET /pro/clients/[id]/chart`, then build the 8-tab chart;
   also add the "Add a client" form + Message/View-chart row actions to the list.
Commit per page; `swift test` + `xcodebuild` Debug+Release each; **visually verify on the sim** side-by-side
with the web app (the user specifically wants visual parity, which a compile can't confirm).

⚠️ Build gotcha seen all session: the Write tool sometimes appends a literal `</content>` line to new
files — strip with `perl -ni -e 'print unless m{^</content>}' <file>` before building.
