# HELM-203 iOS SDK Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Harden `Helm/sdk-iOS`: unify the device id + wire the `attribution_token` handshake (the real attribution-linking fix), add `incrementAuthenticated`, add a `Helm.logging` module, centralize API paths, and cut **v0.3.0**.

**Spec:** `docs/superpowers/specs/2026-06-27-helm-203-sdk-hardening-design.md` (read it — it carries the design + server contract).

**Tech:** Swift 5.9 SwiftPM, single `Helm` target, XCTest. Build/test: `swift build` and `swift test` from repo root (macOS). `@testable import Helm`; inject `URLSession` via `Helm.configure(session:)` + a `MockURLProtocol`; isolate `UserDefaults(suiteName:)`; `InstallationStore(useKeychain: false)` in unit tests.

## Global Constraints
- The `attribution_token` handshake is THE fix — match → `Analytics.onAttributionMatched(id)` → `attribution_token` in the install-register body → server closes the pairing. Mirror Android (`sdk-android` `Analytics.kt`/`AnalyticsClient.kt`).
- Server paths are FIXED (shared contract): attribution `/api/client/v1/attribution/{match,event}/`; analytics `/api/v1/analytics/{installations,events,api-hits}/`; logs `/api/v1/logs` (no trailing slash). Do not change which paths are called.
- Logging auth is a separate `hlit_` ingest token (NOT the `pk_` key); logging no-ops when no ingest token is set; OTLP body must include `timeUnixNano` (string) per record.
- Each commit ends with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Do not push (controller handles release).
- Every task ends green: `swift build` and `swift test` pass.

---

### Task 1: Centralize API paths (#4)
**Files:** create `Sources/Helm/Networking/APIPath.swift`; edit `Attribution.swift`, `Analytics/AnalyticsClient.swift`, `Helm.swift` (doc comment).
- [ ] Add `enum APIPath` with static constants for all current paths (`attributionMatch`, `attributionEvent`, `analyticsInstallations`, `analyticsEvents`, `analyticsApiHits`, `logs`) holding the exact strings from the spec.
- [ ] Replace the 4 hardcoded path literals at their call sites with `APIPath.*`.
- [ ] Fix the `Helm.configure` doc comment that wrongly claims the SDK always appends `/api/client/v1/...`.
- [ ] `swift build && swift test` green. Commit: `HELM-203: centralize SDK API paths in APIPath`.

### Task 2: Device-id unification (#1a)
**Files:** `Attribution.swift`, `AttributionStore.swift`, `Analytics.swift` (add installation-id accessor), tests `AttributionTests.swift`, `AttributionStoreTests.swift`.
- [ ] Add internal `var installationIdValue: String { installationStore.installationId }` on `Analytics`.
- [ ] Give `Attribution` an injected id source: `private let installationId: () -> String`, default `{ Analytics.shared.installationIdValue }`; add to both inits (test init param defaulted).
- [ ] In `_match()`, `let deviceId = installationId()` (was `store.deviceId`).
- [ ] Retire `helm_device_id` from the match path: remove `Keys.deviceId` use from `clearAll()` and the `deviceId` computed property (or leave the property unused + deprecated — but stop matching on it). Reset no longer rotates the id.
- [ ] Rewrite `test_reset_regenerates_device_id` → assert the device id (Keychain installation id) is STABLE across `reset()` while attribution flags/`attribution_id` are cleared. Add a test that `match()` sends the injected installation id as `device_id`.
- [ ] Green. Commit: `HELM-203: unify attribution device_id to the Keychain installation id`.

### Task 3: attribution_token handshake (#1b — THE fix)
**Files:** `Analytics.swift`, `Analytics/AnalyticsClient.swift`, `Attribution.swift`, tests `AnalyticsTests.swift`, `AnalyticsClientTests.swift`, `AttributionTests.swift`.
- [ ] `AnalyticsClient.registrationBody(installationId:userHash:attributionToken:)` — add `attribution_token` to the dict only when the token is non-empty. Update `registerInstallation(...)` signature + call site.
- [ ] `Analytics`: add a lock-guarded `attributionToken: String?`. Add `func onAttributionMatched(_ attributionId: String)` → store token; if started, `register()`. In `start()`, seed `attributionToken` from `AttributionStore().attributionId` before the initial `register()`. `register()` passes the current token.
- [ ] `Attribution._match()`: on successful match (after `store.storeMatch`), call `Analytics.shared.onAttributionMatched(attributionId)`.
- [ ] Tests: (a) `AnalyticsClientTests` — registrationBody includes `attribution_token` when present, omits when empty; (b) `AnalyticsTests` — `onAttributionMatched` while started re-registers and the captured request body carries `attribution_token`; `start()` seeds a pre-stored token; (c) `AttributionTests` — a matched `_match()` triggers analytics re-registration carrying the token (inject a fake analytics hook or assert via the shared store).
- [ ] Green. Commit: `HELM-203: forward attribution_token to installation register (close the pairing)`.

