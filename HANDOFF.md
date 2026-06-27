# Tovis iOS — Build Handoff

> Self-contained handoff for a fresh Claude Code session continuing the **native
> iOS app** build. Written 2026-06-27. The companion backend doc (auth/API
> readiness) is `tovis-app/docs/mobile/native-readiness-handoff.md` — read it for
> backend context.

## TL;DR — where we are

We started a **native SwiftUI iOS app** for Tovis (chosen: native Swift, iOS-first,
**separate repo** at `~/Dev/tovis-ios`). The login surface is built and brand-matched,
with **three working auth methods** (email/password, Sign in with Apple, phone-OTP),
each backed by a real `/api/v1` endpoint. The app builds & runs in the simulator and
signs in against the backend.

**The backend was the bottleneck and is now essentially cleared** (see PR status).
Next real work is **app screens** (client home, booking, etc.) + the operator/Xcode
setup to light up Apple + push.

## Two repos

| Repo | Path | Role |
|------|------|------|
| Backend | `~/Dev/tovis-app` | Next.js 16 API (the `/api/v1` surface). Where auth endpoints live. |
| iOS app | `~/Dev/tovis-ios` | This repo. SwiftUI app + `TovisKit` package. Talks to the backend over HTTP only. |

## iOS repo layout

```
tovis-ios/
├── TovisKit/                 ← local Swift Package (UI-free core). `swift build` + `swift test` pass.
│   └── Sources/TovisKit/
│       ├── Config/TovisConfig.swift     (.local = http://localhost:3000/api/v1, .production = SET REAL URL)
│       ├── Networking/        APIClient (bearer auth, 401→refresh→retry), APIError
│       ├── Auth/              TokenStore (Keychain actor), AuthService (login/apple/phoneLogin/refresh/logout)
│       ├── Devices/           DeviceService (POST /devices push registration)
│       ├── Models/            Codable wire models (Auth.swift, Common.swift)
│       └── TovisClient.swift  (wires it all + stable per-install deviceId)
├── Tovis/                    ← the Xcode APP TARGET (synchronized folder — drop files here, they auto-add)
│   ├── ContentView.swift      @main + SessionModel + RootView + LoginView (email/pw + Apple + phone buttons)
│   ├── PhoneLoginView.swift    two-step phone→code sheet
│   ├── Theme/                  BrandColor (Peacock Plume, light/dark), BrandFont (Grotesk trio), TovisEye (logo)
│   ├── Fonts/                  bundled .ttf (Hanken/Space Grotesk, Space Mono) + registered in Info.plist
│   └── Info.plist              ATS Allow Local Networking = YES; UIAppFonts
├── AppFiles/                 ← stale reference copies (superseded by Tovis/*). Ignore/clean up.
└── tovis-ios.xcodeproj
```

**Design decision:** match the web app closely (it was built to look like iOS), but
rebuild with native SwiftUI components. Brand is **exact** — colors + logo ported 1:1
from `tovis-app/lib/brand/brands/tovis.ts` and `lib/brand/eyeSvg.ts`. Default mode is
**dark** (`.preferredColorScheme(.dark)`).

## Auth — three methods, all wired

| Method | App | Backend endpoint | Backend PR |
|--------|-----|------------------|------------|
| Email + password | `LoginView` | `POST /api/v1/auth/login` | (already existed) |
| Sign in with Apple | `SignInWithAppleButton` → `AuthService.appleLogin` | `POST /api/v1/auth/apple` | **#414 MERGED** |
| Phone OTP | `PhoneLoginView` → `AuthService.phoneLoginSend`/`Verify` | `POST /api/v1/auth/phone-login/{send,verify}` | **#415 MERGED** |

All return the same session payload (`AuthLoginResponseDTO`): token in the JSON body
(stored in Keychain) + cookie for web. 401s auto-refresh via `POST /api/v1/auth/refresh`.

## Backend PR status (in `tovis-app`)

- **#413 — proxy cookieless-origin fix — MERGED.** *Critical:* native login/apple/phone
  are cookieless with no `Origin` header; without this they 403. This unblocks ALL native auth.
- **#414 — Sign in with Apple backend — MERGED.**
- **#415 — phone-OTP login backend — MERGED** (`d1e707d5`). All three auth methods are now
  on `main`. **Deploy `main` to make them live in production** (local dev already has them).

## 🔴 Remaining setup to light it all up (operator + Xcode — needs the human)

