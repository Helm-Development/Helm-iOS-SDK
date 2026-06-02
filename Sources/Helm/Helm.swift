import Foundation
import os

private let configLogger = Logger(subsystem: "dev.helmcode.helm", category: "config")

/// Helm SDK entry point. Use `Helm.configure(...)` to initialize, then access
/// `Helm.attribution` for attribution tracking.
public enum Helm {

    /// Configure the SDK with your publishable key and Helm API base URL.
    ///
    /// Call this once, typically in `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// - Parameters:
    ///   - publishableKey: Your project's publishable API key.
    ///   - baseURL: The Helm API base URL host (e.g. "https://helmcode.dev").
    ///     Pass only the scheme + host -- the SDK appends the API path prefix
    ///     (`/api/client/v1/...`) internally.
    ///   - session: The `URLSession` used for all network requests. Defaults to
    ///     `.shared`. Inject a custom session for testing or to provide custom
    ///     `URLSessionConfiguration` (timeouts, headers, etc.).
    public static func configure(
        publishableKey: String,
        baseURL: String,
        session: URLSession = .shared
    ) {
        if Configuration.shared != nil {
            configLogger.warning("Helm.configure(...) called more than once; the previous configuration was replaced.")
        }
        Configuration.shared = Configuration(
            publishableKey: publishableKey,
            baseURL: baseURL,
            session: session
        )
    }

    /// Whether `Helm.configure(...)` has been called and the SDK is ready to
    /// make network requests. Returns `false` before `configure(...)` runs
    /// and after a manual teardown.
    public static var isConfigured: Bool {
        Configuration.shared != nil
    }

    /// Access attribution tracking features.
    public static var attribution: Attribution {
        Attribution.shared
    }
}
