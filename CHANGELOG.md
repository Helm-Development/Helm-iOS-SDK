# Changelog

All notable changes to the Helm iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-08-08

Influencer promo-code attribution. Additive and backwards-compatible — no existing
API changed shape.

### Added
- HELM-220: `Helm.attribution.submitPromoCode(userId:code:)`,
  `Helm.attribution.fetchAttributionStatus(userId:)`, and
  `Helm.attribution.submitOriginalTransactionId(userId:originalTransactionId:)` for
  influencer promo-code attribution. The first two are the SDK's first public
  `async throws` methods; the third keeps the established fire-and-forget shape.
- HELM-220: Public `PromoCodeResult` (including `.queued`), `AttributionStatus`
  (with `fromCache`), and `HelmAttributionError` mapped from the backend error
  envelope (`invalid_code`, `code_inactive`, `already_linked`, plus pass-through
  for any other code). The SDK's internal networking error type no longer bounds
  the public surface.
- HELM-220: Offline submission queue — promo-code and transaction submissions that
  fail for transport reasons (no connectivity, timeout, 5xx) persist in
  UserDefaults and replay automatically on `Helm.configure(...)`, on app
  foreground, and before the next attribution call. 30-day retention, bounded at
  100 entries, deduplicated on `(kind, userId, value)`. Server-side validation
  failures are terminal and are never queued.
- HELM-220: Per-user attribution status cache so paywalls can still render the
  correct offering while offline, flagged `fromCache: true`.

### Changed
- HELM-220: `Helm.attribution.reset()` and `Helm.analytics.clearIdentity()` now
  also clear the pending submission queue and the attribution status cache, so a
  logout leaves no host-supplied `userId` on device.
- HELM-220: `PrivacyInfo.xcprivacy` now declares
  `NSPrivacyCollectedDataTypeUserID` (linked, App Functionality) alongside the
  existing Device ID entry, matching the `userId` the new methods send.

## [1.2.0] - 2026-07-18

Re-release of the `0.2.0` and `0.3.0` work under a version number that SwiftPM can
actually resolve from a `1.x` dependency rule. **Anyone on `1.1.2` or earlier must
upgrade** — see below.

### Fixed
- HELM-214: Restored a single monotonic tag series. The `0.2.0` and `0.3.0` releases were
  tagged `v0.2.0` / `v0.3.0`; SwiftPM strips the leading `v` and reads them as `0.2.0` /
  `0.3.0`, which sort *below* the previously published `1.1.2`. A `from: "1.1.2"`
  requirement resolves to `[1.1.2, 2.0.0)` and therefore always selected `1.1.2` — the
  fixes shipped in `0.2.0` and `0.3.0` were unreachable for every integrator. `1.2.0`
  carries that same code at a version the resolver can reach.
- HELM-183: Attribution requests now include the `/api/client/v1` path prefix. Prior to
  this fix `match()` and `increment(...)` posted to `/attribution/match/` and
  `/attribution/event/`, which the Helm backend answers with **HTTP 404**. On `1.1.2` and
  earlier, no install was ever attributed and no event was ever recorded. Pass scheme +
  host only to `Helm.configure(baseURL:)` — the SDK appends the prefix itself.

### Note for integrators upgrading from 1.1.2
This release contains every change listed under `[0.3.0]` and `[0.2.0]` below. Two of
them are behavioral changes worth reading before you upgrade:

- `Helm.configure(baseURL:)` must be given scheme + host only (e.g.
  `"https://helmcode.dev"`). If you previously worked around the 404 by passing a URL that
  already contained `/api/client/v1`, remove that prefix.
- macOS is no longer a supported platform (HELM-194); iOS 15+ only.

## [0.3.0] - 2026-06-27

### Added
- HELM-203: `attribution_token` handshake so attribution now links to the installation, providing definitive device → install matching.
- HELM-203: `Attribution.incrementAuthenticated(_:metadata:)` to track authenticated user events with optional metadata.
- HELM-203: `Helm.logging` module for structured logging via OTLP to `/api/v1/logs` (preview-only with ingest token).
- HELM-203: `APIPath` path centralization for maintainability across the SDK.

### Changed
- HELM-203: Attribution `device_id` unified to the Keychain installation `id` (removed separate device rotation).
- HELM-203: `Attribution.reset()` no longer rotates the device identity; it clears state only.

