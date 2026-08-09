# HELM-220: iOS SDK Attribution Methods + Offline Queue

**Ticket:** HELM-220 (task, `ios`)  **Epic:** HELM-218 (authoritative design)
**Date:** 2026-08-08  **Repo:** `Helm/sdk-iOS` (SwiftPM package `Helm`, one target)
**Branch:** `task/HELM-220-attribution-methods` (off `main`, HEAD `609c707` = 1.2.0)
**Ships as:** 1.3.0 — additive, backwards-compatible; bare-numeric tag `1.3.0`

## Context

HELM-218 introduces influencer promo codes: a creator hands out a code, the user
enters it in the app, and the resulting subscription revenue attributes back to
that creator. The client's job is three calls — submit the code, read the
resulting status so the paywall can present the influencer's offering, and report
the StoreKit original transaction id once a purchase completes.

Two constraints shape the design more than anything else:

1. **The join key is the host app's user id.** Helm matches its attribution
   records to RevenueCat transactions by string equality on `userId`. The SDK
   therefore treats `userId` as fully opaque: no validation, no normalization, no
   hashing, no truncation. Enforcing the RevenueCat alignment is documented as the
   integrating app's responsibility (README callout + doc comments on all three
   methods) because the SDK has no way to detect drift.

2. **A promo code entered offline must not be lost.** Code entry is a one-shot
   moment in the user's flow — a spinner that fails is a permanently unattributed
   install. So transport failures are persisted and replayed, while backend
   verdicts are surfaced immediately and never retried.

## Client API contract (fixed by the backend task)

| Path | Method | Request fields |
|---|---|---|
| `/api/client/v1/attribution/promo-code/` | POST | `user_id`, `code`, `platform`, `device_id` |
| `/api/client/v1/attribution/status/` | POST | `user_id`, `platform`, `device_id` |
| `/api/client/v1/attribution/transaction/` | POST | `user_id`, `original_transaction_id`, `platform`, `device_id` |

Failures come back as `{"error": {"message", "code"}}`; the terminal codes are
`invalid_code`, `code_inactive`, `already_linked`.

All three are POST because both SDK HTTP clients are POST-only, so
**`HelmHTTPClient` needed no changes** — its publishable-key bearer, 10 s timeout,
JSON handling, and `HelmError` taxonomy are exactly what these endpoints need. The
paths are centralized in `APIPath` and asserted as literal strings in a unit test:
HELM-183 established that a single character of path drift is a silent 404 for
every integrator, with no signal anywhere in the SDK.

`platform` and `device_id` are auto-included on all three bodies. `device_id`
reuses the existing injected `installationId: () -> String` seam (the Keychain
installation id unified in HELM-203), so no new plumbing was required. The epic
marks `device_id` optional on promo-code and omits it from status; sending it
everywhere is deliberate — the backend tolerates extra fields, and it lets the
server reconcile a submission with the install that made it.

## Public API

```swift
@discardableResult
public func submitPromoCode(userId: String, code: String) async throws -> PromoCodeResult
public func fetchAttributionStatus(userId: String) async throws -> AttributionStatus
public func submitOriginalTransactionId(userId: String, originalTransactionId: String)
```

The first two are the SDK's first public `async throws` methods. The third keeps
the fire-and-forget shape of `match()` / `increment()` — purchase UX must never
block on or be broken by Helm — with an internal `_submitOriginalTransactionId`
async variant so tests can await one cycle, mirroring `match()` / `_match()`.

Public types live in `AttributionModels.swift`: `PromoCodeResult`
(`.linked(influencerCode:offeringId:)` / `.queued`), `AttributionStatus`
(`isLinked`, `influencerCode`, `offeringId`, `fromCache`), and
`HelmAttributionError`.

**`HelmError` stays internal.** It carries an `Error` payload and raw HTTP status
codes, neither of which belongs in an SDK's public contract, and making it public
would freeze the networking layer's shape. `HelmAttributionError` is the sole
public error surface; a test catches every failure path as a generic `Error` and
asserts `error is HelmAttributionError` to keep it that way.

