# Tovis iOS

Native SwiftUI client for the Tovis backend (the `tovis-app` Next.js API). Talks
to the backend purely over its versioned HTTP API (`/api/v1`). No shared code
with the backend repo — the contract is the wire schema
(`schema/api/tovis-api.schema.json` in `tovis-app`).

## Layout

```
tovis-ios/
├── TovisKit/          ← reusable, UI-free core (a local Swift Package)
│   └── Sources/TovisKit/
│       ├── Config/        TovisConfig (base URL / environments)
│       ├── Networking/    APIClient, APIError
│       ├── Auth/          TokenStore (Keychain), AuthService, token refresh
│       ├── Devices/       DeviceService (push token registration)
│       ├── Models/        Codable models mirroring /api/v1 DTOs
│       └── TovisClient    the wired-up entry point
├── AppFiles/          ← SwiftUI files to drop INTO the Xcode app target
└── Tovis.xcodeproj    ← YOU create this in Xcode (step 1 below)
```

`TovisKit` already builds and its tests pass (`cd TovisKit && swift test`).

## Setup

### 1. Create the Xcode app project (you do this in Xcode)

Xcode can't be scaffolded cleanly from the CLI, so create the app shell yourself:

1. **Xcode → File → New → Project… → iOS → App.**
2. Product Name: **Tovis**  ·  Interface: **SwiftUI**  ·  Language: **Swift**.
3. Organization Identifier: your reverse-domain (e.g. `me.tovis`) → Bundle ID
   becomes `me.tovis.Tovis`. **Write this Bundle ID down** — it's the
   `APNS_BUNDLE_ID` the backend push config needs later.
4. **Save it INTO this folder** (`~/Dev/tovis-ios`). Xcode creates
   `Tovis.xcodeproj` and a `Tovis/` source folder next to `TovisKit/`.

### 2. Add TovisKit as a local package

In Xcode: **File → Add Package Dependencies… → Add Local… →** select the
`TovisKit` folder → add the **TovisKit** library to the **Tovis** target.

### 3. Add the app files

Move the four files from `AppFiles/` into your `Tovis/` app-target folder:

- `SessionModel.swift`, `LoginView.swift`, `RootView.swift` — add as-is.
- `TovisApp.swift.example` — use it to **replace** the `TovisApp.swift` Xcode
  generated (it just creates the `SessionModel` and injects it). Delete the
  template `ContentView.swift`.

(With Xcode 16+ synchronized folders, files you drop into `Tovis/` on disk
appear in the project automatically.)

### 4. Allow localhost during development (ATS)

To hit `http://localhost:3000` from the simulator, add an App Transport Security
exception. In the target's **Info** tab add:

```
App Transport Security Settings (Dictionary)
  └─ Allow Local Networking (Boolean) = YES
```

Then run the backend (`cd ../tovis-app && npm run dev`), build & run the app in
the simulator, and sign in with a real account. `TovisConfig.local` points at
`http://localhost:3000/api/v1`. Switch `SessionModel(config:)` to `.production`
(set the real URL in `TovisConfig.swift`) for device/release builds.

## What works now (matches the audited backend)

- **Sign in** → `POST /api/v1/auth/login`, JWT persisted in the Keychain.
- **Bearer auth** on every request; **401 → auto token refresh → retry** via
  `POST /api/v1/auth/refresh`.
- **Per-device id** generated and sent on login (for per-device revocation).
- **Push registration** scaffolded (`DeviceService` → `POST /api/v1/devices`) —
  wire it to APNs once you add the Push Notifications capability.

## Next steps (see the backend handoff: `tovis-app/docs/mobile/native-readiness-handoff.md`)

1. Add typed services + models for the screens you build first (availability,
   holds, bookings, search) — the DTOs are in the wire schema; mirror them in
   `TovisKit/Models/`.
2. Push: add the **Push Notifications** capability, register for APNs, call
   `DeviceService.register(apnsToken:deviceId:)`. Operator sets APNs creds in
   Vercel (backend runbook: `docs/mobile/push-go-live-runbook.md`).
3. Payments: open Stripe Checkout URLs in `ASWebAuthenticationSession`; set up
   **Universal Links** to catch the return (backend Tier 3.2).
4. Replace the browser Turnstile signup defense with **App Attest** (backend Tier 4.1).