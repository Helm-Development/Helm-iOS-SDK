import Foundation

/// Helm SDK entry point. Use `Helm.configure(...)` to initialize, then access
/// `Helm.attribution` for attribution tracking.
public enum Helm {

    /// Configure the SDK with your publishable key and Helm API base URL.
    ///
    /// Call this once, typically in `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// - Parameters:
    ///   - publishableKey: Your project's publishable API key.
    ///   - baseURL: The Helm API base URL (e.g. "https://helmcode.dev").
    ///   - session: The `URLSession` used for all network requests. Defaults to
    ///     `.shared`. Inject a custom session for testing or to provide custom
    ///     `URLSessionConfiguration` (timeouts, headers, etc.).
    public static func configure(
        publishableKey: String,
        baseURL: String,
        session: URLSession = .shared
    ) {
        Configuration.shared = Configuration(
            publishableKey: publishableKey,
            baseURL: baseURL,
            session: session
        )
    }

    /// Access attribution tracking features.
    public static var attribution: Attribution {
        Attribution.shared
    }
}
