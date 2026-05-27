import Foundation
import Security

protocol KeychainStoring {
    func saveString(_ value: String, for key: String) throws
    func readString(for key: String) throws -> String?
    func deleteString(for key: String) throws
}

enum KeychainStoreError: Error {
    case unexpectedStatus(OSStatus)
    case invalidData
}

struct KeychainStore: KeychainStoring {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "VoiceFlow") {
        self.service = service
    }

    func saveString(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        try deleteString(for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func readString(for key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func deleteString(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}

final class InMemoryKeychainStore: KeychainStoring {
    private var storage: [String: String] = [:]

    func saveString(_ value: String, for key: String) throws {
        storage[key] = value
    }

    func readString(for key: String) throws -> String? {
        storage[key]
    }

    func deleteString(for key: String) throws {
        storage.removeValue(forKey: key)
    }
}
