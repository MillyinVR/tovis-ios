# PRO backend API contract map (for the iOS port)

> Consolidated from a backend sweep of `tovis-app` on 2026-06-28. Source of truth
> is always the route handlers under `tovis-app/app/api/v1/pro/**` + `lib/dto/`;
> this is the porter's index. **Most pro routes return INLINE shapes** (no typed
> DTO), so the iOS contract posture is: always ship a Swift decode test; add an
> ajv contract entry only where a typed backend DTO exists or is a clean add;
> otherwise keep the fixture decode-only (like `proSession.json`) and note it.
>
> Envelope: `jsonOk(body)` → `{ ok: true, ...body }` (the `ok` is forced; body is
> spread). Money strings are `"50.00"` (no `$`); `Wire.money` adds the symbol.
> Dates are ISO-8601 UTC instants. `requirePro()` guards every route (CLIENT 403s).

## Phase 3 — bookings

- `GET /pro/bookings` — **does NOT exist** (POST-only). The native list source is
  the calendar agenda (`GET /pro/calendar`, already ported as `ProCalendarService`).
- `GET /pro/bookings/[id]` — **booking detail (read).** Returns:
  `{ booking: { id, status, scheduledFor(ISO), endsAt(ISO), locationId(str|null),
  locationType("SALON"|"MOBILE"), locationAddressSnapshot(str|null),
  locationLatSnapshot(num|null), locationLngSnapshot(num|null), bufferMinutes(int),
  durationMinutes(int), totalDurationMinutes(int), subtotalSnapshot("50.00"),
  client:{ fullName, email(str|null), phone(str|null) }, timeZone, timeZoneSource,
  serviceItems:[{ id, serviceId, offeringId(str|null), itemType("BASE"|"ADD_ON"),
  serviceName, priceSnapshot("50.00"), durationMinutesSnapshot(int), sortOrder }] } }`
- `PATCH /pro/bookings/[id]` — accept/cancel/edit. Body (sparse): `{ status?:
  "ACCEPTED"|"CANCELLED", notifyClient?, scheduledFor?(ISO), bufferMinutes?,
  durationMinutes?|totalDurationMinutes?, serviceItems?:[{serviceId, offeringId,
  sortOrder?}], allowOutsideWorkingHours?, allowShortNotice?, allowFarFuture?,
  overrideReason? }`. **Idempotency-Key header REQUIRED.** Returns normalized result.
- `PATCH /pro/bookings/[id]/cancel` — body `{ reason? }`; Idempotency-Key required;
  → `{ booking:{ id, status, sessionStep }, meta:{ mutated } }`.
- `POST /pro/bookings/[id]/rebook` — body `{ mode:"BOOK"|"RECOMMEND_WINDOW"|"CLEAR",
  scheduledFor?(BOOK), windowStart?/windowEnd?(RECOMMEND_WINDOW) }`; Idempotency-Key;
  → `{ ok, mode, nextBookingId?, aftercare:{…} }`.
- `POST /pro/bookings/[id]/consultation-proposal` — body `{ proposedServicesJson:{items:
  [{serviceId, offeringId?, itemType:"BASE"|"ADD_ON", label, price, durationMinutes,
  notes?, sortOrder?, source:"BOOKING"|"PROPOSAL"}]}, proposedTotal, notes? }`.
- `POST /pro/bookings/[id]/consultation/in-person-decision` — body `{ action:"APPROVED"|"REJECTED" }`.
- `GET /pro/bookings/[id]/consultation-services` — `[{ offeringId, serviceId,
  serviceName, categoryName(str|null), defaultPrice(num|null), defaultDurationMinutes(num|null) }]`.
- `POST /pro/bookings/[id]/final-review` — body `{ finalLineItems:[…], expectedSubtotal?,
  recommendedProducts?, rebookMode?, rebookedFor?/rebookWindow* }`.
- Session: `POST .../session/{start,finish}`, `POST .../session/step {step}`,
  `GET .../session/state` → `{ state, hash }`. (Already ported via `ProSessionService`.)
- Checkout: `PATCH .../checkout/mark-paid { paymentMethod }`, `PATCH .../checkout/waive`.
- `POST /pro/bookings` (create-for-client), `POST .../invite`, `GET/POST .../media`.

## Phase 4 — profile / offerings / portfolio / reviews

- **Read** = `GET /professionals/[id]` (PUBLIC; already ported as `ProfileService.
  professional(id:)` → `ProPublicProfile`). Carries header/stats/offerings/
  portfolioTiles/reviews/isFavoritedByMe. Reviews are **read-only** (embedded here;
  clients write them). The pro's own id is on the JWT/me.
- `PATCH /pro/profile` — body `{ businessName?, bio?, location?, avatarUrl?,
  professionType?, nameDisplay?("BUSINESS_NAME"|"FIRST_LAST_NAME"|"BUSINESS_AND_NAME"),
  handle? }` → `{ profile:{ id, businessName, handle, bio, location, avatarUrl,
  professionType, nameDisplay, isPremium } }`.
