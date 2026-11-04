import Foundation
import Security

public enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(msg)"
        case .invalidData:
            return "Keychain returned unreadable credential data."
        }
    }
}

public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = AppEnvironment.keychainService) {
        self.service = service
    }

    public func loadCredentials(for device: AppleTVDevice) -> [String: String] {
        let candidates = [device.identifier] + device.allIdentifiers
        var seen = Set<String>()
        for id in candidates where seen.insert(id).inserted {
            if let creds = loadCredentials(identifier: id), !creds.isEmpty {
                return creds
            }
        }
        return [:]
    }

    public func loadCredentials(identifier: String) -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    public func saveCredentials(_ credentials: [String: String], for identifier: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "TV Remote (\(identifier))",
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributesToUpdate as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = "TV Remote (\(identifier))"
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func deleteCredentials(for device: AppleTVDevice) {
        let candidates = Set([device.identifier] + device.allIdentifiers)
        for id in candidates {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: id,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
