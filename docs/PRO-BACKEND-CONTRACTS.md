# PRO backend API contract map — retired

This hand-maintained contract map has been retired. The source of truth for
the pro `/api/v1` wire contract is now the fixtures under `scripts/contract/`,
validated in CI against the live backend schema by the **"Wire contract
(fixtures vs backend schema)"** job (`.github/workflows/ci.yml`) — a
hand-written doc drifts the moment a DTO changes; the fixtures cannot.

For the backend route handlers themselves, see `tovis-app/app/api/v1/pro/**`
and `lib/dto/`.
