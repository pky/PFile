import Foundation
import Security

final class KeychainService {

    static let shared = KeychainService()
    private init() {}

    // MARK: - Save

    func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
#if targetEnvironment(simulator)
        UserDefaults.standard.set(data, forKey: key)
#else
        try saveToKeychain(data: data, key: key)
#endif
    }

    // MARK: - Load

    func load<T: Decodable>(_ type: T.Type, key: String) throws -> T {
#if targetEnvironment(simulator)
        guard let data = UserDefaults.standard.data(forKey: key) else {
            throw KeychainError.itemNotFound
        }
        return try JSONDecoder().decode(type, from: data)
#else
        let data = try loadFromKeychain(key: key)
        return try JSONDecoder().decode(type, from: data)
#endif
    }

    // MARK: - Delete

    func delete(key: String) {
#if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: key)
#else
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }

    // MARK: - Private (Keychain)

#if !targetEnvironment(simulator)

    private func saveToKeychain(data: Data, key: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func loadFromKeychain(key: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.loadFailed(status)
        }
        return data
    }

#endif
}

// MARK: - KeychainError

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .saveFailed(let s):  return "Keychain 保存に失敗しました (status: \(s))"
        case .loadFailed(let s):  return "Keychain 読み込みに失敗しました (status: \(s))"
        case .itemNotFound:       return "認証情報が見つかりません"
        }
    }
}
