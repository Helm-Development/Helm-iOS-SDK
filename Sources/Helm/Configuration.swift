import Foundation

/// Internal configuration store for the Helm SDK.
internal final class Configuration: @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _shared: Configuration?

    /// The shared configuration instance, set via `Helm.configure(...)`.
    ///
    /// Lock-protected so concurrent reads from network call sites don't race
    /// with `Helm.configure(...)` writes during app launch.
    static var shared: Configuration? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shared
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _shared = newValue
        }
    }

    /// The project's publishable API key.
    let publishableKey: String

    /// The Helm API base URL (e.g. "https://helmcode.dev").
    let baseURL: String

    /// The URLSession used for all network requests. Injectable for testing.
    let session: URLSession

    init(publishableKey: String, baseURL: String, session: URLSession = .shared) {
        self.publishableKey = publishableKey
        self.baseURL = baseURL
        self.session = session
    }
}
