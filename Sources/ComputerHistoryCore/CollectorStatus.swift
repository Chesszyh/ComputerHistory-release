import Foundation

/// 采集器运行状态快照，供托盘应用展示。
public struct CollectorStatus: Sendable, Equatable {

    public struct ProcessInfo: Sendable, Equatable {
        public var running: Bool
        public var pid: Int32?
        /// 已运行时长（秒）。取不到启动时刻时为 nil。
        public var uptime: TimeInterval?
    }

    public struct DataStats: Sendable, Equatable {
        public var segmentCount: Int
        /// 已计数的事件总数。
        public var eventCount: Int
        /// 有文件未能计数时为 true。此时 `eventCount` 是**下界**，
        /// 展示方必须标注，不能当作准确值。
        public var eventCountIncomplete: Bool
        public var bytes: Int
        public var earliest: Date?
        public var latest: Date?
        /// 最新一个 segment 的时刻，用于判断是否仍在写入。
        public var lastWriteAt: Date?
        /// 已封口的段 ID（含 UUID 后缀的完整目录名）。
        /// 待补写量按它与已生成记忆的**集合差**计算，而不是拿两个总数相减。
        public var sealedSegmentIDs: [String]
    }

    public struct MemoryStats: Sendable, Equatable {
        public var count: Int
        public var tenMinuteCount: Int
        public var sixHourCount: Int
        /// 已封口但尚未生成记忆的段数。
        public var pendingSegments: Int
    }

    public var process: ProcessInfo
    public var data: DataStats
    public var memories: MemoryStats
    public var rootDirectory: URL
    public var awayReason: AwayPeriods.Reason? = nil

    /// 采集器是否仍在写入。超过一个段周期没有新事件即视为停滞——
    /// 进程活着但没有产出，与「没在用电脑」不同，值得提示。
    public var isStalled: Bool {
        guard process.running, awayReason == nil, let last = data.lastWriteAt else { return false }
        return Date().timeIntervalSince(last) > SegmentClock.durationSeconds * 2
    }

