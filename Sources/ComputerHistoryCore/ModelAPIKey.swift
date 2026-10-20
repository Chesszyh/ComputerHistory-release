import Foundation
import Security

public enum ModelAPIKey {
    private static let service = "ComputerHistory.ModelAPIKey"

    private static func query(root: URL, fallback: Bool = false, groupID: String? = nil) -> [String: Any] {
        let suffix: String
        switch groupID {
        case nil: suffix = fallback ? "#fallback" : ""
        case "legacy-primary": suffix = ""
        case "legacy-fallback": suffix = "#fallback"
        default: suffix = "#group:" + groupID!
        }
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: root.standardizedFileURL.path + suffix]
    }

    public static func contains(root: URL, fallback: Bool = false, groupID: String? = nil) throws -> Bool {
        var attributes = query(root: root, fallback: fallback, groupID: groupID)
        // Settings only need existence; requesting secret data here would prompt for another executable's access.
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(attributes as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeyError(status: status) }
        return true
    }

    public static func load(root: URL, fallback: Bool = false, groupID: String? = nil) throws -> String? {
        var attributes = query(root: root, fallback: fallback, groupID: groupID)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw KeyError(status: status) }
        return key
    }

    public static func save(_ key: String, root: URL, fallback: Bool = false, groupID: String? = nil) throws {
        let attributes = query(root: root, fallback: fallback, groupID: groupID)
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

    public static func remove(root: URL, fallback: Bool = false, groupID: String? = nil) throws {
        let status = SecItemDelete(query(root: root, fallback: fallback, groupID: groupID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError(status: status) }
    }

    public struct KeyError: Error, CustomStringConvertible {
        let status: OSStatus
        public var description: String { "无法访问模型密钥：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))" }
    }
}
