// Contract test: validate the iOS wire-model test fixtures against the backend
// API JSON Schema (tovis-app/schema/api/tovis-api.schema.json).
//
// The SAME fixture files are decoded by the Swift tests (TovisKit) and validated
// here against the backend's generated schema. So if a backend DTO changes shape
// (a field becomes required, a type changes, etc.), this fails loudly instead of
// the app silently failing to decode at runtime.
//
// The schema lives in the sibling backend repo. Override its path with
//   TOVIS_API_SCHEMA=/abs/path/to/tovis-api.schema.json npm run validate
import { readFileSync, existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import Ajv from 'ajv'

const here = dirname(fileURLToPath(import.meta.url))
const fixturesDir = resolve(here, '../../TovisKit/Tests/TovisKitTests/Fixtures')
const defaultSchema = resolve(here, '../../../tovis-app/schema/api/tovis-api.schema.json')
const schemaPath = process.env.TOVIS_API_SCHEMA || defaultSchema

// Each fixture is the FULL endpoint response (envelope included). `pick` returns
// the object(s) to validate against the named backend schema definition.
const CHECKS = [
  { file: 'clientHome.json', def: 'ClientHomeDTO', pick: (d) => [d.home] },
  { file: 'clientMe.json', def: 'ClientMePageDTO', pick: (d) => [d.me] },
  // Validate the whole feed (not just the rows) so `unreadCount` +
  // `markReadEventKeys` — the bell's badge and the mark-read allowlist — are
  // covered too.
  { file: 'clientActivity.json', def: 'ClientActivityFeedDTO', pick: (d) => [d.activity] },
  { file: 'messagesThreads.json', def: 'MessageThreadListItemDTO', pick: (d) => d.threads },
  { file: 'clientInviteLink.json', def: 'ClientInviteLinkResponseDTO', pick: (d) => [d] },
  { file: 'publicClaim.json', def: 'ClaimPublicViewResponseDTO', pick: (d) => [d] },
  { file: 'messageThread.json', def: 'MessageDTO', pick: (d) => d.messages },
  { file: 'searchServices.json', def: 'SearchServiceItemDto', pick: (d) => d.items },
  { file: 'availabilityBootstrap.json', def: 'AvailabilityBootstrapOk', pick: (d) => [d] },
  { file: 'availabilityDay.json', def: 'AvailabilityDayOk', pick: (d) => [d] },
  { file: 'proProfile.json', def: 'ProPublicProfileDto', pick: (d) => [d.professional] },
  {
    file: 'clientBookings.json',
    def: 'ClientBookingDTO',
    pick: (d) => [
      ...d.buckets.upcoming,
      ...d.buckets.pending,
      ...d.buckets.prebooked,
      ...d.buckets.past,
    ],
  },
  { file: 'looksFeed.json', def: 'LooksFeedItemDto', pick: (d) => d.items },
  { file: 'lookDetail.json', def: 'LooksDetailItemDto', pick: (d) => [d.item] },
  { file: 'looksComments.json', def: 'LooksCommentDto', pick: (d) => d.comments },
  { file: 'searchPros.json', def: 'SearchProItemDto', pick: (d) => d.items },
  {
    file: 'clientNotifications.json',
    def: 'ClientNotificationDTO',
    pick: (d) => d.items,
  },
  {
    file: 'notificationPreferences.json',
    def: 'NotificationPreferencesPayload',
    pick: (d) => [d],
  },
  {
    file: 'offeringAddOns.json',
    def: 'OfferingAddOnItemDTO',
    pick: (d) => d.addOns,
  },
  {
    file: 'clientAddresses.json',
    def: 'ClientAddressDTO',
    pick: (d) => d.addresses,
  },
  {
    file: 'proBookingMedia.json',
    def: 'ProBookingMediaItemDTO',
    pick: (d) => d.items,
  },
  {
    file: 'proFinance.json',
    def: 'ProFinancePageData',
    pick: (d) => [d],
  },
  {
    file: 'clientAftercareDetail.json',
    def: 'ClientAftercareDetailDTO',
    pick: (d) => [d],
  },
  {
    file: 'proVisibility.json',
    def: 'ProVisibilityHealthDTO',
    pick: (d) => [d.visibility],
  },
  {
    file: 'supportTicket.json',
    def: 'SupportTicketDTO',
    pick: (d) => [d],
  },
  // GET /api/v1/pro/overview returns `jsonOk(overview)` where overview is
  // `loadProOverviewPage(): Promise<ProOverviewPageData>` — so the payload is
  // spread at the ROOT (alongside `ok`), not nested under a key.
  {
    file: 'proOverview.json',
    def: 'ProOverviewPageData',
    pick: (d) => [d],
  },
  // GET /api/v1/pro/camera/usage returns `jsonOk({ usage })`.
  {
    file: 'proCameraUsage.json',
    def: 'ProCameraUsage',
    pick: (d) => [d.usage],
  },
  // POST /api/v1/holds returns `jsonOk({ hold, meta })`. `durationMinutes` is
  // what the slot is actually RESERVED for — base + the add-ons sent with the
  // create (B1-A) — so this fixture is the wire proof that the hold and
  // finalize size the same window.
  {
    file: 'bookingHoldCreate.json',
    def: 'BookingHoldCreateDTO',
    pick: (d) => [d.hold],
  },
  // GET /api/v1/pro/availability/busy-days returns the payload at the ROOT
  // (`jsonOk({ tz, from, to, days })`), so the whole document is the DTO —
  // including `days`, whose per-day `{ bookings, blocked }` shape is what the
  // rebook month sheet's overlay draws.
  {
    file: 'proBusyDays.json',
    def: 'ProAvailabilityBusyDaysOk',
    pick: (d) => [d],
  },
  // POST /api/v1/pro/working-hours returns the payload at the ROOT. A VERBATIM
  // capture off the running route (2026-07-25) of the B8 case that matters:
  // a save that narrowed Thursday over an existing 11:00 booking, so
  // `strandedBookings` is populated rather than absent. The GET twin
  // (proWorkingHours.json) deliberately has no such field — the server omits it
  // entirely when nothing changed, and iOS must keep decoding both.
  {
    file: 'proWorkingHoursSave.json',
    def: 'ProWorkingHoursSaveOk',
    pick: (d) => [d],
  },
  // GET /api/v1/pro/calendar — the payload is at the ROOT. A VERBATIM capture
  // off the running route under `scope=ALL` over a WEEK (2026-08-01), so it
  // carries the whole K-series accretion at once: K1's `paymentBadge`, K3's
  // `scope` + `locationId`, K5's `relationshipBadge`, K7/K8's `serviceSwatch`,
  // K11/K13's `clientConfirmation`, K15's `consentRequirement`, and two
  // `management.waitlistToday` rows (the synthetic BOOKING-kind shape with a
  // null location).
  //
  // Every optional field is pinned on BOTH sides, because absent is the common
  // case and a fixture where every row carried one would prove nothing:
  //   * `serviceSwatch` — four rows carry "09", two carry "02" (a second hue,
  //     one of them resolved through its BASE service item rather than the
  //     per-service fallback), and the two Haircut & Style rows OMIT the key
  //     because that pro never picked a colour.
  //   * `clientConfirmation` — one CLIENT_CONFIRMED, one DECLINED, one
  //     AWAITING_CLIENT, five omitting it (nobody asked).
  //   * `consentRequirement` — exactly ONE row carries it (a FUTURE booking
  //     whose service requires a form this client hasn't signed) and seven omit
  //     it. The past Haircut & Style booking has the same unsigned requirement
  //     and still omits the key: the badge helper's `significant` goes false
  //     once the appointment has started, and the route drops an insignificant
  //     badge outright. That row is the significance gate, captured.
  //
  // Until K6 this feed had NO contract coverage at all — the response type lived
  // inline in the route and had no name to export (K4-B). Every field the chain
  // had added crossed to the device unchecked.
  {
    file: 'proCalendar.json',
    def: 'ProCalendarResponseDTO',
    pick: (d) => [d],
  },
  // GET /api/v1/pro/bookings/{id}/session/state — the payload is at the ROOT.
  // A VERBATIM capture (2026-08-01) of the LOUD case: a booking whose service
  // requires a form the client has not signed, so `unsignedConsentForms` is
  // present beside `state` (K17-A).
  //
  // 🔴 The quiet case is the same route with the key simply ABSENT — the route
  // has ONE representation for "nothing to sign", never `[]`. It is pinned
  // device-side by `ConsentRequirementTests` rather than by a second CHECKS
  // entry, because the fixture that models it (`proSessionState.json`) is a
  // hand-built shape from PR #441 that no longer matches today's server at all:
  // it predates `stateHash`, `bookingUpdatedAt`, `checkout.paymentAuthorizedAt`
  // /`stripePaymentStatus` and `consultation.updatedAt`. It still earns its keep
  // in the Swift tests — it is the only fixture carrying a consultation PROOF —
  // but a contract fixture models the CURRENT server, so it stays out of here
  // until someone re-captures it ([[contract-fixture-models-the-current-server]]).
  {
    file: 'proSessionStateConsent.json',
    def: 'ProSessionStateResponseDTO',
    pick: (d) => [d],
  },
  // GET /api/v1/pro/clients/{id}/policy — K16's per-client booking requirements
  // (K17-B). VERBATIM captures (2026-08-01) of the A/B that is the entire point
  // of this contract, driven against the live local route in both flag states:
  //
  //   proClientPolicy.json      a STORED `requireCardOnFile: true` sitting beside
  //                             `cardOnFileRailEnabled: false` — the rail is dark,
  //                             and the stored switch is STILL true. The resolver
  //                             would have zeroed it; the read route deliberately
  //                             does not, because a pro must see what they set.
  //                             The device disables that one CONTROL instead
  //                             ([[kill-switch-must-reach-the-control]]).
  //   proClientPolicyNone.json  the DELETE response — `policy: null`, which is a
  //                             different fact from four falses and is why the
  //                             write route deletes the row rather than storing
  //                             an all-off one. Also the null-branch of the
  //                             `policy` anyOf, so both arms are covered here.
  {
    file: 'proClientPolicy.json',
    def: 'ProClientPolicyResponseDTO',
    pick: (d) => [d],
  },
  {
    file: 'proClientPolicyNone.json',
    def: 'ProClientPolicyResponseDTO',
    pick: (d) => [d],
  },
  // GET /api/v1/pro/clients/{id}/technical — the client technical record.
  //
  // 🔴 This route had NO declared shape until K17-B: the handler built an inline
  // literal, nothing was `satisfies`-checked, and the generated schema carried no
  // definition for it. That is why K14 could put `formVersion` and `consentForms`
  // on the wire (#809) with zero contract coverage, and why the device decoded
  // neither for two releases. tovis-app now declares
  // `ProClientTechnicalRecordResponseDTO`, so this fixture finally has something
  // to be checked against.
  //
  // VERBATIM capture (2026-08-01). Deliberately mixed: THREE consent rows, one
  // with `formVersion: null` (a free-text record written during the drive
  // through the picker's "No form" branch) and two carrying attestations — which
  // between them cover all three `originLabel` phrasings the server composes.
  // The record entries validate individually so a required field lost on any ONE
  // of them fails here rather than at runtime.
  {
    file: 'proClientTechnical.json',
    def: 'ProClientTechnicalRecordResponseDTO',
    pick: (d) => [d],
  },
  {
    file: 'proClientTechnical.json',
    def: 'ProClientConsentRecordDTO',
    pick: (d) => d.consents,
  },
  {
    file: 'proClientTechnical.json',
    def: 'ProConsentFormOptionDTO',
    pick: (d) => d.consentForms,
  },
  // GET /api/v1/pro/bookings — buckets + stats; validate every row, so a
  // required field lost on ANY of them fails here rather than at runtime. The
  // fixture models TODAY's server: both badges present on every row (K5-B).
  // The pre-deploy shape — neither badge sent — is a device-side concern and is
  // pinned by inline JSON in DecodingTests, not by a stale fixture row.
  {
    file: 'proBookingsList.json',
    def: 'ProBookingListItemDTO',
    pick: (d) => [...d.today, ...d.upcoming, ...d.past, ...d.cancelled],
  },
]

function fail(msg) {
  console.error(`✗ ${msg}`)
  process.exitCode = 1
}

if (!existsSync(schemaPath)) {
  fail(
    `Backend schema not found at:\n    ${schemaPath}\n` +
      `  Set TOVIS_API_SCHEMA to the path of tovis-app/schema/api/tovis-api.schema.json.`,
  )
  process.exit(1)
}

const schema = JSON.parse(readFileSync(schemaPath, 'utf8'))

// ts-json-schema-generator renders type-fest's `JsonArray` (a `JsonValue[]`) as an
// OBJECT requiring a numeric `length` — it picks up the array's `length` property
// instead of emitting an array schema. That makes every `JsonValue` field reject
// any nested array (e.g. a consultation's `proposedServicesJson.items`). Repair the
// one definition here rather than regenerating the shared backend schema.
if (schema.definitions?.JsonArray) {
  schema.definitions.JsonArray = {
    type: 'array',
    items: { $ref: '#/definitions/JsonValue' },
  }
}

const ajv = new Ajv({ allErrors: true, strict: false })
ajv.addSchema(schema, 'api')

let checked = 0
for (const check of CHECKS) {
  const path = resolve(fixturesDir, check.file)
  if (!existsSync(path)) {
    fail(`${check.file}: fixture missing at ${path}`)
    continue
  }

  const validate = ajv.getSchema(`api#/definitions/${check.def}`)
  if (!validate) {
    fail(`${check.file}: schema has no definition '${check.def}'`)
    continue
  }

  const data = JSON.parse(readFileSync(path, 'utf8'))
  const items = check.pick(data)
  let ok = true
  items.forEach((item, i) => {
    if (!validate(item)) {
      ok = false
      const where = items.length > 1 ? `[${i}]` : ''
      fail(`${check.file}${where} does not match ${check.def}:`)
      for (const err of validate.errors ?? []) {
        console.error(`    ${err.instancePath || '(root)'} ${err.message}`)
      }
    }
  })

  checked += items.length
  if (ok) console.log(`✓ ${check.file} → ${check.def} (${items.length} object(s))`)
}

if (process.exitCode === 1) {
  console.error('\nContract validation FAILED — fixtures drifted from the backend schema.')
} else {
  console.log(`\nContract OK — ${checked} object(s) validated against the API schema.`)
}