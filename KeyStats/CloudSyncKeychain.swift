import Foundation
import Security

enum CloudSyncKeychain {
    private static let service = "com.keystats.app.cloudsync"
    private static let tokenAccount = "auth_token"
    private static let userIdAccount = "user_id"

    static func saveToken(_ token: String) {
        save(token, account: tokenAccount)
    }

    static func loadToken() -> String? {
        load(account: tokenAccount)
    }

    static func deleteToken() {
        delete(account: tokenAccount)
    }

    static func saveUserId(_ userId: String) {
        save(userId, account: userIdAccount)
    }

    static func loadUserId() -> String? {
        load(account: userIdAccount)
    }

    static func deleteUserId() {
        delete(account: userIdAccount)
    }

    static func clearCredentials() {
        deleteToken()
        deleteUserId()
    }

    private static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            #if DEBUG
            NSLog("[CloudSyncKeychain] delete failed for %@: %d", account, deleteStatus)
            #endif
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            #if DEBUG
            NSLog("[CloudSyncKeychain] save failed for %@: %d", account, addStatus)
            #endif
        }
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
