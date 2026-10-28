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
        // HELM-325: how the stored attribution ID was obtained, when it came
        // from an exact method (clipboard handoff or, from HELM-336, Apple
        // Ads). Empty or missing means the ID, if any, came from `match()`.
        static let method = "helm_attribution_method"
        // HELM-325: set once a clipboard handoff code has been redeemed for
        // this installation, whether or not it became the primary attribution.
        static let clipboardRedeemed = "helm_clipboard_redeemed"
        // HELM-325: the pasteboard change count at the moment the user pasted
        // something that did not attribute the install (not a handoff URL, or
        // a code Helm rejected). While the clipboard still has that change
        // count, `hasClipboardHandoff()` returns `false` so the app does not
        // keep offering the same paste.
        static let clipboardDismissedChangeCount = "helm_clipboard_dismissed_change_count"
        // HELM-336: the Apple Ads check. `finished` stops it for good; the
        // attempt count and first-attempt time bound the retries.
        static let appleAdsFinished = "helm_apple_ads_finished"
        static let appleAdsAttempts = "helm_apple_ads_attempts"
        static let appleAdsFirstAttempt = "helm_apple_ads_first_attempt"
    }

    /// How an exact attribution ID was obtained. The raw value is persisted.
    enum ExactMethod: String {
        /// HELM-325: a clipboard handoff code pasted through the Paste button.
        case clipboard
        /// HELM-336: an Apple Ads install, from the AdServices token.
        case appleAds = "apple_ads"
    }

    /// HELM-336: the most Apple Ads attempts without a final answer: the first
    /// plus 3 more. One attempt is up to `maxAppleAdsSendsPerAttempt` sends
    /// in one launch. Exposed for tests.
    static let maxAppleAdsAttempts: Int = 4

    /// HELM-336: the most sends in one attempt. Apple answers "not ready" if
    /// asked too soon after the token was made, and advises retrying every 5
    /// seconds up to 3 times. Exposed for tests.
    static let maxAppleAdsSendsPerAttempt: Int = 3

    /// HELM-336: the wait between sends in one attempt. Exposed for tests.
    static let appleAdsSendInterval: TimeInterval = 5

    /// HELM-336: how long after the first try the Apple Ads check keeps
    /// retrying. Matches the token's 24-hour lifetime. Exposed for tests.
    static let appleAdsRetryWindow: TimeInterval = 24 * 60 * 60

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

    // MARK: - Exact attribution (HELM-325)

    /// Store an attribution ID that came from an exact method, replacing any
    /// earlier unmatched or `match()` result. `match()` never overwrites an
    /// exact attribution.
    func storeExactMatch(attributionId: String, method: ExactMethod) {
        defaults.set(attributionId, forKey: Keys.attributionId)
        defaults.set(method.rawValue, forKey: Keys.method)
    }

    /// The exact method behind the stored attribution ID, or `nil` when the
    /// stored ID (if any) came from `match()`.
    var exactMethod: ExactMethod? {
        defaults.string(forKey: Keys.method).flatMap(ExactMethod.init(rawValue:))
    }

    /// Whether the stored attribution ID came from an exact method.
    var hasExactAttribution: Bool {
        exactMethod != nil
    }

    // MARK: - Clipboard handoff (HELM-325)

    /// Whether a clipboard handoff code has been redeemed for this
    /// installation.
    var clipboardRedeemed: Bool {
        defaults.bool(forKey: Keys.clipboardRedeemed)
    }

    /// Record that a clipboard handoff code was redeemed.
    func markClipboardRedeemed() {
        defaults.set(true, forKey: Keys.clipboardRedeemed)
    }

    /// The pasteboard change count of the last paste that did not attribute
    /// the install, or `nil` if there has been none.
    var clipboardDismissedChangeCount: Int? {
        defaults.object(forKey: Keys.clipboardDismissedChangeCount) as? Int
    }

    /// Remember the pasteboard change count of a paste that did not attribute
    /// the install.
    func storeClipboardDismissed(changeCount: Int) {
        defaults.set(changeCount, forKey: Keys.clipboardDismissedChangeCount)
    }

    // MARK: - Apple Ads check (HELM-336)

    /// Whether the Apple Ads check has finished for this installation. Once
    /// it has, it never runs again.
    var appleAdsFinished: Bool {
        defaults.bool(forKey: Keys.appleAdsFinished)
    }

    /// Record that the Apple Ads check has finished.
    func markAppleAdsFinished() {
        defaults.set(true, forKey: Keys.appleAdsFinished)
    }

    /// The number of Apple Ads attempts that ended without a final answer
    /// (`pending` or a failed request on every send of the attempt).
    var appleAdsAttemptCount: Int {
        defaults.integer(forKey: Keys.appleAdsAttempts)
    }

    /// Count one Apple Ads attempt that ended without a final answer.
    func recordAppleAdsAttempt() {
        defaults.set(appleAdsAttemptCount + 1, forKey: Keys.appleAdsAttempts)
    }

    /// When the Apple Ads check first ran, or `nil` before it has.
    var appleAdsFirstAttempt: Date? {
        let seconds = defaults.double(forKey: Keys.appleAdsFirstAttempt)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Record when the Apple Ads check first ran. Later calls do nothing.
    func stampAppleAdsFirstAttemptIfNeeded(_ date: Date) {
        guard appleAdsFirstAttempt == nil else { return }
        defaults.set(date.timeIntervalSince1970, forKey: Keys.appleAdsFirstAttempt)
    }

    /// Whether the Apple Ads check has used its attempts or its 24-hour
    /// window, measured from the first try.
    func appleAdsRetriesExhausted(now: Date = Date()) -> Bool {
        if appleAdsAttemptCount >= Self.maxAppleAdsAttempts { return true }
        if let first = appleAdsFirstAttempt,
           now.timeIntervalSince(first) >= Self.appleAdsRetryWindow {
            return true
        }
        return false
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
        defaults.removeObject(forKey: Keys.method)
        defaults.removeObject(forKey: Keys.clipboardRedeemed)
        defaults.removeObject(forKey: Keys.clipboardDismissedChangeCount)
        defaults.removeObject(forKey: Keys.appleAdsFinished)
        defaults.removeObject(forKey: Keys.appleAdsAttempts)
        defaults.removeObject(forKey: Keys.appleAdsFirstAttempt)
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
