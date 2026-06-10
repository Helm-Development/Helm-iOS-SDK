import Foundation

/// Owns the analytics session id: new UUID on cold start, rotated when the app
/// returns to the foreground after more than `backgroundTimeout` seconds.
/// Clock is injected for tests. Memory-only by design (spec §4).
internal final class SessionManager {

    private let backgroundTimeout: TimeInterval
    private let now: () -> Date
    private var backgroundedAt: Date?

    /// The current session id (lowercase UUID4 string).
    private(set) var sessionId: String

    init(backgroundTimeout: TimeInterval = 300, now: @escaping () -> Date = Date.init) {
        self.backgroundTimeout = backgroundTimeout
        self.now = now
        self.sessionId = UUID().uuidString.lowercased()
    }

    func appDidEnterBackground() {
        backgroundedAt = now()
    }

    /// Rotates the session if the background stay exceeded the timeout.
    /// Returns `true` when a new session started.
    @discardableResult
    func appWillEnterForeground() -> Bool {
        defer { backgroundedAt = nil }
        guard let backgrounded = backgroundedAt,
              now().timeIntervalSince(backgrounded) > backgroundTimeout else {
            return false
        }
        sessionId = UUID().uuidString.lowercased()
        return true
    }
}
