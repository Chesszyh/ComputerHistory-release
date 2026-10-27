import Foundation

/// All keychain access belongs to the separately installed credential executable.
public enum ModelAPIKey {
    public static var helperURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("computer-history-credentials")
    }

    public static func contains(root: URL, fallback: Bool = false, groupID: String? = nil) throws -> Bool {
        try request("contains", root: root, fallback: fallback, groupID: groupID)["exists"] as? Bool ?? false
    }
    public static func load(root: URL, fallback: Bool = false, groupID: String? = nil) throws -> String? {
        try request("load", root: root, fallback: fallback, groupID: groupID)["key"] as? String
    }
    public static func save(_ key: String, root: URL, fallback: Bool = false, groupID: String? = nil) throws {
        _ = try request("save", root: root, fallback: fallback, groupID: groupID, key: key)
    }
    public static func remove(root: URL, fallback: Bool = false, groupID: String? = nil) throws {
        _ = try request("remove", root: root, fallback: fallback, groupID: groupID)
    }
    public static func authorize(root: URL, fallback: Bool = false, groupID: String? = nil) throws {
        guard try request("authorize", root: root, fallback: fallback, groupID: groupID)["exists"] as? Bool == true else {
            throw ConfigurationInputError.invalid("当前模型组没有保存密钥。")
        }
        // A one-time Allow only authorizes that helper process. Verify a fresh background reader.
        guard try load(root: root, fallback: fallback, groupID: groupID) != nil else {
            throw ConfigurationInputError.invalid("密钥访问尚未恢复，请重试并在系统验证中选择“始终允许”。")
        }
    }

    private static func request(_ operation: String, root: URL, fallback: Bool, groupID: String?, key: String? = nil) throws -> [String: Any] {
        let executable = helperURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ConfigurationInputError.invalid("密钥助手缺失，请重新安装 ComputerHistory。")
        }
        var request: [String: Any] = ["operation": operation, "root": root.standardizedFileURL.path, "fallback": fallback]
        request["groupID"] = groupID; request["key"] = key
        let process = Process()
        process.executableURL = executable
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              process.terminationStatus == 0, result["ok"] as? Bool == true else {
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ConfigurationInputError.invalid(result?["error"] as? String ?? "密钥助手未完成操作，请在设置中恢复密钥访问。")
        }
        return result
    }
}