- `GET /pro/offerings` → `{ offerings:[{ id, serviceId, title(null),
  description(str|null), customImageUrl(str|null), offersInSalon, offersMobile,
  salonPriceStartingAt("50.00"|null), salonDurationMinutes(int|null),
  mobilePriceStartingAt(str|null), mobileDurationMinutes(int|null), isActive,
  serviceName, categoryName(str|null), serviceDefaultImageUrl(str|null),
  minPrice("50.00"), isServiceActive, isCategoryActive, serviceIsAddOnEligible,
  serviceAddOnGroup(str|null) }] }`.
- `POST /pro/offerings` (create, body serviceId + salon/mobile price+duration),
  `GET/PATCH/DELETE /pro/offerings/[id]` (PATCH sparse; DELETE soft → isActive:false).
  Rate-limited `pro:offerings:write`.
- `GET /pro/services?locationType=SALON|MOBILE` → service catalog for adding offerings.
- Portfolio media: `POST /pro/media { uploadSessionId, caption?, mediaType, serviceIds[],
  primaryServiceId?, isEligibleForLooks?, isFeaturedInPortfolio? }` → `ProMediaCreateResponseDTO`
  (TYPED, `lib/dto/mediaAttach.ts`). `PATCH /pro/media/[id]`, `POST/DELETE /pro/media/[id]/portfolio`.
- Looks publication: `POST/GET/PATCH /pro/looks[/id]` (TYPED, `lib/looks/publication/contracts.ts`
  → `ProLookPublicationResultDto`).

## Phase 5a — clients / chart + aftercare

- `GET /pro/clients` → `{ count, clients:[…] }`, each `{ id, fullName, canViewClient(bool),
  email(str|null), phone(str|null), lastBookingLabel(str) }` — the **visible client directory**
  (web `/pro/clients` 1:1: `proClientVisibilityWhere` scope, name-ordered, `take:500`). Native
  loads this and filters client-side (web has no server search). _tovis-app PR #434._
- `GET /pro/clients/search?q=` → `{ query, recentClients:[…], otherClients:[…] }`,
  each `{ id, fullName, canViewClient(bool), email(str|null), phone(str|null) }`. Returns empty
  lists for empty `q` (anti-enumeration) — use the directory GET above for the list, this for typeahead.
- `POST /pro/clients { firstName, lastName, email, phone }` → `{ id, clientId, userId, email }`.
- Client chart is **server-rendered** (`/pro/clients/[id]?view=chart&tab=…`) — NO single
  GET API. Chart write endpoints exist: `PATCH .../profile-context {occupation, proCapturedSocialHandle}`,
  `GET .../service-addresses`, `POST .../notes {title?,body,kind:"GENERAL"|"CONSULTATION"|"COMMUNICATION_STYLE"}`,
  `POST .../allergies {label,description?,severity}`, `PATCH .../alert {alertBanner}`,
  `PUT/DELETE .../do-not-rebook`. **Founder-flag-gated** (`isClientTechnicalRecordEnabled`,
  404 if off): `POST .../formula`, `POST .../consent`, `PATCH .../photo-release`.
  ⚠️ Visibility: `assertProCanViewClient`; PII (notes/allergies/occupation) encrypted at rest,
  decrypted on read. Since there's no chart-read API, the iOS chart needs a NEW
  aggregate GET DTO on the backend (companion PR) OR compose from existing reads.
- Aftercare list is **server-rendered** (`/pro/aftercare` + `AftercareListClient`). Per-booking
  aftercare API: `GET /pro/bookings/[id]/aftercare` → `{ booking:{ id, status, sessionStep,
  scheduledFor, finishedAt, locationTimeZone, aftercareSummary:{ id, notes, rebookMode, rebookedFor,
  rebookWindowStart/End, rebookDeclinedAt, draftSavedAt, sentToClientAt, lastEditedAt, version,
  isFinalized, publicAccess:{accessMode,hasPublicAccess,clientAftercareHref}, rebookSlot:{…}|null,
  recommendedProducts:[…] }|null } }`. `POST /pro/bookings/[id]/aftercare` (save/send draft).
  Like clients, the **aftercare LIST needs a new GET DTO** on the backend for native.

## Phase 5b — availability / working-hours / locations

- `GET /pro/availability/busy-days?from&to&tz` → `{ ok, tz, from, to, days:{ "YYYY-MM-DD":{bookings,blocked} } }`.
- `GET /pro/working-hours?locationType&locationId` / `POST` (body `{ workingHours:{ sun..sat:
  {enabled,start"HH:MM",end"HH:MM"} } }`) → `{ workingHours, locationType, locationId, location, usedDefault, … }`.
