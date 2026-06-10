import Foundation
import Security

/// Persists the analytics installation id (UUID4, lowercase), generated once.
/// Keychain-backed so the id survives app reinstall; falls back to UserDefaults
/// when Keychain is unavailable (unit tests, macOS CLI contexts).
internal final class InstallationStore {

    private enum Keys {
        static let service = "dev.helmcode.helm"
        static let account = "helm_installation_id"
        static let defaultsKey = "helm_installation_id"
    }

    private let defaults: UserDefaults
    private let useKeychain: Bool

    init(defaults: UserDefaults = .standard, useKeychain: Bool = true) {
        self.defaults = defaults
        self.useKeychain = useKeychain
    }

    /// The stable installation id. Generated on first access.
    var installationId: String {
        if useKeychain, let existing = readKeychain(), !existing.isEmpty {
            return existing
        }
        if let existing = defaults.string(forKey: Keys.defaultsKey), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString.lowercased()
        if !(useKeychain && writeKeychain(newId)) {
            defaults.set(newId, forKey: Keys.defaultsKey)
        }
        return newId
    }

    // MARK: - Keychain

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: Keys.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: Keys.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
