# Helm iOS SDK

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015-blue.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

The official Swift SDK for [Helm](https://helmcode.dev). Attribute installs, track conversion events, and tie user activity back to the campaign that drove it — with a single `configure` call and a one-line `match()`.

## Features

- **Attribution matching** — match each install to the campaign, channel, or tracking link that drove it, using device-side signals (no IDFA required).
- **Event tracking** — record conversion events (`signup`, `purchase`, etc.) with optional metadata, automatically linked to the matched attribution source.
- **Fire-and-forget API** — all network calls run in the background; calling code never blocks.
- **Privacy-first** — no IDFA, no ATT prompt, no third-party trackers. Device signals are collected only on first match and never persisted off-device by the SDK.
- **Zero dependencies** — pure Foundation + `os.log`. No transitive packages.
- **Lightweight** — under 500 lines of source.

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
3. Set the dependency rule to **Up to Next Major Version** starting from `1.1.2`.
4. Add the `Helm` library product to your app target.

### Swift Package Manager (Package.swift)

Add Helm to the `dependencies` array of your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Helm-Development/Helm-iOS-SDK.git", from: "1.1.2")
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

    /// Reset all SDK attribution state so the next `match()` runs as if
    /// this were a fresh install. Generates a new `device_id`, clears
    /// the stored attribution match, drops any queued events, and resets
    /// the retry budget. Call this on logout or account deletion.
    public func reset()
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
| Diagnostics   | Other Diagnostic Data | No     | No                | App Functionality |

"Device ID" here is the per-install UUID Helm generates and stores in its own `UserDefaults` suite (it is **not** the IDFA and **not** the IDFV). It is linked to the user account in your Helm dashboard, but Helm never uses it for cross-app or cross-developer tracking.

### Account deletion

For App Review Guideline 5.1.1(v) compliance, host apps that offer in-app account deletion should also clear Helm's on-device state when the user deletes their account or logs out into a different account on the same device:

```swift
Helm.attribution.reset()
```

`reset()` generates a new `device_id`, clears the stored attribution match, drops any queued events, and resets the retry budget so the next `match()` runs as if on a fresh install.

## Logging

The SDK emits structured logs via Apple's unified logging system under the subsystem `dev.helmcode.helm`. View them in Console.app or Xcode's debug console by filtering on that subsystem.

## Versioning

Helm follows [Semantic Versioning](https://semver.org):

- **Major** (`2.0.0`) — breaking API changes
- **Minor** (`1.2.0`) — additive, backwards-compatible API
- **Patch** (`1.1.3`) — backwards-compatible bug fixes

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Contributing

Issues and pull requests are welcome at [github.com/Helm-Development/Helm-iOS-SDK](https://github.com/Helm-Development/Helm-iOS-SDK).

Before opening a PR:

```bash
swift build
swift test
```

## License

The Helm iOS SDK is released under the MIT License. See [LICENSE](LICENSE) for details.
