import Foundation

/// Owns the analytics session id: new UUID on cold start, rotated when the app
/// returns to the foreground after more than `backgroundTimeout` seconds.
/// Clock is injected for tests. Memory-only by design (spec §4).
///
/// Thread-safe: `sessionId` is written from main-thread lifecycle handlers and
/// read from arbitrary threads via `track()`/`headers`, so all mutable state
/// is lock-protected.
internal final class SessionManager: @unchecked Sendable {

    private let backgroundTimeout: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var backgroundedAt: Date?
    private var _sessionId: String

    /// The current session id (lowercase UUID4 string).
    var sessionId: String {
        lock.lock(); defer { lock.unlock() }
        return _sessionId
    }

    init(backgroundTimeout: TimeInterval = 300, now: @escaping () -> Date = Date.init) {
        self.backgroundTimeout = backgroundTimeout
        self.now = now
        self._sessionId = UUID().uuidString.lowercased()
    }

    func appDidEnterBackground() {
        lock.lock(); defer { lock.unlock() }
        backgroundedAt = now()
    }

    /// Rotates the session if the background stay exceeded the timeout.
    /// Returns `true` when a new session started.
    @discardableResult
    func appWillEnterForeground() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { backgroundedAt = nil }
        guard let backgrounded = backgroundedAt,
              now().timeIntervalSince(backgrounded) > backgroundTimeout else {
            return false
        }
        _sessionId = UUID().uuidString.lowercased()
        return true
    }
}