## [0.2.0] - 2026-06-10

### Added
- HELM-186: `PrivacyInfo.xcprivacy` manifest shipped inside the SDK bundle declaring `UserDefaults` Required Reason API (`CA92.1`), `Device ID` (linked, App Functionality + Analytics), and `Other Diagnostic Data` (not linked, App Functionality).
- HELM-187: Pending-event queue so `increment(...)` calls made while `match()` is in flight pick up the resolved `attribution_id` instead of posting with a null value. Queue is bounded; oldest entries drop on overflow.
- HELM-189: `Helm.attribution.reset()` to clear all SDK-stored attribution state (device_id, match, queued events, retry budget) for logout and App Review Guideline 5.1.1(v) account-deletion compliance.
- HELM-191: Optional `session: URLSession` parameter on `Helm.configure(...)` so integrators and tests can inject a custom `URLSession` / `URLSessionConfiguration`.
- HELM-195: `Helm.isConfigured` public API and a `configLogger.warning` when `configure(...)` is called more than once.

### Changed
- HELM-183: Network paths now include the `/api/client/v1` prefix on the SDK side; `configure(baseURL:)` takes scheme + host only.
- HELM-185: `Configuration.shared` and `AttributionStore` are now thread-safe; concurrent reads/writes no longer race.
- HELM-190: HTTP response bodies are now logged with `privacy: .private` instead of `.public` so they redact correctly in Console.
- HELM-192: Rewrote the README Privacy section to clarify that the SDK ships its own `PrivacyInfo.xcprivacy`, document the App Privacy nutrition-label entries hosts must declare, and add an Account Deletion subsection covering `Helm.attribution.reset()`.
- HELM-196: Replaced deprecated `Locale.languageCode` / `Locale.regionCode` with the iOS 16+ `Locale.Language` APIs (with iOS 15 fallback) so locale signals report canonical `en-US`-shaped values.

### Fixed
- HELM-184: `match()` now marks itself checked after exhausting the retry budget so a backend outage no longer causes infinite per-launch retries.
- HELM-188: `HelmHTTPClient` now throws when JSON body encoding fails instead of silently sending an empty body.
- HELM-194: Fixed `DeviceSignals` returning `0x0` screen size on macOS by dropping macOS as a supported platform; iOS is the only supported platform going forward.

### Removed
- HELM-193: Deleted dead-code `Sources/Helm/Attribution/IPResolver.swift` (no callers since HELM-100 removed the ipify dependency).
- HELM-194: Platforms — dropped macOS support; iOS is the only supported platform.

## [1.1.2] - 2026-04-16

### Fixed
- Parse the marketing OS version (e.g. `18.7`) from `operatingSystemVersionString` so attribution requests report the user-visible version rather than the Darwin kernel version.

## [1.1.1] - 2026-04-16

### Fixed
- Send locale in the canonical `en-US` format expected by the Helm backend.
- Report the marketing OS version (`18.7`) instead of the build version in the attribution match payload.

## [1.1.0] - 2026-04-16

### Added
- Multi-signal device collection during attribution match: screen dimensions, locale, timezone, OS version, and device model are now included in the match request to improve match accuracy without using IDFA.

## [1.0.2] - 2026-04-16

### Added
- Debug logging for the attribution match flow and the underlying HTTP client, surfaced via the `dev.helmcode.helm` `os.log` subsystem.

## [1.0.1] - 2026-04-15

### Changed
- Removed the runtime dependency on ipify. The Helm backend now reads the client IP from the request envelope, eliminating one external network call per match.

## [1.0.0] - 2026-04-14

### Added
- Initial release of the Helm iOS SDK.
- `Helm.configure(publishableKey:baseURL:)` to initialize the SDK.
- `Helm.attribution.match()` for install attribution matching.
- `Helm.attribution.increment(_:metadata:)` for fire-and-forget event tracking.
- Swift Package Manager support for iOS 15+ and macOS 12+.

[Unreleased]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.3.0...HEAD
[1.3.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.1.2...1.2.0
[0.3.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.1.2...v0.2.0
[1.1.2]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.1.1...1.1.2
[1.1.1]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.0.2...1.1.0
[1.0.2]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/Helm-Development/Helm-iOS-SDK/releases/tag/1.0.0
