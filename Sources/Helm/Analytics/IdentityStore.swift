import Foundation

/// Persists the user_hash handed to the app by the TastySpread login response,
/// between `identify(userHash:)` and `clearIdentity()`.
internal final class IdentityStore {

    private enum Keys {
        static let userHash = "helm_user_hash"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored user hash, or `nil` when anonymous.
    var userHash: String? {
        let value = defaults.string(forKey: Keys.userHash) ?? ""
        return value.isEmpty ? nil : value
    }

    func store(userHash: String) {
        defaults.set(userHash, forKey: Keys.userHash)
    }

    func clear() {
        defaults.removeObject(forKey: Keys.userHash)
    }
}
