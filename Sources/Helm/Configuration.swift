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

    /// TAS-801: when `true`, every attribution submission this build makes is
    /// registered in Helm as **sandbox test data** (wire field `debug`) and is
    /// permanently excluded from payouts and billing. Defaults to `false` so a
    /// production build is safe without any change at the call site.
    let debug: Bool

    /// The URLSession used for all network requests. Injectable for testing.
    let session: URLSession

    init(publishableKey: String,
         baseURL: String,
         debug: Bool = false,
         session: URLSession = .shared) {
        self.publishableKey = publishableKey
        self.baseURL = baseURL
        self.debug = debug
        self.session = session
    }
}
