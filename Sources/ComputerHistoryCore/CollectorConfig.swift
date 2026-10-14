import Foundation
import CoreFoundation

/// 采集器运行配置。
///
/// 从 `~/.computer-history/config.json` 读取；文件不存在时用默认值并写出模板，
/// 便于使用者发现可调项。字段缺失一律取默认值——配置文件向前兼容，
/// 不会因新增字段而失效。
public struct CollectorConfig: Sendable {

    /// 观测策略：决定哪些应用与域名被采集。
    public var policy: ObservationPolicy

    /// AX 树单帧节点上限。
    public var maxNodesPerSnapshot: Int

    /// 落盘保留策略。长期运行时磁盘是必须管的资源：
    /// 实测约 1.3 MB/分钟（≈1.9 GB/天），不限制会填满磁盘。
    public var retention: Retention

    /// 日志文件大小上限，超出即截断重开。
    public var maxLogBytes: Int

    public struct Retention: Sendable {
        /// 数据中心（`segments/`）总字节上限。超出后由旧到新删除整个 segment。
        public var maxTotalBytes: Int
        /// segment 最长保留天数。0 表示不按时间清理。
        public var maxAgeDays: Int

        public init(maxTotalBytes: Int = 2 * 1024 * 1024 * 1024,
                    maxAgeDays: Int = 30) {
            self.maxTotalBytes = maxTotalBytes
            self.maxAgeDays = maxAgeDays
        }
    }

    public init(
        policy: ObservationPolicy = .conservative,
        maxNodesPerSnapshot: Int = 4000,
        retention: Retention = .init(),
        maxLogBytes: Int = 8 * 1024 * 1024
    ) {
        self.policy = policy
        self.maxNodesPerSnapshot = maxNodesPerSnapshot
        self.retention = retention
        self.maxLogBytes = maxLogBytes
    }

    // MARK: - 持久化

    /// 配置文件名，位于落盘根目录下。
    public static let fileName = "config.json"

    public static func fileURL(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(fileName)
    }

    /// 仅在文件不存在时生成模板；读取或解析失败交由调用方报告并停止启动。
    public static func load(rootDirectory: URL) throws -> CollectorConfig {
        let url = fileURL(rootDirectory: rootDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let fresh = CollectorConfig()
            try FileManager.default.createDirectory(
                at: rootDirectory, withIntermediateDirectories: true)
            try fresh.jsonData().write(to: url, options: .atomic)
            return fresh
        }
        // 不能用默认采集范围覆盖使用者的隐私限制。
        return try decode(from: data)
    }

    /// 从 JSON 解码。缺字段取默认值。
    public static func decode(from data: Data) throws -> CollectorConfig {
        let any = try JSONSerialization.jsonObject(with: data)
        guard let dict = any as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        try ConfigValidation.keys(dict, allowed: ["maxNodesPerSnapshot", "maxLogBytes", "retention", "policy"], path: "config")
        var config = CollectorConfig()
        if let n = try ConfigValidation.integer(dict, "maxNodesPerSnapshot", minimum: 1) { config.maxNodesPerSnapshot = n }
        if let n = try ConfigValidation.integer(dict, "maxLogBytes", minimum: 1) { config.maxLogBytes = n }
        if let r = try ConfigValidation.object(dict, "retention") {
            try ConfigValidation.keys(r, allowed: ["maxTotalBytes", "maxAgeDays"], path: "retention")
            if let n = try ConfigValidation.integer(r, "maxTotalBytes", minimum: 0) { config.retention.maxTotalBytes = n }
            if let n = try ConfigValidation.integer(r, "maxAgeDays", minimum: 0) { config.retention.maxAgeDays = n }
        }
        if let policy = try ConfigValidation.object(dict, "policy") {
            config.policy = try ObservationPolicy(json: policy)
        }
        return config
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case notAnObject
        case invalidField(String, expected: String)

        public var description: String {
            switch self {
            case .notAnObject: return "配置顶层必须是对象"
            case let .invalidField(path, expected): return "字段 \(path) 无效；应为\(expected)"
            }
        }
    }

    public func jsonData() throws -> Data {
        let obj: [String: Any] = [
            "maxNodesPerSnapshot": maxNodesPerSnapshot,
            "maxLogBytes": maxLogBytes,
            "retention": [
                "maxTotalBytes": retention.maxTotalBytes,
                "maxAgeDays": retention.maxAgeDays,
            ],
            "policy": policy.jsonObject,
        ]
        return try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }
}

/// 清理结果，用于日志。
public struct PruneReport: Sendable {
    public var removedSegments: Int = 0
    public var freedBytes: Int = 0
    /// 剩余可识别时间段的文件字节数；无法完整读取时为 nil。
    public var remainingBytes: Int?
    public var failures: [Failure] = []

    public struct Failure: Sendable {
        public enum Operation: String, Sendable {
            case list = "读取目录"
            case measure = "统计字节"
            case remove = "删除目录"
        }
        public let directory: URL
        public let operation: Operation
        public let message: String
    }
}

// 缺字段与错误字段必须区分，避免隐私规则拼写或类型错误时扩大采集范围。
enum ConfigValidation {
    static func keys(_ object: [String: Any], allowed: Set<String>, path: String) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw CollectorConfig.ConfigError.invalidField("\(path).\(unknown)", expected: "以下字段之一：" + allowed.sorted().joined(separator: ", "))
        }
    }

    static func object(_ parent: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let value = parent[key] else { return nil }
        guard let object = value as? [String: Any] else {
            throw CollectorConfig.ConfigError.invalidField(key, expected: "对象")
        }
        return object
    }

    static func integer(_ parent: [String: Any], _ key: String, minimum: Int) throws -> Int? {
        guard let value = parent[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = value as? Int, integer >= minimum else {
            throw CollectorConfig.ConfigError.invalidField(key, expected: "不小于 \(minimum) 的整数")
        }
        return integer
    }
}
