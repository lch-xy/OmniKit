//
//  CredentialStore.swift
//  OmniKit
//

import Foundation
import Security

enum CredentialStore {
    static func load(forKey key: String, store: OmniKitStore = .shared) -> (value: String, error: String?) {
        let legacyValue = store.string(forKey: key)
        var value = legacyValue ?? ""
        do {
            var query = baseQuery(forKey: key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess {
                guard let data = result as? Data, let stored = String(data: data, encoding: .utf8) else {
                    throw keychainError(errSecDecode)
                }
                value = stored
            } else if status != errSecItemNotFound {
                throw keychainError(status)
            }
            if legacyValue != nil {
                try save(value, forKey: key, store: store)
            }
            return (value, nil)
        } catch {
            return (value, "密钥存储失败：\(error.localizedDescription)")
        }
    }

    static func save(_ value: String, forKey key: String, store: OmniKitStore = .shared) throws {
        let query = baseQuery(forKey: key)
        let status: OSStatus
        if value.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            status = result == errSecItemNotFound ? errSecSuccess : result
        } else {
            let attributes = [kSecValueData as String: Data(value.utf8)]
            let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if result == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = Data(value.utf8)
                status = SecItemAdd(item as CFDictionary, nil)
            } else {
                status = result
            }
        }
        guard status == errSecSuccess else { throw keychainError(status) }
        if let legacyValue = store.object(forKey: key) {
            store.removeObject(forKey: key)
            do {
                try store.synchronize()
            } catch {
                store.set(legacyValue, forKey: key)
                throw error
            }
        }
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.lch.OmniKit",
            kSecAttrAccount as String: key
        ]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误（\(status)）"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
