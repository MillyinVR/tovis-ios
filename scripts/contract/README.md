# Wire-contract test

Validates the iOS wire-model **fixtures** against the backend's generated API
JSON Schema, so a backend DTO change fails loudly here (or in the Swift decode
tests) instead of silently breaking decode at runtime.

The fixtures in `TovisKit/Tests/TovisKitTests/Fixtures/*.json` are the single
source of wire-shape truth — they are **decoded by the Swift tests** AND
**validated against the schema** by this script.

## Run

```bash
cd scripts/contract
npm install        # one-time (ajv)
npm run validate
```

By default it reads the schema from the sibling backend repo at
`../../../tovis-app/schema/api/tovis-api.schema.json`. Override with:

```bash
TOVIS_API_SCHEMA=/abs/path/to/tovis-api.schema.json npm run validate
```

## Add a new fixture

1. Drop `Fixtures/<name>.json` (the full endpoint response, envelope included).
2. Decode it in a Swift test via `fixture("<name>")`.
3. Add a `CHECKS` entry in `validate-fixtures.mjs` mapping it to its backend
   schema definition (e.g. `ClientHomeDTO`).