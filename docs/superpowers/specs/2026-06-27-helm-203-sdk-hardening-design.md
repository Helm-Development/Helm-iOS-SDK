# HELM-203: iOS SDK Hardening

**Ticket:** HELM-203 (Major)  **Epic:** HELM-85 / relates TAS-690
**Date:** 2026-06-27  **Repo:** `Helm/sdk-iOS` (single SwiftPM package `Helm`, one target)
**Branch:** `HELM-203/sdk-hardening` (off `main`, HEAD `e96548f` = v0.2.0)

## Context & key correction

The on-device TAS-690 test proved the iOS install **registers** and **identify() binds** the user, but attribution **never links to the install** (raw `Attribution.installation` stays null). Investigation of the server (`Helm/Helm`) corrected the ticket's premise:

> **The server does NOT join attribution to installation by `device_id`.** `Attribution.device_id` is a **deprecated, unused column**. The link is made by the **`attribution_token` handshake**: `match()` returns `attribution_id`; the SDK must send it as **`attribution_token`** on the **installation-register** POST, and `register_installation → _close_attribution_pairing` sets the `Attribution.installation` FK.

Android (HELM-202) already does this via `Analytics.onAttributionMatched(attributionId)` → `attribution_token` in the registration body. **iOS does neither** — `match()` stores the id locally and nothing forwards it; `registrationBody` has no `attribution_token`. **This is the real bug**, and it's the correct realization of HELM-203 #1's stated intent ("so the join works"). We implement the literal device-id unification too (Android parity / cleanliness), but the **handshake is what fixes attribution.**

Server map summary (no server changes needed): attribution match/referrer/event live at `/api/client/v1/attribution/*` (auth `pk_`/`sas_`, no entitlement gate); analytics at `/api/v1/analytics/*` (requires `build` entitlement — TastySpread has it); client logs at `POST /api/v1/logs` (OTLP body, **`hlit_` ingest token**, **preview/non-prod only**, no entitlement gate).

---

## Part 1 — Device-id unification + attribution_token handshake

**1a. Unify the device id to the Keychain installation id.**
- Canonical id = `InstallationStore.installationId` (Keychain `helm_installation_id`, lowercase UUID, survives reinstall). `AttributionStore.deviceId` (UserDefaults `helm_device_id`, uppercase, lost on reinstall) is retired from the match path.
- `Attribution` gains an installation-id source. Add an internal accessor on `Analytics` — `var installationIdValue: String { installationStore.installationId }` — and inject it into `Attribution` (default `{ Analytics.shared.installationIdValue }`, overridable in tests). In `_match()`, `let deviceId = installationId()` instead of `store.deviceId`. (Independent `InstallationStore()` instances resolve to the same Keychain item, so a direct `InstallationStore().installationId` is an acceptable fallback if avoiding the `Analytics` coupling.)
- `device_id` is still sent in the match body (harmless; the column is deprecated but accepted), now carrying the canonical installation id so the two modules report one identity.
- **Reset semantics change:** `Attribution.reset()` no longer regenerates the device id (the identity now lives in the Keychain installation id, which analytics owns). `reset()` still clears attribution flags/`attribution_id`/retry budget/queue. Update `AttributionStore.clearAll()` to stop owning `helm_device_id`, and **rewrite `test_reset_regenerates_device_id`** to assert the new contract (device id is stable across reset; attribution state is cleared). Account-deletion full-wipe of the installation id is out of scope (analytics concern).