- `POST /pro/schedule/publish` → `{ liveModes[], locationsPublished, scheduleConfigVersion, blockedLocations[] }`.
- Blocked time: `GET/POST /pro/calendar/blocked` (block = `{ id, startsAt, endsAt, note(str|null),
  locationId(str|null) }`), `GET/PATCH/DELETE /pro/calendar/blocked/[id]`. **✅ native (inc.2):**
  `ProCalendarService.{createBlock,block,updateBlock,deleteBlock}` + `ProBlockTimeSheet`; create
  pins to a bookable location, server validates 15min–24h window + overlaps.
- Locations: `GET /pro/locations` → `{ locations:[{ id, type:"SALON"|"SUITE"|"MOBILE_BASE",
  name, isPrimary, isBookable, formattedAddress, addressLine1/2, city, state, postalCode,
  countryCode, placeId, lat(num|null), lng(num|null), timeZone, workingHours, bufferMinutes,
  stepMinutes, advanceNoticeMinutes, maxDaysAhead, createdAt, updatedAt }] }`. `POST` create,
  `PATCH/DELETE /pro/locations/[id]`, `PATCH /pro/locations/[id]/mobile-base {postalCode?,radiusMiles}`.

## Phase 5c — notifications + membership/payments

- Pro notifications are a **distinct** surface from client (different table/fields):
  `GET /pro/notifications?take&cursor&unread&eventKey` → `{ items:[{ id, eventKey, priority(num|null),
  title, body(str|null), href, data(obj|null), createdAt, seenAt(str|null), readAt(str|null),
  bookingId(str|null), reviewId(str|null) }], nextCursor(str|null) }`.
- `GET /pro/notifications/summary` → `{ hasUnread, count }`.
- `POST /pro/notifications/[id]/mark-read`, `POST /pro/notifications/mark-read` → `{ ok, count }`.
- `GET/PATCH /pro/notification-preferences` — **shared** `NotificationPreferencesPayload` shape
  (already ported as `NotificationPreferencesPayload`; pro just has a different category set).
  GET → `{ categories:[…], events:{eventKey:{inAppEnabled,smsEnabled,emailEnabled}}, quietHours:
  {enabled,startMinutes,endMinutes} }`. PATCH body `{ events:[{eventKey,channels}], quietHours }`.
- `GET /pro/membership/status` → `{ membership:{ planKey, status, entitlements:{…}, currentPeriodEnd,
  cancelAtPeriodEnd, trialEndsAt, hasBillingAccount } }`.
- `GET/PATCH /pro/payment-settings` → `{ paymentSettings:{ collectPaymentAt:"AT_BOOKING"|"AFTER_SERVICE",
  depositEnabled, depositType:"FLAT"|"PERCENT", depositFlatAmount, depositPercent, depositScope, accept*…,
  tipsEnabled, allowCustomTip, tipSuggestions:[{label,percent}], *Handle, paymentNote } }`.
- `GET /pro/payments/stripe/status` → adds `stripeAccount:{ connected, chargesEnabled, payoutsEnabled,
  detailsSubmitted, status:"NOT_STARTED"|"ONBOARDING_STARTED"|"DISABLED"|"RESTRICTED"|"ENABLED",
  requirements:{currentlyDue[],eventuallyDue[],disabledReason} }`.

## Camera (AI photographer)

- `GET /pro/camera/shot-packs` → `{ ok, version, packs:[{ id, name, tagline,
  serviceKeywords[], trendScore, steps:[{ title, hint, icon, face:"required"|"absent"|"either",
  fillBandMin(num|null), fillBandMax(num|null), isDetail, allowsClosedEyes,
  pose:[{ kind, params(obj|null), tip }] }] }] }`. Inline; decode-only
  (`proShotPacks.json`). Unknown pose-rule kinds are DROPPED at guide-build.
- `POST /pro/camera/look-brief` (PR #454) — body `{ image:{ base64, mediaType },
  serviceName?, measuredSummary? }` → `{ ok, brief:{ summary, poseRules:[same
  wire shape as pack pose rules], directionLines:[str] } }`. Claude-vision
  enhance of a "Match a look" reference; consent-gated in the UI; image ≤ ~4 MB
  base64; free w/ daily cap (429 when exhausted); 502 upstream-down, 422 unreadable.
  Inline; decode-only (`proLookBrief.json`).
- `POST /pro/camera/set-critique` (PR #454) — body `{ photos:[{ id, phase:
  "BEFORE"|"AFTER", image:{ base64, mediaType } }] (1–10, ≤ ~3.9 MB total),
  serviceName? }` → `{ ok, critique:{ overall, strengths:[str], photos:[{ id,
  verdict:"portfolio"|"keep"|"retake" (plain string — render unknowns neutrally),
  note, retakeTip(str|null) }] } }`. Same consent/cap/error posture. Inline;
  decode-only (`proSetCritique.json`).
