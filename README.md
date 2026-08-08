# Helm iOS SDK

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015-blue.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

The official Swift SDK for [Helm](https://helmcode.dev). Attribute installs, track conversion events, and tie user activity back to the campaign that drove it — with a single `configure` call and a one-line `match()`.

## Features

- **Attribution matching** — match each install to the campaign, channel, or tracking link that drove it, using device-side signals (no IDFA required).
- **Event tracking** — record conversion events (`signup`, `purchase`, etc.) with optional metadata, automatically linked to the matched attribution source.
- **Influencer promo codes** — link a user to an influencer's code, read back the paywall offering to present, and report the purchase's original transaction id for revenue attribution.
- **Offline-tolerant** — promo-code and transaction submissions that can't reach the server are queued on device and replayed automatically for up to 30 days; attribution status is cached per user so paywalls render correctly offline.
- **Fire-and-forget API** — event and transaction calls run in the background; calling code never blocks.
- **Privacy-first** — no IDFA, no ATT prompt, no third-party trackers. Device signals are collected only on first match and never persisted off-device by the SDK.
- **Zero dependencies** — pure Foundation + `os.log`. No transitive packages.

## Requirements

| Platform | Minimum Version |
|----------|-----------------|
| iOS      | 15.0            |
| Swift    | 5.9             |
| Xcode    | 15.0            |

## Installation

### Swift Package Manager (Xcode)

1. In Xcode, open your project and choose **File → Add Package Dependencies…**
2. Paste the repository URL:
   ```
   https://github.com/Helm-Development/Helm-iOS-SDK.git
   ```
3. Set the dependency rule to **Up to Next Major Version** starting from `1.3.0`.
4. Add the `Helm` library product to your app target.

### Swift Package Manager (Package.swift)

Add Helm to the `dependencies` array of your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Helm-Development/Helm-iOS-SDK.git", from: "1.3.0")
]
```

Then add `Helm` to the dependencies of any target that needs it:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Helm", package: "Helm-iOS-SDK")
    ]
)
```

## Quick Start

### 1. Configure the SDK

Call `Helm.configure(...)` once at app launch — typically in your `App` initializer or `application(_:didFinishLaunchingWithOptions:)`.

#### SwiftUI

```swift
import SwiftUI
import Helm

@main
struct MyApp: App {
    init() {
        Helm.configure(
            publishableKey: "pk_live_your_publishable_key",
            baseURL: "https://helmcode.dev"
        )
        // Optional: inject a custom URLSession for testing or proxying.
        // Helm.configure(
        //     publishableKey: "pk_live_your_publishable_key",
        //     baseURL: "https://helmcode.dev",
        //     session: URLSession(configuration: customConfig)
        // )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

#### UIKit

```swift
import UIKit
import Helm

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Helm.configure(
            publishableKey: "pk_live_your_publishable_key",
            baseURL: "https://helmcode.dev"
        )
        return true
    }
}
```

### 2. Run attribution match on launch

Call `match()` after `configure(...)`. It is safe to call on every launch — subsequent calls are no-ops once a match check has completed.

```swift
Helm.attribution.match()
```

### 3. Record events

Increment a named event whenever the user takes an action you want to measure. Events are automatically tied to the matched attribution source.

```swift
// Simple event
Helm.attribution.increment("signup")