**1b. attribution_token handshake (the fix) — mirror Android.**
- Add `Analytics.onAttributionMatched(_ attributionId: String)`: store the token (lock-guarded `attributionToken` field, mirroring Android's `@Volatile`) and, if analytics has `start()`ed, call `register()` again so the next registration carries `attribution_token`.
- Add the field to `AnalyticsClient.registrationBody(installationId:userHash:attributionToken:)` — include `"attribution_token": token` only when non-empty (matches Android `AnalyticsClient.kt:58`).
- `Analytics.register()` reads the current token and passes it.
- On `Analytics.start()`, seed the token from `AttributionStore().attributionId` (covers the case where `match()` resolved before analytics started — Android does this at `Analytics.kt:92`).
- In `Attribution._match()` on a successful match (after `store.storeMatch`), call `Analytics.shared.onAttributionMatched(attributionId)`.
- Net effect: match → token forwarded → installation re-registers with `attribution_token` → server closes the pairing → `Attribution.installation` FK set → attribution links. **Verified against server `_close_attribution_pairing` (`installation.py:80-94`).**

## Part 2 — `incrementAuthenticated`

Implement the ticket's `Attribution.incrementAuthenticated(_ eventType:metadata:)`. It mirrors `increment()` but attaches the bound user identity: read the stored `user_hash` (via a shared `IdentityStore` accessor — `Analytics` owns it today) and include `"user_hash": hash` in the attribution `event` body posted to `/api/client/v1/attribution/event/`.

> Server note: the attribution-event endpoint does **not** read `user_hash` today (identity is associated at the installation level via `identify()`→register, which already works). We send the field for forward-compatibility and parity; document that server-side consumption is a follow-up. Same queue/`matchInFlight` gating as `increment()`; extend `PendingEvent` with an `authenticated`/`userHash` field so auth events queued during a match still resolve correctly.

## Part 3 — `Helm.logging` module (net-new)

New `Logging` class + `Helm.logging` accessor, mirroring the `Analytics` singleton/DI/batching shape.

- **Config:** logging needs an **ingest token** (`hlit_…`), distinct from the publishable key, and is **preview/non-prod only**. Add `Helm.logging.configure(ingestToken:)` (or extend `Helm.configure` with an optional `ingestToken: String? = nil`) + `Helm.logging.start()`. When no ingest token is set, logging is a silent no-op (prod).
- **API:** `Helm.logging.log(_ message: String, level: HelmLogLevel = .info, attributes: [String: String] = [:])`.
- **Batching:** `LogEntry` (with `payload()`) + `LogQueue` cloned from `EventQueue` (NSLock, threshold/cap, drain/requeue); flush on a `DispatchSourceTimer` + `didEnterBackground`, with requeue-once on 429/5xx — same pattern as `Analytics.flushNow()`.
- **Transport:** `LoggingClient` (mirrors `AnalyticsClient`) builds the **OTLP/HTTP JSON** envelope and POSTs to `/api/v1/logs` with `Authorization: Bearer <hlit_token>`. Envelope per server `parse_otlp_logs` (`logging/services.py`): `resourceLogs[].resource.attributes` with `helm.environment`, `service.name`, optional `helm.commit.sha`; `scopeLogs[].logRecords[]` each with **`timeUnixNano` (required, string)**, `severityNumber`, `severityText`, `body.stringValue`, `attributes[]`. Mirror the django-helm contract (`django_helm/logging.py` `_build_otlp_payload`).
- Because logging uses a different bearer token than the rest of the SDK, `HelmHTTPClient.post` needs an optional per-call auth override (`bearerOverride: String? = nil`) OR a dedicated logging client that builds its own request. Prefer the small `HelmHTTPClient` override so retry/timeout/JSON handling is shared.
- Test hooks: internal `await`-able flush + `queuedLogCount`, mirroring Analytics.

## Part 4 — Path-prefix reconcile (SDK-only)

The server can't unify prefixes (the `/api/client/v1/` vs `/api/v1/` split is a fixed contract shared with the backend django-helm SDK), so "reconcile" is SDK-side hygiene, **not** a server route change:
- Centralize every path into one `enum APIPath` (or a `Paths` namespace) so the four (soon five) hardcoded path strings live in one audited place: `attribution/match|event` under `/api/client/v1/`, `analytics/installations|events|api-hits` under `/api/v1/analytics/`, `logs` at `/api/v1/logs`.
- Fix the misleading `Helm.configure` doc comment that claims the SDK always appends `/api/client/v1/...` (only true for attribution).
- Do **not** change which server paths are called — they are correct.

## Part 5 — Release + package identity

- **CHANGELOG:** convert the stale `[Unreleased]` block to a `0.2.0` entry (it shipped as `v0.2.0`) and add a `0.3.0` section for HELM-203.
- **Package.swift:** the manifest still declares `.macOS(.v12)` though CHANGELOG HELM-194 dropped macOS — remove the macOS platform line to match (the package is iOS-only; the app pins it iOS-only). Keep package name `Helm` / product `Helm` and the `Helm-Development/Helm-iOS-SDK` URL (already the unified identity the app uses).
- **Version:** cut **`v0.3.0`** on `main` after merge (JitPack/SPM resolves the tag).
- **App adoption (follow-up, separate repo):** bump `Helm-iOS-SDK` `0.2.0 → 0.3.0` in `TastySpread-iOS` `Package.resolved`/project, then re-run the on-device attribution test — at which point `get_recent_attributions(tastyspread)` should show the install linked to `elysia`.

## Testing
XCTest + `@testable import Helm`. Per-test isolated `UserDefaults(suiteName:)`; `InstallationStore(useKeychain: false)` for unit tests; `MockURLProtocol`/`AttributionMockURLProtocol` injected via `Helm.configure(session:)` to capture request bodies (read `httpBodyStream`). New/changed tests:
- Handshake: after a successful `match()`, the next analytics registration body contains `attribution_token == attribution_id`; `onAttributionMatched` re-registers when started; `start()` seeds a pre-existing stored token.
- Device-id: `match()` sends the Keychain installation id as `device_id`; reset no longer rotates it (rewrite `test_reset_regenerates_device_id`).
- `incrementAuthenticated`: event body carries `user_hash`; queue gating works.
- Logging: OTLP envelope shape (required `timeUnixNano`, severity, body), batch flush, no-op without ingest token, correct `hlit_` bearer + `/api/v1/logs` target.
- Paths: every call site resolves through `APIPath`.

## Out of scope / risk
- No server changes (verified). Logging only functions in preview/non-prod (token scope).
- Identity continuity: existing installs keep their Keychain installation id; the abandoned UserDefaults `helm_device_id` is irrelevant to the (token-based) join, so there is no attribution-data migration.
- Behavior change: `reset()` device-id semantics — documented + test rewritten.
