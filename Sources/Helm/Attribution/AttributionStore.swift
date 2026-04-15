import Foundation

/// Persists attribution state in UserDefaults.
internal final class AttributionStore {

    private enum Keys {
        static let checked = "helm_attribution_checked"
        static let attributionId = "helm_attribution_id"
        static let deviceId = "helm_device_id"
    }

    private let defaults: UserDefaults

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

    // MARK: - Device ID

    /// A stable device identifier (random UUID, generated once per install).
    var deviceId: String {
        if let existing = defaults.string(forKey: Keys.deviceId), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        defaults.set(newId, forKey: Keys.deviceId)
        return newId
    }
}
