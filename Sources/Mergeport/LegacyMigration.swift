import Foundation
import Security

/// One-time import of settings and the OAuth token from the app's former name, Gityard.
enum LegacyMigration {
    private static let legacyID = "dev.wouter.gityard"
    private static let doneKey = "migratedFromGityard"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey), !ProcessInfo.processInfo.arguments.contains("--demo") else { return }
        if let legacy = defaults.persistentDomain(forName: legacyID) {
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        migrateToken()
        defaults.set(true, forKey: doneKey)
    }

    private static func migrateToken() {
        guard (try? TokenVault.read()) == nil else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyID,
            kSecAttrAccount as String: "github-oauth",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty,
              (try? TokenVault.save(token)) != nil else { return }
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyID,
            kSecAttrAccount as String: "github-oauth",
        ]
        SecItemDelete(legacy as CFDictionary)
    }
}
