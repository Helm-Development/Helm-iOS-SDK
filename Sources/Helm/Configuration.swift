import Foundation

/// Internal configuration store for the Helm SDK.
internal final class Configuration {

    /// The shared configuration instance, set via `Helm.configure(...)`.
    static var shared: Configuration?

    /// The project's publishable API key.
    let publishableKey: String

    /// The Helm API base URL (e.g. "https://helmcode.dev").
    let baseURL: String

    init(publishableKey: String, baseURL: String) {
        self.publishableKey = publishableKey
        self.baseURL = baseURL
    }
}
