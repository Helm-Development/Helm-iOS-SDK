# Changelog

All notable changes to the Helm iOS SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.8.0] - 2026-10-27

Apple Ads attribution. Additive and backwards-compatible: `appleAdsAttribution` is
a defaulted parameter, so every existing `Helm.configure(...)` call site keeps
compiling unchanged. The check is on by default.

### Added
- HELM-336: `appleAdsAttribution` parameter on
  `Helm.configure(publishableKey:baseURL:debug:environment:appleAdsAttribution:session:)`,
  default `true`. When on, the SDK checks once per installation, in the background
  after `configure`, whether the install came from an Apple Ads campaign. Apps need
  no other code. It needs no App Tracking Transparency prompt: Apple states that
  AdServices does not engage in tracking as defined under ATT.
- HELM-336: the check gets a new token from `AAAttribution.attributionToken()`
  (AdServices, iOS 14.3+; behind `#if canImport(AdServices)`), off the main thread,
  and sends `POST /api/client/v1/attribution/apple-ads/` (HELM-335) with `token`,
  `device_id` and `debug`.
- HELM-336: `matched: true` finishes the check; when `primary` is `true` (or
  missing) the attribution ID replaces the stored one and is passed to analytics.
  `not_apple_ads`, `invalid_token` and any other final reason finish the check and
  store nothing. On `pending`, a failed request or an unusable response, the SDK
  waits 5 seconds (`Task.sleep`, never on the main thread) and sends again with a
  new token, up to 3 sends in one launch, following Apple's advice to retry a
  not-ready record every 5 seconds up to 3 times. Helm's server asks Apple once per
  send and does not wait. The sends stop if the app goes to the background.
- HELM-336: the up-to-3 sends of one launch count as one attempt. Without a final
  answer, the SDK makes another attempt on the next launch or return to the
  foreground, up to 4 attempts in total within 24 hours of the first try. If
  AdServices throws, the SDK stops for this launch and tries again on the next one.
- HELM-336: new `UserDefaults` keys `helm_apple_ads_finished`,
  `helm_apple_ads_attempts` and `helm_apple_ads_first_attempt`, cleared by
  `Helm.attribution.reset()` (so the check runs again on the next launch).

### Changed
- HELM-336: `match()` also stops once an Apple Ads attribution is stored, the same
  way it does for a clipboard attribution.

## [1.7.0] - 2026-10-27

Clipboard handoff for iOS install attribution. Additive and backwards-compatible:
no existing API changed. The new views need iOS 16; the package still supports
iOS 15, where `hasClipboardHandoff()` returns `false`.

### Added
- HELM-325: `Helm.attribution.hasClipboardHandoff() async -> Bool` says whether the
  app should show the Paste button. It asks iOS only whether the clipboard
  probably holds a web URL (`hasURLs` and `detectPatterns` with
  `probableWebURL`), which shows no prompt and no "pasted from" notice. It
  returns `false` on iOS 15 and macOS, once a code has been redeemed for this
  installation, while a code is queued, and while the clipboard still holds
  contents the user already pasted without a match.
- HELM-325: after the first `hasClipboardHandoff()` call, the SDK checks again
  when the app returns to the foreground and on `UIPasteboard.changedNotification`,
  and posts `Notification.Name.helmClipboardHandoffAvailabilityDidChange`
  (`userInfo["available"]`, a `Bool`) when the answer changes.
- HELM-325: `HelmPasteButton` (SwiftUI, wraps
  `PasteButton(supportedContentTypes: [.url, .plainText])`) and
  `Helm.attribution.makePasteControl(configuration:onResult:)` (UIKit, returns a
  `UIPasteControl` whose target accepts `UTType.url` and `UTType.plainText`).
  Both report a new `ClipboardHandoffResult` (`.matched`, `.notMatched(reason:)`
  or `.failed`) on the main actor.
- HELM-325: both Paste buttons accept plain text as well as URLs, because a web
  page may copy the handoff URL as either type. They share one loader that
  prefers an item typed as a URL and otherwise trims the text and reads it as a
  URL; `hasClipboardHandoff()` still decides when the button is shown.
- HELM-325: a pasted URL is sent only if it is `https` and its path is exactly
  `/h/<code>/` with a code of at least 12 characters from `A-Z a-z 0-9 _ -`.
  Anything else is ignored and reported as `.notMatched(reason: "not_handoff_url")`.
- HELM-325: the code is redeemed with `POST /api/client/v1/attribution/clipboard/`
  (HELM-323), body `code`, `device_id` and `debug`. On a match the code is marked
  redeemed; when the response's `primary` is `true` (or missing), the attribution
  ID replaces any earlier `match()` result and is passed to analytics, and the
  clipboard is cleared if its change count has not moved since the paste. An
  unmatched response stores nothing new. Events recorded during the request wait
  for its answer.
- HELM-325: a redeem that fails on the network (no connection, timeout, 5xx) is
  kept in the existing offline queue as a new `clipboard_handoff` entry and
  replayed like promo codes and transactions. A replay never clears the clipboard.
- HELM-325: new `UserDefaults` keys `helm_attribution_method`,
  `helm_clipboard_redeemed` and `helm_clipboard_dismissed_change_count`, cleared by
  `Helm.attribution.reset()`.

### Changed
- HELM-325: once a clipboard attribution is stored, `match()` does nothing, and a
  `match()` response that arrives after a clipboard attribution is ignored. The
  clipboard result wins whichever finishes last.