## Transport vs terminal — the classification that drives everything

`AttributionErrorMapper.classify(_:)` reduces `HelmError` to two outcomes.
Queueing, cache fallback, and replay-halting all key off this one function.

| Internal `HelmError` | Classification | Consequence |
|---|---|---|
| `.networkError(_)` (offline, timeout, DNS) | **transport** | queue / serve cache |
| `.serverError(status, _)`, `status >= 500` | **transport** | queue / serve cache |
| `.serverError(status, body)`, `status < 500` | **terminal** | parse envelope → `.invalidCode` / `.codeInactive` / `.alreadyLinked` / `.server(code:message:)`; unparseable body → `.server(code: "http_<status>", message: body)` |
| `.notConfigured` | **terminal** → `.notConfigured` | never queued — misconfiguration is not transient |
| `.invalidResponse` | **terminal** → `.invalidResponse` | |
| `.encodingFailed` / `.invalidJSONBody` | **terminal** → `.server(code: "encoding_failed", …)` | |
| non-`HelmError` (defensive, unreachable) | **terminal** → `.server(code: "unknown", …)` | |

4xx statuses — **including 408 and 429** — are terminal, matching HELM-218's
definition of transient ("no connectivity, timeout, 5xx") exactly. If the backend
ever rate-limits these endpoints, 429 moves to `.transport` in this one function
and nowhere else.

## Offline queue

`PendingSubmissionStore` follows the `AttributionStore` pattern: `internal final
class … @unchecked Sendable`, `init(defaults: UserDefaults = .standard, now:
@escaping () -> Date = Date.init)`, one `NSLock` around every read-modify-write.
One UserDefaults key, `helm_attribution_pending_submissions`, holds a
JSON-encoded array of `PendingSubmission { id, kind, userId, value, enqueuedAt }`
— a `Codable` `Sendable` value type, same discipline as `PendingEvent`.

- **Retention:** 30 days (HELM-218 DECIDED). Pruning runs on every `all()` /
  `enqueue()`, so an expired entry never reaches the network; drops are logged.
- **Cap:** 100 entries, oldest dropped on overflow.
- **Dedupe:** identical `(kind, userId, value)` is skipped. Replay is idempotent
  server-side, so duplicates would be harmless but wasteful.
- **Corruption:** an undecodable payload is discarded rather than wedging every
  future enqueue on the same decode failure.

**Replay triggers** — all three from HELM-218:

1. `Helm.configure(...)`, after `Configuration.shared` is set. Integrators call
   `configure` on every launch, making it the natural drain point.
2. `UIApplication.willEnterForegroundNotification` — the moment connectivity is
   most likely to have returned. Registered **only in `Attribution`'s private
   singleton `init()`**, not the internal test init, so test instances stay
   observer-free and replay is exercised through the async method directly.
3. Before any new attribution call, after the configured-guard — so a queued code
   lands before the status read that follows it.

**Replay loop** (`_replayPendingSubmissions`): FIFO over the pruned queue;
success dequeues (and, for a promo code, writes the linked status to the cache);
a terminal verdict dequeues and logs; a transport failure **breaks the loop**,
leaving that entry and every entry behind it — the network is still down, so
hammering the rest only burns battery.

A `replayInFlight` flag (its own `NSLock`, separate from the event `queueLock`)
makes concurrent replays a no-op rather than a race. A skipped replay means a
queued entry may post *after* a concurrent fresh call's request; harmless,
because HELM-218 guarantees all three endpoints are idempotent. Every lock
section is synchronous — the Swift 6 rule already documented in `Attribution`.

## Status cache

`AttributionStatusCache` stores `helm_attribution_status_cache` as a JSON map
**keyed by `userId`** → `CachedStatus { isLinked, influencerCode, offeringId,
fetchedAt }`. Keying per user is the point: a shared or re-signed-in device must
never serve user A's influencer offering to user B. Capped at 5 users, evicting
oldest `fetchedAt` first.

