import Foundation
import LocalAuthentication
import Security

/// One app-owned device connection, in this device's native secure storage.
@MainActor struct CircleKeychainStore: CircleCredentialStore {
    private var query: [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "circle.hub", kSecAttrAccount as String: "reader",
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: authentication]
    }

    func load() throws -> StoredCircleConnection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw CircleConnectionError.invalidConfiguration }
        return try JSONDecoder().decode(StoredCircleConnection.self, from: data)
    }

    func save(_ value: StoredCircleConnection) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(request as CFDictionary, nil))
        } else { try check(status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CircleKeychainError(status: status) }
    }
}

private struct CircleKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecMissingEntitlement {
            return "This development build lacks the signing entitlement needed for secure storage. Install a correctly signed Circle build."
        }
        return "Circle cannot access its saved connection (Keychain \(status)). Unlock this device and try again."
    }
}