## [1.6.0] - 2026-10-25

User feedback. Additive and backwards-compatible: no existing API changed.

### Added
- HELM-310: `Helm.submitFeedback(type:message:imageData:imageMimeType:userId:email:)`
  sends a bug report, feature request or general feedback from the app's user to
  Helm's `POST /api/client/v1/feedback/` endpoint (HELM-307) as
  `multipart/form-data`, with optional JPEG, PNG, HEIC or WebP image data, user ID
  and email. It returns a `FeedbackResult` with the ID, status and creation date
  Helm gave the feedback.
- HELM-310: on iOS, `Helm.submitFeedback(type:message:image:userId:email:)` takes a
  `UIImage`, encodes it as JPEG and, if the result is over 10 MB, lowers the JPEG
  quality and then scales the image down until it fits.
- HELM-310: the SDK adds `platform` (`ios`), the app version, the OS version, the
  device model (hardware identifier such as `iPhone16,2`) and the configured `debug`
  flag to every feedback request. Feedback from a `debug: true` build is stored as
  test data.
- HELM-310: the message is trimmed and checked (1 to 5000 characters) and image
  data is checked (at most 10 MB) before anything is sent.
- HELM-310: new public types `FeedbackType`, `FeedbackResult` and
  `HelmFeedbackError`. Each error code the endpoint returns (`missing_field`,
  `invalid_field`, `invalid_image`, `image_too_large`, `auth_required`,
  `invalid_token`) has its own case; no connection, a timeout or a 5xx is
  `.network`. There is no offline queue: when the method throws, the feedback was
  not stored.

## [1.5.0] - 2026-09-07

The `debug` flag now reaches analytics as well as attribution, and a new
`environment` label rides along with it. Additive and backwards-compatible —
`environment` is a defaulted parameter, so every existing `Helm.configure(...)`
call site keeps compiling unchanged, and a build that sets neither value
registers as a live production user.

### Added
- HELM-237: installation registration now sends the configured `debug` boolean,
  the same wire field the attribution endpoints already take. Helm leaves activity
  from a debug build out of its daily, weekly, and monthly active-user counts, so
  a developer running the app all day no longer shows up as a real user. The flag
  is sent on every registration, including when `false`, so a device that moves
  from a debug build to a shipped one counts as live again.
- HELM-241: `environment` parameter on
  `Helm.configure(publishableKey:baseURL:debug:environment:session:)`. It is a
  free-form label for the deployment environment the build talks to, e.g.
  `"production"`, `"staging"`, `"development"`, and it defaults to
  `"production"`. Helm records it on analytics activity so you can filter by
  environment. It is independent of `debug`, which decides whether the activity
  counts as real usage at all — a staging build can still be real usage, and a
  debug build can still point at production.
- HELM-241: installation registration sends `environment` alongside `debug`.
- HELM-241: every object in the analytics `events[]` array now carries its own
  `debug` and `environment`, captured when the event is created rather than when
  the batch is flushed. An event queued under one configuration keeps its own
  values even if the app is reconfigured before the flush — the same rule
  TAS-801 already applies to queued attribution submissions.
- HELM-241: the two older attribution endpoints, `match` and `event`, now send
  `debug` too. The three influencer endpoints already did, so all five
  attribution requests now carry the marker. `environment` is analytics-only and
  is not sent on any attribution request.

## [1.4.0] - 2026-08-10

Sandbox test data for influencer attribution. Additive and backwards-compatible —
`debug` is a defaulted parameter, so existing `Helm.configure(...)` call sites keep
compiling unchanged and keep sending live submissions.

### Added
- TAS-801: `debug` parameter on `Helm.configure(publishableKey:baseURL:debug:session:)`.
  When `true`, every attribution submission this build makes is registered in Helm as
  **sandbox test data** and is permanently excluded from payouts and billing. Defaults
  to `false`, so a production build is safe without any change at the call site — set
  it from your build configuration (e.g. `true` for develop/QA, `false` for
  staging/production).
- TAS-801: All three attribution request bodies (`promo-code`, `status`,
  `transaction`) now always include a `debug` boolean read from the configuration.
- TAS-801: Queued offline submissions **persist the marker they were created with**.
  A submission enqueued by a debug build replays as sandbox data even if the app has
  since been reconfigured as live, and vice versa. The queue's dedupe key is now
  `(kind, userId, value, debug)` — the same value in two environments is two distinct
  submissions.
- TAS-801: The attribution status cache records the environment each entry was
  confirmed under. An offline status read falls back to a cached entry only when it
  came from the *same* environment; a cross-environment entry is treated as a miss
  (`.network`), so a live paywall never renders an offering confirmed against sandbox
  data.

### Changed
- TAS-801: `PendingSubmission` and `CachedStatus` decode `debug` with
  `decodeIfPresent(_:forKey:) ?? false`, so a 1.3.0 queue or status cache already on
  disk decodes as **live** on upgrade rather than being discarded.

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

[Unreleased]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.8.0...HEAD
[1.8.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.7.0...1.8.0
[1.7.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.6.0...1.7.0
[1.6.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.5.0...1.6.0
[1.5.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.4.0...1.5.0
[1.4.0]: https://github.com/Helm-Development/Helm-iOS-SDK/compare/1.3.0...1.4.0
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