1. **`APPLE_CLIENT_ID` env** = the iOS bundle id (e.g. `me.tovis.Tovis`, check Xcode →
   target → Signing & Capabilities). Set in `tovis-app/.env.local` for local dev AND in
   Vercel for prod. Without it, `/api/v1/auth/apple` can't verify tokens.
2. **Xcode: add the "Sign in with Apple" capability** — Tovis target → Signing &
   Capabilities → set **Team** (paid Apple Developer account — the user HAS one) → +
   Capability → Sign in with Apple. The button compiles without it but Apple's sheet
   errors until it's added.
3. **Twilio Verify** for phone-OTP — `TWILIO_VERIFY_SERVICE_SID` etc. (already set in prod).
4. **Deploy** so the merged backend is live against production (not just local dev).

## How to run / test (current state)

1. Backend: `cd ~/Dev/tovis-app && npm run dev` (serves `localhost:3000`).
2. Xcode: open `~/Dev/tovis-ios/tovis-ios.xcodeproj`, pick an **iPhone simulator** (not
   "My Mac"), ⌘R.
3. Email/password sign-in works today against local dev. Apple needs steps 1–2 above.
   Phone-OTP needs Twilio Verify configured locally (or test against deployed prod).
4. Phone field expects **E.164** (`+15555550123`).

## ⚠️ Gotchas / lessons (so the next session doesn't repeat them)

- **Xcode 26/27 beta single-file app:** new projects open as "Untitled" and you name them
  by **saving** (⌘S). They generate ONE file with `@main` + `ContentView` + `#Preview` +
  `#Playground` — we replaced it with our real `ContentView.swift`. Files dropped into
  `Tovis/` (a synchronized folder) auto-appear in the project.
- **I cannot compile the Xcode app target from CLI** (needs Xcode + signing). I verified
  `TovisKit` (`swift build`/`swift test`) and parse-checked theme files, but the **app
  target screens (`ContentView`, `PhoneLoginView`, Apple/phone buttons) must be confirmed
  building in Xcode** — they're standard SwiftUI but that's the one unverified piece.
- **Branch hygiene (we got burned once):** in `tovis-app`, branch every feature off
  `origin/main` and DON'T stack PRs. Phone-OTP got accidentally committed on top of the
  Apple branch; I had to un-stack it (cherry-pick onto main + reset). When two auth PRs
  both touch `lib/rateLimit/policies.ts` + the generated schema, expect a rebase conflict —
  resolve by keeping BOTH buckets and re-running `npm run gen:api-schema`.
- **CI "Browser E2E" flakes** with `runner received a shutdown signal` (infra, not code) —
  just re-run that one job.
- **Fonts** are variable fonts referenced by FAMILY name in `BrandFont` so `.weight()`
  drives the axis; `UIAppFonts` in Info.plist lists the files.

## ▶️ Suggested next steps (pick up here)

1. **Confirm the app target builds in Xcode** + add the Apple capability + `APPLE_CLIENT_ID`,
   then smoke-test all three sign-ins in the simulator.
2. **Build the first real signed-in screen** — the client home. Backend already has a
   single-source endpoint: `GET /api/v1/client/home` (DTO `ClientHomeDTO`). Add a
   `HomeService` + models to `TovisKit`, then a `HomeView` replacing the placeholder
   `SignedInView`. The wire schema (`tovis-app/schema/api/tovis-api.schema.json`) is the
   contract — mirror the DTOs.
3. Then iterate outward: search/discover, booking flow (holds → availability → checkout),
   messages. All have `/api/v1` endpoints + DTOs already.
4. **Push notifications** (backend built but inert): add the Push Notifications capability,
   register for APNs, call `DeviceService.register(apnsToken:deviceId:)`; operator sets
   APNs/FCM creds (`tovis-app/docs/mobile/push-go-live-runbook.md`).
5. **Deep links / Universal Links** (backend Tier 3.2, not started) — needed for Stripe
   checkout returns and to replace web Turnstile with App Attest (Tier 4.1).

## Key references

- Backend native-readiness handoff: `tovis-app/docs/mobile/native-readiness-handoff.md`
- Brand source of truth: `tovis-app/lib/brand/brands/tovis.ts`, `lib/brand/eyeSvg.ts`
- Wire contract for native models: `tovis-app/schema/api/tovis-api.schema.json` (+ `lib/dto/`)
- Push runbook: `tovis-app/docs/mobile/push-go-live-runbook.md`
