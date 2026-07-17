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