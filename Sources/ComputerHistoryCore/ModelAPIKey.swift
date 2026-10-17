import Foundation
import Security

public enum ModelAPIKey {
    private static let service = "ComputerHistory.ModelAPIKey"

    private static func query(root: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: root.standardizedFileURL.path]
    }

    public static func load(root: URL) throws -> String? {
        var attributes = query(root: root)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw KeyError(status: status) }
        return key
    }

    public static func save(_ key: String, root: URL) throws {
        let attributes = query(root: root)
        let data = Data(key.utf8)
        let status = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = attributes
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "ComputerHistory 模型服务密钥"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeyError(status: added) }
        } else if status != errSecSuccess { throw KeyError(status: status) }
    }

    public static func remove(root: URL) throws {
        let status = SecItemDelete(query(root: root) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError(status: status) }
    }

    public struct KeyError: Error, CustomStringConvertible {
        let status: OSStatus
        public var description: String { "无法访问模型密钥：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))" }
    }
}
