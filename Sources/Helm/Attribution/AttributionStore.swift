import Foundation

/// Persists attribution state in UserDefaults.
internal final class AttributionStore: @unchecked Sendable {

    private enum Keys {
        static let checked = "helm_attribution_checked"
        static let attributionId = "helm_attribution_id"
        static let deviceId = "helm_device_id"
        // HELM-184: bounded retry budget so a backend outage on first
        // launch can't slam the server forever.
        static let attempts = "helm_attribution_attempts"
        static let lastAttempt = "helm_attribution_last_attempt"
    }

    /// Maximum number of `match()` attempts before the SDK gives up and
    /// flips `hasChecked` to true. Exposed for tests.
    static let maxAttempts: Int = 5

    /// Maximum time window from the first attempt before the SDK gives up,
    /// even if `maxAttempts` hasn't been reached. Exposed for tests.
    static let maxRetryWindow: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private let defaults: UserDefaults

    /// Serializes the device-id read-modify-write so two concurrent first-launch
    /// callers cannot each see a nil value and write a different UUID.
    private let deviceIdLock = NSLock()

    /// Initialize with an explicit UserDefaults suite (useful for testing).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Has Checked

    /// Whether an attribution match has already been attempted.
    var hasChecked: Bool {
        defaults.bool(forKey: Keys.checked)
    }

    /// Mark that an attribution check has been performed.
    func markChecked() {
        defaults.set(true, forKey: Keys.checked)
    }

    // MARK: - Attribution ID

    /// The stored attribution ID, or `nil` if empty / not yet set.
    var attributionId: String? {
        let value = defaults.string(forKey: Keys.attributionId) ?? ""
        return value.isEmpty ? nil : value
    }

    /// The raw stored attribution ID string (empty string if unmatched, empty if not set).
    var rawAttributionId: String {
        defaults.string(forKey: Keys.attributionId) ?? ""
    }

    /// Store a successful attribution match.
    func storeMatch(attributionId: String) {
        defaults.set(attributionId, forKey: Keys.attributionId)
    }

    /// Store that attribution was checked but no match was found.
    func storeUnmatched() {
        defaults.set("", forKey: Keys.attributionId)
    }

    // MARK: - Retry Budget (HELM-184)

    /// Serializes attempt-counter writes so concurrent `_match()` failures
    /// can't lose increments or flip `canRetry` based on a torn read.
    private let retryLock = NSLock()

    /// Whether `match()` is still allowed another attempt.
    ///
    /// `false` once either the attempt cap (`maxAttempts`) is reached or
    /// the retry window (`maxRetryWindow` from the first attempt) has
    /// elapsed. The Attribution layer is expected to call `markChecked()`
    /// once `canRetry` flips to false so subsequent launches skip the
    /// network entirely.
    var canRetry: Bool {
        retryLock.lock()
        defer { retryLock.unlock() }
        let attempts = defaults.integer(forKey: Keys.attempts)
        if attempts >= Self.maxAttempts {
            return false
        }
        let firstAttempt = defaults.double(forKey: Keys.lastAttempt)
        // `lastAttempt` is actually the first-attempt timestamp -- written
        // once when attempts == 0 and never overwritten. The naming on the
        // UserDefaults key is preserved for the spec; semantically this is
        // "the moment we started trying."
        if firstAttempt > 0,
           Date().timeIntervalSince1970 - firstAttempt >= Self.maxRetryWindow {
            return false
        }
        return true
    }

    /// Increment the attempt counter and stamp the first-attempt timestamp
    /// on the first failure. Idempotent in the sense that the timestamp is
    /// only written once.
    func recordFailedAttempt() {
        retryLock.lock()
        defer { retryLock.unlock() }
        let attempts = defaults.integer(forKey: Keys.attempts)
        if attempts == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastAttempt)
        }
        defaults.set(attempts + 1, forKey: Keys.attempts)
    }

    /// Reset the retry budget. Called on a successful match so subsequent
    /// SDK upgrades / forced re-matches start fresh.
    func resetRetryBudget() {
        retryLock.lock()
        defer { retryLock.unlock() }
        defaults.removeObject(forKey: Keys.attempts)
        defaults.removeObject(forKey: Keys.lastAttempt)
    }

    /// Current attempt count -- exposed for tests.
    var attemptCount: Int {
        retryLock.lock()
        defer { retryLock.unlock() }
        return defaults.integer(forKey: Keys.attempts)
    }

    // MARK: - Reset (HELM-189)

    /// Remove every key this store owns, returning the SDK to a fresh-install
    /// state. Used by `Attribution.reset()`.
    ///
    /// - Note: `helm_device_id` is intentionally NOT cleared here.  Device
    ///   identity is now the Keychain-backed installation id owned by
    ///   `Analytics`; attribution reset must not rotate it (HELM-203).
    func clearAll() {
        retryLock.lock()
        defer { retryLock.unlock() }
        defaults.removeObject(forKey: Keys.checked)
        defaults.removeObject(forKey: Keys.attributionId)
        defaults.removeObject(forKey: Keys.attempts)
        defaults.removeObject(forKey: Keys.lastAttempt)
    }

    // MARK: - Device ID (deprecated — HELM-203)

    /// A UserDefaults-backed device identifier (random UUID, generated once
    /// per install).
    ///
    /// - Deprecated: Attribution now uses the Keychain-backed installation id
    ///   via `Analytics.shared.installationIdValue`.  This property is retained
    ///   for backward compatibility but is no longer used in the match path.
    var deviceId: String {
        deviceIdLock.lock()
        defer { deviceIdLock.unlock() }
        if let existing = defaults.string(forKey: Keys.deviceId), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        defaults.set(newId, forKey: Keys.deviceId)
        return newId
    }
}