No TTL — HELM-218 specifies "last successful status", and `fromCache: true` is the
staleness signal the host app reacts to.

- **Written by:** a successful `fetchAttributionStatus`, a successful
  `submitPromoCode`, and a successful promo-code replay.
- **Read by:** `fetchAttributionStatus` on a **transport** failure only. With a
  cache hit it returns `fromCache: true`; with a miss it throws `.network`.
  Terminal 4xx errors are thrown, never cache-masked — a real server verdict must
  surface.
- **Wiped by:** `Attribution.reset()` and `Analytics.clearIdentity()`. Both the
  queue and the cache hold the host-supplied `userId`, so a logout that left them
  behind would let the next user replay the previous user's code. `Analytics`
  gained two all-defaulted injected stores for this, matching how it already
  takes an `AttributionStore`; independent instances converge on the same
  `.standard` keys.

## Rejected options

- **Queue `notConfigured` submissions** so a call made before `configure` survives.
  Rejected: HELM-218 restricts queueing to transport failures, and silently
  swallowing a misconfiguration hides an integrator bug that should be loud. The
  fire-and-forget transaction path logs and drops; the two async methods throw.
- **Surface deferred replay failures via a delegate or notification.** Rejected as
  out of scope: HELM-218 makes deferred-failure UX the host app's concern, and the
  app can already re-read `fetchAttributionStatus` when the paywall next appears.
- **A TTL on the status cache.** Rejected: it would trade a correct-but-stale
  offering for a wrong default one, exactly when the network is down. `fromCache`
  gives the app the information to decide instead.

## Tests

`swift test` — 141 tests, 0 failures (60 of them new).

- `PendingSubmissionStoreTests` (13): UserDefaults round-trip across instances,
  FIFO order, single-entry removal, dedupe key, retention boundary at ±1 s around
  30 days, overflow dropping the oldest, `clearAll` removing the key, corruption
  tolerance.
- `AttributionStatusCacheTests` (9): per-user isolation, nil-optional round-trip,
  overwrite in place, oldest-first eviction at the cap, `clearAll`, corruption
  tolerance.
- `AttributionSubmissionTests` (38): exact path literals; body composition for all
  three endpoints including verbatim `userId` pass-through; every branch of the
  transport/terminal table; queue-then-replay for both kinds; replay ordering
  before a status read; terminal and transport replay outcomes; retention
  short-circuit before any network call; `fromCache` fallback, per-user cache
  isolation, and 4xx-over-cache precedence; the fire-and-forget overload;
  `notConfigured` on all three entry points; no `HelmError` leakage; and
  `reset()` / `clearIdentity()` wipes.

A per-file `SubmissionMockURLProtocol` extends the existing mock pattern with a
`.failure(URLError)` outcome so real transport failures — not just 5xx statuses —
are exercised. Note that `URL.path` strips trailing slashes, so path assertions
compare against the absolute string; getting this wrong would have made the
trailing-slash parity tests vacuous.

## Risks

1. **Path parity is a hard contract.** Do not ship the SDK before the backend
   endpoints exist on the target environment, and confirm the merged router spells
   `promo-code/` (not `promo_code/`).
2. **Response key drift.** `linked`, `influencer_code`, `offering_id` must be
   confirmed against the merged backend serializers. Parsing is defensive
   (`.invalidResponse` when `linked` is missing), so drift fails loudly rather
   than silently reporting "unlinked".
3. **`userId` now persists on device** inside queued submissions and as the status
   cache key. Not a Required Reason change (`CA92.1` already covers Helm's
   UserDefaults use), but the nutrition-label guidance needed the `Identifiers →
   User ID` row, and the manifest gained `NSPrivacyCollectedDataTypeUserID` for
   consistency with the existing Device ID entry.
4. **`@discardableResult` on `submitPromoCode`** matches the ticket signature, but
   discarding the result loses the `.queued` signal. Documented in the doc comment
   and the README.
