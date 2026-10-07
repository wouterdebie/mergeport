import Foundation
import MergeportCore
import Security

enum TokenVault {
    static let github = "github-oauth"
    static let linear = "linear-oauth"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.wouter.mergeport",
         kSecAttrAccount as String: account]
    }

    static func read(account: String = github) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw MergeportError.message("The \(account == linear ? "Linear" : "GitHub") credential in Keychain is invalid. Sign out and reconnect.")
        }
        return token
    }

    static func save(_ token: String, account: String = github) throws {
        let data = Data(token.utf8)
        let query = query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    static func delete(account: String = github) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> MergeportError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .message("Keychain: \(message)")
    }
}