// Event with metadata
Helm.attribution.increment("purchase", metadata: [
    "sku": "pro_annual",
    "amount_usd": 49.99
])
```

All event calls are fire-and-forget — they return immediately and never throw.

## Influencer attribution

Helm can link a signed-in user to an influencer's promo code, tell you which paywall offering to present to them, and attribute the resulting purchase back to that influencer.

> ### ⚠️ `userId` must match your RevenueCat app user ID
>
> `userId` is **opaque to Helm and passed through verbatim** — Helm never validates, normalizes, hashes, or truncates it. **It MUST be exactly the same string your app sets as the RevenueCat app user ID** (the value you pass to `Purchases.logIn(_:)` or `Purchases.configure(appUserID:)`).
>
> Helm's revenue matching joins influencer attribution to RevenueCat transactions on that equality. If the two strings drift — different casing, an email in one place and a UUID in the other, a prefix added on one side — the promo code links but no revenue ever attributes to the influencer, and nothing surfaces an error. Keeping them aligned is the integrating app's responsibility.

### 1. Submit a promo code

```swift
do {
    let result = try await Helm.attribution.submitPromoCode(
        userId: currentUser.revenueCatAppUserID,
        code: enteredCode
    )
    switch result {
    case .linked(let influencerCode, let offeringId):
        // Linked server-side. Present `offeringId` on the paywall if non-nil.
        show(offering: offeringId)
    case .queued:
        // No connectivity — Helm persisted the submission and will replay it.
        showMessage("We'll apply your code as soon as you're back online.")
    }
} catch HelmAttributionError.invalidCode {
    showMessage("That code doesn't exist.")
} catch HelmAttributionError.codeInactive {
    showMessage("That code is no longer active.")
} catch HelmAttributionError.alreadyLinked {
    showMessage("A different code is already applied to your account.")
} catch {
    showMessage((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
}
```

`.queued` is **not** a failure — it means the submission survived the network outage and will be retried automatically (see [Offline behavior](#offline-behavior)). Because `submitPromoCode` is `@discardableResult`, ignoring the return value silently discards that distinction; inspect it whenever you show UI.

### 2. Pick the paywall offering

```swift
let status = try await Helm.attribution.fetchAttributionStatus(
    userId: currentUser.revenueCatAppUserID
)

if status.isLinked, let offeringId = status.offeringId {
    show(offering: offeringId)
} else {
    show(offering: defaultOfferingId)
}

if status.fromCache {
    // Served from the on-device cache because the network was unreachable.
    // The values are the last ones Helm's server confirmed for this user.
}
```

### 3. Report the purchase

Call this once the purchase completes, with the StoreKit original transaction id (`Transaction.originalID` in StoreKit 2, or `original_transaction_id` from the receipt):

```swift
Helm.attribution.submitOriginalTransactionId(
    userId: currentUser.revenueCatAppUserID,
    originalTransactionId: String(transaction.originalID)
)
```

This returns immediately and never throws — purchase UX never blocks on Helm.

### Offline behavior

- **Transport failures are queued.** No connectivity, a timeout, or a 5xx means the submission is persisted to Helm's own `UserDefaults` keys and replayed automatically on the next `Helm.configure(...)` call, when the app returns to the foreground, and before the next attribution call. Entries are retained for **30 days**, deduplicated, and bounded at 100.
- **Validation verdicts are terminal.** `invalid_code`, `code_inactive`, `already_linked`, and any other 4xx are answers, not outages — they are surfaced to you (or logged and dropped, for the fire-and-forget transaction method) and are **never** queued or retried.
- **Status reads fall back to the cache.** `fetchAttributionStatus` returns the last server-confirmed status for that `userId` with `fromCache: true` when the network is unreachable, and only throws `.network` when nothing is cached for that user. Cached statuses are stored per `userId`, so a shared device never serves one account's offering to another. A real 4xx is still thrown rather than masked by the cache.
- **A queued code that later turns out to be invalid fails silently.** By the time a replay runs, the call that submitted it has long since returned. Helm logs and drops the entry; if your product needs to tell the user, re-read `fetchAttributionStatus` when the paywall next appears.

## API Reference

### `Helm`

The top-level entry point.

```swift
public enum Helm {
    /// Configure the SDK. Call once at launch.
    /// - Parameters:
    ///   - publishableKey: Your project's publishable API key.
    ///   - baseURL: The Helm API host (e.g. "https://helmcode.dev").
    ///     Pass only scheme + host — the SDK appends the API path prefix.
    ///   - session: The `URLSession` used for all network requests.
    ///     Defaults to `.shared`. Inject a custom session for testing
    ///     or to provide a custom `URLSessionConfiguration`.
    public static func configure(
        publishableKey: String,
        baseURL: String,
        session: URLSession = .shared
    )

    /// `true` after `configure(...)` has been called.
    public static var isConfigured: Bool { get }

    /// Access attribution tracking features.
    public static var attribution: Attribution { get }
}
```

### `Attribution`

```swift
public final class Attribution {
    /// Match the current device to an attribution source.
    /// Idempotent — safe to call on every launch.
    public func match()

    /// Record an attribution event.
    /// - Parameters:
    ///   - eventType: The event name (e.g. "signup", "purchase").
    ///   - metadata: Optional key-value metadata attached to the event.
    public func increment(_ eventType: String, metadata: [String: Any]? = nil)

    /// Record an attribution event tied to the authenticated user identity.
    public func incrementAuthenticated(_ eventType: String, metadata: [String: Any]? = nil)

    /// Submit an influencer promo code for the given user.
    /// - Parameters:
    ///   - userId: Opaque, passed through verbatim. MUST equal the string
    ///     your app sets as the RevenueCat app user ID.
    ///   - code: The code the user entered. The server normalizes case.
    /// - Returns: `.linked(influencerCode:offeringId:)`, or `.queued` when the
    ///   network was unreachable and the submission was persisted for replay.
    /// - Throws: `HelmAttributionError`.
    @discardableResult
    public func submitPromoCode(userId: String, code: String) async throws -> PromoCodeResult

    /// Fetch the user's influencer-attribution status. Falls back to the
    /// on-device cache (`fromCache: true`) on a transport failure.
    /// - Throws: `HelmAttributionError`.
    public func fetchAttributionStatus(userId: String) async throws -> AttributionStatus

    /// Report a purchase's StoreKit original transaction id so Helm can
    /// attribute revenue to the influencer. Fire-and-forget: returns
    /// immediately, never throws, queues on transport failure.
    public func submitOriginalTransactionId(userId: String, originalTransactionId: String)

    /// Reset all SDK attribution state so the next `match()` runs as if
    /// this were a fresh install: clears the stored attribution match,
    /// drops any queued events, resets the retry budget, and empties the
    /// pending submission queue and attribution status cache. Call this on
    /// logout or account deletion.
    public func reset()
}
```

### `PromoCodeResult`

```swift
public enum PromoCodeResult: Equatable, Sendable {
    /// Linked server-side. `offeringId` is the RevenueCat offering to serve.
    case linked(influencerCode: String, offeringId: String?)
    /// Transport failure — persisted on device and replayed automatically for
    /// up to 30 days. Not a failure; tell the user it will apply when online.
    case queued
}
```

### `AttributionStatus`

```swift
public struct AttributionStatus: Equatable, Sendable {
    public let isLinked: Bool
    public let influencerCode: String?
    public let offeringId: String?
    /// True when served from the on-device cache because the network was
    /// unreachable; false when fresh from the server.
    public let fromCache: Bool
}
```

### `HelmAttributionError`

The only error type thrown by the attribution methods — the SDK's internal networking error never crosses the public boundary.

```swift
public enum HelmAttributionError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured                              // Helm.configure(...) not called
    case invalidCode                                // backend `invalid_code`
    case codeInactive                               // backend `code_inactive`
    case alreadyLinked                              // backend `already_linked`
    case network                                    // offline/timeout/5xx, nothing queued or cached
    case server(code: String, message: String)      // any other backend error envelope
    case invalidResponse                            // 2xx with an unusable body
}
```

## Privacy

The Helm SDK is designed to be privacy-respecting by default:

- **No IDFA / ATT prompt** — Helm does not access the IDFA and does not require an `NSUserTrackingUsageDescription` entry in your `Info.plist`. (This applies only to Helm's own data collection — host apps that integrate other ATT-triggering SDKs are unaffected by anything Helm does.)
- **No third-party trackers** — all requests go directly to your configured Helm backend. Helm's backend treats each customer tenant as a first-party silo; cross-tenant correlation would change this analysis.
- **No persistent device fingerprint** — device signals (screen size, locale, timezone, OS version) are collected only during the first attribution match and are not stored on-device after the request completes.
- **Server-derived IP** — your client never reads or transmits its own IP address; the Helm backend reads it from the request envelope.

### SDK-shipped privacy manifest

Helm ships its own `PrivacyInfo.xcprivacy` inside the SDK bundle. The manifest declares Helm's Required Reason API usage (`UserDefaults`, reason `CA92.1` — read/write app state owned by the SDK) and the data categories Helm itself collects. Because the SDK carries this manifest, you do **not** need to add Helm-specific Required Reason API entries to your app's own privacy manifest — Xcode picks Helm's up automatically.

You still need to declare the data Helm collects in your **App Privacy** nutrition label in App Store Connect — the manifest covers Apple's static API audit; the nutrition label is what the user sees on the product page.

### App Privacy nutrition label

Copy these entries into your App Store Connect → App Privacy form:

| Data Category | Data Type | Linked to User | Used for Tracking | Purposes |
|---------------|-----------|----------------|-------------------|----------|
| Identifiers   | Device ID | Yes            | No                | App Functionality, Analytics |
| Identifiers   | User ID   | Yes            | No                | App Functionality |
| Diagnostics   | Other Diagnostic Data | No     | No                | App Functionality |

"Device ID" here is the per-install UUID Helm generates and stores in its own `UserDefaults` suite (it is **not** the IDFA and **not** the IDFV). It is linked to the user account in your Helm dashboard, but Helm never uses it for cross-app or cross-developer tracking.

"User ID" is the `userId` **you** pass to the influencer-attribution methods (`submitPromoCode`, `fetchAttributionStatus`, `submitOriginalTransactionId`). Declare this row only if your app calls them. Helm sends that string to your Helm backend and, as of 1.3.0, also persists it on device:

- inside any **queued submission** that failed for transport reasons (until it replays, or 30 days pass), and
- as the key of the **attribution status cache** (until it is overwritten, evicted, or wiped).

Both live in Helm's own `UserDefaults` keys, already covered by the SDK manifest's `CA92.1` Required Reason declaration — no Required Reason change is needed in your app. Both are cleared by `Helm.attribution.reset()` and `Helm.analytics.clearIdentity()`.

### Account deletion

For App Review Guideline 5.1.1(v) compliance, host apps that offer in-app account deletion should also clear Helm's on-device state when the user deletes their account or logs out into a different account on the same device:

```swift
Helm.attribution.reset()
```

`reset()` clears the stored attribution match, drops any queued events, resets the retry budget, and empties the pending submission queue and the attribution status cache — so no `userId` supplied by the previous user survives on device and the next `match()` runs as if on a fresh install.

`Helm.analytics.clearIdentity()` also clears the pending submission queue and the status cache, so a plain logout is enough to stop the next user on the device from inheriting the previous user's promo code or offering.

## Logging

The SDK emits structured logs via Apple's unified logging system under the subsystem `dev.helmcode.helm`. View them in Console.app or Xcode's debug console by filtering on that subsystem.

## Versioning

Helm follows [Semantic Versioning](https://semver.org):

- **Major** (`2.0.0`) — breaking API changes
- **Minor** (`1.3.0`) — additive, backwards-compatible API
- **Patch** (`1.3.1`) — backwards-compatible bug fixes

The current release is **1.3.0**. See [CHANGELOG.md](CHANGELOG.md) for release notes.

### Tagging convention

Release tags are **bare numeric** — `1.2.0`, never `v1.2.0`. Two `v`-prefixed tags
(`v0.2.0`, `v0.3.0`) were published in June 2026 by mistake. SwiftPM strips the leading
`v`, so those tags resolved as `0.2.0` / `0.3.0` — *below* the then-current `1.1.2` — and
were therefore unreachable from any `from: "1.1.x"` dependency rule. They are retained
only so existing checkouts do not break; do not add more. Every new release must be a
bare-numeric tag that sorts strictly above the previous release.

## Contributing

Issues and pull requests are welcome at [github.com/Helm-Development/Helm-iOS-SDK](https://github.com/Helm-Development/Helm-iOS-SDK).

Before opening a PR:

```bash
swift build
swift test
```

## License

The Helm iOS SDK is released under the MIT License. See [LICENSE](LICENSE) for details.