### Task 4: `incrementAuthenticated` (#2)
**Files:** `Attribution.swift` (+ shared `IdentityStore` access), tests `AttributionTests.swift`.
- [ ] Give `Attribution` read access to the stored `user_hash` (share `IdentityStore`, or add internal `Analytics.currentUserHash`). 
- [ ] Add `public func incrementAuthenticated(_ eventType: String, metadata: [String: Any]? = nil)` mirroring `increment()` but adding `"user_hash": <hash>` to the event body. Extend `PendingEvent` with a `userHash: String?` so auth events queued during a match resolve correctly; `_increment` includes it when present.
- [ ] Test: `incrementAuthenticated` posts to `/api/client/v1/attribution/event/` with `user_hash` in the body; plain `increment` does not.
- [ ] Green. Commit: `HELM-203: add Attribution.incrementAuthenticated (user-hash-bound events)`.

### Task 5: `Helm.logging` module (#3)
**Files:** create `Sources/Helm/Logging/Logging.swift`, `Logging/LoggingClient.swift`, `Logging/LogQueue.swift`, `Logging/HelmLogLevel.swift`; edit `Helm.swift` (accessor + optional ingest-token config), `Networking/HelmHTTPClient.swift` (optional `bearerOverride`); tests `Tests/HelmTests/LoggingTests.swift`, `LoggingClientTests.swift`.
- [ ] `HelmHTTPClient.post(path:body:bearerOverride: String? = nil)` — when set, use `Authorization: Bearer <override>` instead of the publishable key. Keep existing callers unchanged (default nil).
- [ ] `HelmLogLevel` enum → maps to OTLP `severityNumber`/`severityText` (e.g. debug=5/DEBUG, info=9/INFO, warn=13/WARN, error=17/ERROR).
- [ ] `LogEntry` (message, level, attributes, timestamp) with `payload()`; `LogQueue` cloned from `EventQueue` (NSLock, threshold/cap, drain/requeue).
- [ ] `LoggingClient` builds the OTLP envelope per spec (resource attrs `helm.environment`/`service.name`/optional `helm.commit.sha`; records with required `timeUnixNano` string, severity, `body.stringValue`, attributes) and POSTs `APIPath.logs` with `bearerOverride: <hlit_token>`.
- [ ] `Logging` class (singleton + DI like `Analytics`): `configure(ingestToken:environment:serviceName:)`, `start()`, `log(_:level:attributes:)`, timer + background flush, requeue-once on 429/5xx. **No-op when no ingest token configured.** `Helm.logging` accessor on the facade; thread the ingest token through `Helm.configure` (optional param) or a dedicated `Helm.logging.configure`.
- [ ] Tests: OTLP shape (required fields), `log()` enqueues + flush posts to `/api/v1/logs` with the `hlit_` bearer, no-op without a token, level→severity mapping, batch threshold flush. Add internal `await`-able flush + `queuedLogCount` test hooks.
- [ ] Green. Commit: `HELM-203: add Helm.logging module (OTLP -> /api/v1/logs, preview ingest token)`.

### Task 6: Release prep (#5)
**Files:** `CHANGELOG.md`.
- [ ] **Leave `Package.swift` platforms AS-IS.** Do NOT remove `.macOS(.v12)` — `swift test` runs on the macOS host and the package must build for macOS for the test suite to run. (CHANGELOG HELM-194's "dropped macOS" refers to product support, not test compilation; removing the line breaks `swift test`. Note this in the CHANGELOG instead.)
- [ ] `CHANGELOG.md`: convert the stale `[Unreleased]` block to `## [0.2.0]`, add `## [0.3.0] - 2026-06-27` documenting HELM-203 (handshake, device-id unify, incrementAuthenticated, logging module, path centralization).
- [ ] Green. Commit: `HELM-203: changelog for v0.3.0`.

---

## After the branch merges (controller, not a task)
1. Tag `v0.3.0` on `sdk-iOS` `main`.
2. In `TastySpread-iOS`: bump `Helm-iOS-SDK` `0.2.0 → 0.3.0`, build, ship an OTA, re-run the on-device test → confirm `get_recent_attributions(tastyspread)` links the install to `elysia`.
3. Update HELM-203 with the corrected findings (device_id join was dead; attribution_token handshake was the fix).

## Self-Review
- Spec coverage: #1a→T2, #1b→T3, #2→T4, #3→T5, #4→T1, #5→T6. The attribution_token handshake (the real fix) = T3. ✅
- Ordering: T1 (paths) is foundational; T2/T3 share Analytics edits but are split by concern (id source vs token); T5 is independent; T6 last. Each task builds + tests green.
