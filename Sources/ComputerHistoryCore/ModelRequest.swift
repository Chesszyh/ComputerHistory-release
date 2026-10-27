import Foundation

public struct ModelRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var model: String
    public var endpoint: String
    public var task: String
    public var sources: [String]
    public var status: String
    public var system: String
    public var input: String
    public var output: String?
    public var error: String?
    public var finishReason: String?
    public var usage: DeepSeekClient.Usage?
    public var pricing: ModelPricing?
    public var estimatedCost: Double?
    public var comparisonOf: String? = nil
    public var fallbackOf: String? = nil
    public var worker: CollectorProcessIdentity? = nil
    public var durationSeconds: Double? = nil

    public func save(root: URL) throws {
        let dir = root.appendingPathComponent("requests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = EventStreamJSON.makeEncoder(preservingSubseconds: true)
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent(id + ".json"), options: .atomic)
    }

    public static func load(url: URL) throws -> ModelRequest {
        try EventStreamJSON.makeDecoder(acceptingLegacyNumericDates: true).decode(Self.self, from: Data(contentsOf: url))
    }

    public var taskLabel: String {
        let label: String
        switch task { case "10min": label = "十分钟记忆"; case "6h": label = "六小时汇总"
        case "daily": label = "日报"; case "weekly": label = "周报"
        case "narrative-grouping": label = "活动归属"
        case "narrative": label = "活动整理"; default: label = task }
        return fallbackOf != nil ? "降级 · " + label : (comparisonOf == nil ? label : "历史对照 · " + label)
    }
    public var statusLabel: String {
        if status == "running" {
            guard let worker else { return "状态未知" }
            return worker.matchesLiveProcess ? "请求中" : "已中断"
        }
        switch status { case "running": return "请求中"; case "success": return "已返回"
        case "empty": return "空输出"; case "truncated": return "输出截断"; default: return "失败" }
    }
    public var costLabel: String {
        guard let cost = estimatedCost, let pricing else { return "费用未知" }
        return "\(pricing.currency) " + String(format: "%.4f", cost)
    }
}

/// 只缓存列表字段；请求正文按需读取，刷新不会常驻所有输入和输出。
public actor ModelRequestLoader {
    private struct Cached {
        var stamp: FileStamp
        var record: ModelRequest
    }
    private var cached: [URL: Cached] = [:]
    public init() {}
    public func load(root: URL) -> [ModelRequest] {
        let directory = root.appendingPathComponent("requests")
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        let live = Set(files)
        cached = cached.filter { live.contains($0.key) }
        for file in files {
            guard let stamp = FileStamp(file) else { continue }
            if let old = cached[file], old.stamp == stamp { continue }
            guard var value = try? ModelRequest.load(url: file) else { cached[file] = nil; continue }
            value.system = ""; value.input = ""; value.output = nil
            cached[file] = Cached(stamp: stamp, record: value)
        }
        return cached.values.map(\.record).sorted { $0.startedAt > $1.startedAt }
    }
}
