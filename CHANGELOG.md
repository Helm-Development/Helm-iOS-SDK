# Changelog

All notable changes to the Helm iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.1.2...HEAD
[1.1.2]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.1.1...1.1.2
[1.1.1]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.0.2...1.1.0
[1.0.2]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/Helm-Development/Helm-iOS-SDK/releases/tag/1.0.0
