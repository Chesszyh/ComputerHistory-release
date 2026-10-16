import Foundation
import Darwin

/// 段元数据；firstEventAt 是本项目增加的排序字段，旧文件缺失时从事件读取。
public struct EventStreamMetadata: Codable, Sendable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    /// 正常 10 分钟滚动切分不写该字段——88/88 段实测均无。
    /// 仅异常/显式终止路径写入（取值见 EventStreamEndReason）。
    public var endReason: String?
    public var eventCount: Int
    public var suppressedEventCount: Int
    /// 服务端写的是**写入时的绝对路径**，样本从原容器复制后该字段仍指向旧路径。
    /// 读取方不得信任此字段，应以 metadata.json 所在目录推导 events.jsonl。
    public var eventsPath: String
    public var firstEventAt: Date? = nil
}

/// 录制结束原因。取值来自反汇编 `ComputerUseIPCEventStreamEndReason.rawValue.getter`。
public enum EventStreamEndReason: String, Sendable {
    case stopped = "stopped"
    case recordingControlsStopped = "recording_controls_stopped"
    case recordingControlsCancelled = "recording_controls_cancelled"
    case serviceTerminated = "service_terminated"
    case maxDuration = "max_duration"
    case debugUIStopped = "debug_ui_stopped"
}

/// Segment 目录命名与切分。
///
/// 实测：86/88 段时长恰为 600 秒，`startedAt` 对齐到 10 分钟边界。
/// 注意段内首个事件的 timestamp 通常**晚于** startedAt——段是按钟表预创建的，
/// 只在有事件时才写入。
public enum SegmentClock {
    public static let durationSeconds: TimeInterval = 600

    /// 时间戳前缀格式 `YYYY-MM-DDTHH-MM-SSZ`；目录冲突时写入器追加 UUID。
    public static func segmentID(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// 从目录名还原 segment 的起始时刻；格式不符时返回 nil。
    ///
    /// 保留策略据此判断超龄——目录名是采集时写入的权威时间，
    /// 而文件修改时间在复制、恢复、备份后会失真。
    public static func date(fromSegmentID id: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && UUID(uuidString: String(parts[1])) != nil),
              parts[0].count == 20,
              let date = f.date(from: String(parts[0])),
              segmentID(for: date) == String(parts[0]) else { return nil }
        return date
    }

    /// 把时刻向下对齐到 10 分钟边界。
    public static func alignedStart(for date: Date) -> Date {
        let epoch = date.timeIntervalSince1970
        let aligned = (epoch / durationSeconds).rounded(.down) * durationSeconds
        return Date(timeIntervalSince1970: aligned)
    }

    public static func isExpired(_ start: Date, now: Date) -> Bool {
        now.timeIntervalSince(start) >= durationSeconds
    }
}

/// 单个 segment 的 JSONL 写入器。
///
/// 与官方一致：事件逐行追加到 events.jsonl；被抑制的事件**不写主文件**，
/// 只累加计数（官方另有可选的 suppressedEvents 文件，本实现暂不产出以保持
/// 与样本一致的目录布局——88/88 段只有 2 个文件）。
public final class SegmentWriter {
    public let directoryURL: URL
    public let eventsURL: URL
    public let metadataURL: URL
    public let segmentID: String
    public let startedAt: Date

    private var handle: FileHandle?
    private var firstEventAt: Date?
    private var eventCount = 0
    private var suppressedCount = 0
    private var closed = false

    /// 样本 metadata.json 是 pretty-printed 且键序固定；用 sortedKeys 保证字节可复现。
    /// 每次构造而非静态持有：`JSONEncoder` 不是 `Sendable`。
    private static func makeMetadataEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(EventStreamJSON.timestampString(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public init(rootDirectoryURL: URL, start: Date) throws {
        let aligned = SegmentClock.alignedStart(for: start)
        let baseID = SegmentClock.segmentID(for: aligned)
        let segments = rootDirectoryURL.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        var id = baseID
        while mkdir(segments.appendingPathComponent(id).path, 0o700) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            id = baseID + "_" + UUID().uuidString
        }
        self.segmentID = id
        self.startedAt = aligned
        self.directoryURL = rootDirectoryURL
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        self.eventsURL = directoryURL.appendingPathComponent("events.jsonl")
        self.metadataURL = directoryURL.appendingPathComponent("metadata.json")

        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        // 目录已独占创建，每个会话的编号与元数据保持独立。
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: eventsURL.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        self.handle = h
    }

    public func append(_ record: EventStreamRecord) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        let encoder = EventStreamJSON.makeEncoder()
        var data = try encoder.encode(record)
        data.append(0x0A)  // JSONL：每行一个对象
        try handle.write(contentsOf: data)
        if firstEventAt == nil { firstEventAt = record.timestamp }
        eventCount += 1
    }

    /// 命中抑制策略的事件只计数、不落主文件。
    public func noteSuppressed() {
        suppressedCount += 1
    }

    /// 写出 metadata.json 并关闭句柄。可重复调用（幂等）。
    public func close(endedAt: Date?, endReason: EventStreamEndReason? = nil) throws {
        guard !closed else { return }
        try handle?.close()
        handle = nil

        let meta = EventStreamMetadata(
            id: segmentID,
            startedAt: startedAt,
            endedAt: endedAt,
            endReason: endReason?.rawValue,
            eventCount: eventCount,
            suppressedEventCount: suppressedCount,
            // 与官方一致，写绝对路径；读取方以目录位置为准。
            eventsPath: eventsURL.path,
            firstEventAt: firstEventAt
        )
        let data = try Self.makeMetadataEncoder().encode(meta)
        try data.write(to: metadataURL, options: .atomic)
        closed = true
    }

    public var counts: (events: Int, suppressed: Int) {
        (eventCount, suppressedCount)
    }
}