    /// 采集目录的默认位置。
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".computer-history")
    }

    /// 读取一次状态。全部为本地文件操作，不做网络请求。
    public static func read(root: URL = defaultRoot,
                            now: Date = Date(),
                            fileManager: FileManager = .default) -> CollectorStatus {
        let process = readProcess(root: root, fileManager: fileManager)
        let data = readData(root: root, fileManager: fileManager)
        let memories = readMemories(root: root, data: data, fileManager: fileManager)
        let away = AwayPeriods.load(root: root)
        return CollectorStatus(process: process, data: data,
                               memories: memories, rootDirectory: root,
                               awayReason: away.startedAt.map { _ in away.startedReason ?? .locked })
    }

    public static func empty(root: URL) -> CollectorStatus {
        CollectorStatus(process: .init(running: false, pid: nil, uptime: nil),
            data: .init(segmentCount: 0, eventCount: 0, eventCountIncomplete: false, bytes: 0,
                        earliest: nil, latest: nil, lastWriteAt: nil, sealedSegmentIDs: []),
            memories: .init(count: 0, tenMinuteCount: 0, sixHourCount: 0, pendingSegments: 0), rootDirectory: root)
    }

    static func readProcess(root: URL, fileManager: FileManager) -> ProcessInfo {
        // 以采集锁 + 进程身份判定，而不是仅看 pid 文件是否存在——
        // pid 会复用，文件也可能是上次崩溃留下的残留。
        guard let identity = CollectorProcessLease.runningIdentity(root: root) else {
            return ProcessInfo(running: false, pid: nil, uptime: nil)
        }
        let started = Date(timeIntervalSince1970:
            TimeInterval(identity.startedSeconds) + TimeInterval(identity.startedMicroseconds) / 1e6)
        return ProcessInfo(running: true, pid: identity.pid,
                           uptime: Date().timeIntervalSince(started))
    }

    static func readData(root: URL, fileManager: FileManager) -> DataStats {
        let segmentsDir = root.appendingPathComponent("segments")
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: segmentsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return DataStats(segmentCount: 0, eventCount: 0,
                             eventCountIncomplete: false, bytes: 0,
                             earliest: nil, latest: nil, lastWriteAt: nil,
                             sealedSegmentIDs: [])
        }

        var count = 0, events = 0, bytes = 0
        var incomplete = false
        var sealed: [String] = []
        var earliest: Date?, latest: Date?, lastWrite: Date?
        for dir in dirs {
            let eventsURL = EventArchive.eventsURL(in: dir)
            guard let attrs = try? fileManager.attributesOfItem(atPath: eventsURL.path)
            else { continue }
            count += 1
            // 只有封口（metadata 存在）的段才计入待补写判断——正在写入的段
            // 生成记忆会漏掉后续内容。
            if fileManager.fileExists(
                atPath: dir.appendingPathComponent("metadata.json").path) {
                sealed.append(dir.lastPathComponent)
            }
            bytes += (attrs[.size] as? Int) ?? 0
            let sealedMetadata = try? EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
                from: Data(contentsOf: dir.appendingPathComponent("metadata.json")))
            let modified = eventsURL.pathExtension == "gz" ? (sealedMetadata?.endedAt ?? attrs[.modificationDate] as? Date) : attrs[.modificationDate] as? Date
            if let modified {
                if lastWrite == nil || modified > lastWrite! { lastWrite = modified }
            }
            if let started = SegmentClock.date(
                fromSegmentID: dir.lastPathComponent.split(separator: "_").first
                    .map(String.init) ?? dir.lastPathComponent) {
                if earliest == nil || started < earliest! { earliest = started }
                if latest == nil || started > latest! { latest = started }
            }
            // 逐块计行，不设大小上限——按大小跳过会静默漏计（实测漏掉三份
            // 大于 8 MiB 的文件，把 8173 条报成 7034 条）。只把整数加一，
            // 不保留字符串，内存与文件大小无关。
            if let counted = sealedMetadata?.eventCount ?? Self.countLines(at: eventsURL) {
                events += counted
            } else {
                incomplete = true
            }
        }
        return DataStats(segmentCount: count, eventCount: events,
                         eventCountIncomplete: incomplete, bytes: bytes,
                         earliest: earliest, latest: latest, lastWriteAt: lastWrite,
                         sealedSegmentIDs: sealed)
    }

    /// 流式统计行数。文件读不到时返回 nil，由调用方标记为不完整。
    static func countLines(at url: URL) -> Int? {
        try? EventArchive.withReader(at: url) { handle in
            var lines = 0
            var lastByte: UInt8 = 10
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                lines += chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                lastByte = chunk.last ?? lastByte
            }
            return lines + (lastByte == 10 ? 0 : 1)
        }
    }

    static func readMemories(root: URL, data: DataStats,
                             fileManager: FileManager) -> MemoryStats {
        let index = MemoryIndex.load(from: root.appendingPathComponent("memories"))
        return memoryStats(index: index, data: data)
    }

    static func memoryStats(index: MemoryIndex, data: DataStats) -> MemoryStats {
        let ten = index.entries.filter { $0.granularity == "10min" }.count
        let six = index.entries.filter { $0.granularity == "6h" }.count
        // 待补写量按**真实集合差**计算：已封口的段中尚无十分钟记忆的那些。
        // 不能用「段数 − 记忆数」，同窗重启会让两者口径不同。
        let produced = Set(index.entries.filter { $0.granularity == "10min" && $0.generationStatus != "failed" }
            .map { $0.sourceSegmentID })
        return MemoryStats(count: index.entries.count, tenMinuteCount: ten,
                           sixHourCount: six,
                           pendingSegments: max(0, data.sealedSegmentIDs.count - produced.intersection(data.sealedSegmentIDs).count))
    }

    // MARK: - 展示

    public func uptimeLabel() -> String {
        guard let uptime = process.uptime else { return "—" }
        let seconds = Int(uptime)
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }

    public func sizeLabel() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(data.bytes))
    }
}
