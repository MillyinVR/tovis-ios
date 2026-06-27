import Foundation
import Security

/// Secure storage for the session JWT, backed by the iOS Keychain.
///
/// An `actor` so concurrent reads/writes are serialized safely. The bearer
/// token is the app's long-lived credential — it must live here, never in
/// `UserDefaults` or plain files.
public actor TokenStore {
    private let service: String
    private let account = "session-token"

    /// `service` should be unique to the app; default uses the bundle id style.
    public init(service: String = "me.tovis.app.session") {
        self.service = service
    }

    /// The current session token, or nil if signed out.
    public func token() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    /// True if a token is present.
    public func hasToken() -> Bool {
        token() != nil
    }

    /// Store (or replace) the session token.
    public func save(_ token: String) {
        let data = Data(token.utf8)
        var query = baseQuery()

        // Upsert: try update first, fall back to add.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    /// Remove the token (sign-out).
    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}