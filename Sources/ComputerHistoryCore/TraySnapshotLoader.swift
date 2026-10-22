import Foundation

public struct TrayTimelineItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var timestamp: Date
    public var title: String
    public var summary: String
    public var apps: [String]
    public var isNarrative: Bool
    public var memoryFiles: [URL]
    public var coveredCount: Int
    public var eventCount: Int?
    public var endTimestamp: Date
    public var isAway: Bool = false
    public var deletionID: String { (isNarrative ? "narrative:" : "memory:") + id }
    public var hasDetail: Bool { !memoryFiles.isEmpty }
}

public struct TrayTimelineGroup: Sendable, Equatable {
    public var day: String
    public var items: [TrayTimelineItem]
    public init(day: String, items: [TrayTimelineItem]) { self.day = day; self.items = items }
}

public struct TraySnapshot: Sendable {
    public var status: CollectorStatus
    public var control: CollectorControl
    public var groups: [TrayTimelineGroup]
    public var contentVersion: Int
    public var deletedSummaries: [TimelineDeletions.Record]
    /// 本轮实际读取的事件字节与解析的记忆数，用于固定数据性能验证。
    public var eventBytesRead: Int
    public var memoriesParsed: Int
}

/// 独立 actor 提供串行磁盘执行边界；快照只携带展示字段，不携带历史正文。
public actor TraySnapshotLoader {
    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Date
        var inode: UInt64
    }
    private struct Counter {
        var stamp: Stamp
        var offset: UInt64
        var newlines: Int
        var trailing: Bool
        var count: Int { newlines + (trailing ? 1 : 0) }
    }
    private var counters: [URL: Counter] = [:]
    private var sealedCounts: [URL: (events: Stamp, metadata: Stamp, count: Int)] = [:]
    private var memories: [URL: (stamp: Stamp, entry: MemoryIndex.Entry?)] = [:]
    private var narrativeStamp: Stamp?
    private var narrative = ActivityNarrative()
    private var previousTimelineEntries: [TimelineSource] = []
    private var previousNarrative: [ActivityNarrative.Item] = []
    private var previousDeletions = TimelineDeletions()
    private var previousAway = AwayPeriods()
    private var previousTimeZone: TimeZone?
    private var groups: [TrayTimelineGroup] = []
    private var deletedSummaries: [TimelineDeletions.Record] = []
    private var contentVersion = 0

    private struct TimelineSource: Equatable {
        var url: URL
        var date: Date
        var title: String
        var summary: String
        var apps: [String]
    }

    public init() {}

    private func stamp(_ url: URL) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Stamp(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                     modified: modified, inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    public func load(root: URL, timeZone: TimeZone = .current) -> TraySnapshot {
        let fm = FileManager.default
        var bytesRead = 0, parsed = 0
        let segmentsDirectory = root.appendingPathComponent("segments")
        var incomplete = false
        let dirs: [URL]
        do {
            dirs = try fm.contentsOfDirectory(at: segmentsDirectory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            dirs = []
            incomplete = fm.fileExists(atPath: segmentsDirectory.path)
        }
        var events = 0, bytes = 0, count = 0
        var sealed: [String] = []
        var earliest: Date?, latest: Date?, lastWrite: Date?
        var seen: Set<URL> = []
        for dir in dirs {
            let url = EventArchive.eventsURL(in: dir)
            guard let current = stamp(url) else {
                if SegmentClock.date(fromSegmentID: dir.lastPathComponent) != nil { incomplete = true }
                continue
            }
            seen.insert(url)
            count += 1
            bytes += Int(current.size)
            let metadata = try? EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
                from: Data(contentsOf: dir.appendingPathComponent("metadata.json")))
            let written = url.pathExtension == "gz" ? (metadata?.endedAt ?? current.modified) : current.modified
            lastWrite = max(lastWrite ?? written, written)
            if let date = SegmentClock.date(fromSegmentID: dir.lastPathComponent) {
                earliest = min(earliest ?? date, date)
                latest = max(latest ?? date, date)
            }
            let metadataURL = dir.appendingPathComponent("metadata.json")
            if let metadataStamp = stamp(metadataURL) {
                sealed.append(dir.lastPathComponent)
                if let cached = sealedCounts[url], cached.events == current, cached.metadata == metadataStamp {
                    events += cached.count
                    continue
                }
                if let data = try? Data(contentsOf: metadataURL),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = object["eventCount"] as? Int, value >= 0 {
                    sealedCounts[url] = (current, metadataStamp, value)
                    counters[url] = nil
                    events += value
                    continue
                }
            } else { sealedCounts[url] = nil }
            if url.pathExtension == "gz" {
                if let cached = counters[url], cached.stamp == current { events += cached.count }
                else if let counted = CollectorStatus.countLines(at: url) {
                    counters[url] = Counter(stamp: current, offset: current.size, newlines: counted, trailing: false)
                    events += counted
                } else { incomplete = true }
                continue
            }
            if let cached = counters[url], cached.stamp == current {
                events += cached.count
                continue
            }
            var counter = counters[url]
            // 追加仅在同一文件且尺寸增长时复用游标；截断、替换、同尺寸重写重新计数。
            if counter == nil || counter!.stamp.inode != current.inode || current.size <= counter!.offset {
                counter = Counter(stamp: current, offset: 0, newlines: 0, trailing: false)
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: counter!.offset)
                while counter!.offset < current.size {
                    let amount = min(UInt64(1 << 20), current.size - counter!.offset)
                    guard let data = try handle.read(upToCount: Int(amount)), !data.isEmpty else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    bytesRead += data.count
                    counter!.offset += UInt64(data.count)
                    counter!.newlines += data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                    counter!.trailing = data.last != 10
                }
                counter!.stamp = current
                counters[url] = counter
                events += counter!.count
            } catch { incomplete = true; counters[url] = nil }
        }
        counters = counters.filter { seen.contains($0.key) }
        sealedCounts = sealedCounts.filter { seen.contains($0.key) }
        let files = ((try? fm.contentsOfDirectory(at: root.appendingPathComponent("memories"),
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension == "md" }
        let fileSet = Set(files)
        let removedMemories = memories.keys.contains { !fileSet.contains($0) }
        memories = memories.filter { fileSet.contains($0.key) }
        for file in files {
            guard let current = stamp(file) else { memories[file] = nil; continue }
            if memories[file]?.stamp == current { continue }
            parsed += 1
            var entry = MemoryIndex.parse(fileURL: file)
            entry?.body = ""
            entry?.sections = []
            memories[file] = (current, entry)
        }
        let index = MemoryIndex(entries: memories.values.compactMap(\.entry).sorted { $0.startedAt > $1.startedAt })
        let nStamp = stamp(ActivityNarrative.fileURL(root: root))
        let narrativeChanged = nStamp != narrativeStamp
        if narrativeChanged {
            narrative = ActivityNarrative.load(root: root)
            narrativeStamp = nStamp
        }
        if parsed > 0 || removedMemories || narrativeChanged { contentVersion += 1 }
        let sources = index.entries.map { TimelineSource(url: $0.fileURL, date: $0.startedAt,
                                           title: $0.title, summary: $0.summary, apps: $0.applications) }
        let deletions = (try? TimelineDeletions.load(root: root)) ?? previousDeletions
        let away = AwayPeriods.load(root: root)
        if away != previousAway || deletions != previousDeletions { contentVersion += 1 }
        if deletions != previousDeletions || away != previousAway || sources != previousTimelineEntries || narrative.items != previousNarrative || previousTimeZone != timeZone {
            let allGroups = Self.timeline(index: index, narrative: narrative, away: away, restored: deletions.restoredItems, timeZone: timeZone)
            deletedSummaries = deletions.trashEntries(candidates: allGroups.flatMap(\.items))
            let aliases = Dictionary(narrative.items.map { ($0.id, $0.previousIDs ?? []) }, uniquingKeysWith: { first, _ in first })
            groups = allGroups.compactMap { group in
                let items = group.items.filter { item in
                    !deletions.ids.contains(item.deletionID)
                        && !(aliases[item.id] ?? []).contains { deletions.ids.contains("narrative:" + $0) }
                }
                return items.isEmpty ? nil : TrayTimelineGroup(day: group.day, items: items)
            }
            previousDeletions = deletions
            previousTimelineEntries = sources
            previousNarrative = narrative.items
            previousTimeZone = timeZone
            previousAway = away
        }
        let data = CollectorStatus.DataStats(segmentCount: count, eventCount: events,
                    eventCountIncomplete: incomplete, bytes: bytes, earliest: earliest, latest: latest,
                    lastWriteAt: lastWrite, sealedSegmentIDs: sealed)
        let status = CollectorStatus(process: CollectorStatus.readProcess(root: root, fileManager: fm), data: data,
                     memories: CollectorStatus.memoryStats(index: index, data: data), rootDirectory: root)
        return TraySnapshot(status: status, control: CollectorControl.load(root: root), groups: groups,
                            contentVersion: contentVersion, deletedSummaries: deletedSummaries, eventBytesRead: bytesRead, memoriesParsed: parsed)
    }

    private static func timeline(index: MemoryIndex, narrative: ActivityNarrative, away: AwayPeriods, restored: [TrayTimelineItem],
                                 timeZone: TimeZone) -> [TrayTimelineGroup] {
        let lookup = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.id, $0.fileURL) })
        var covered = Set(restored.filter(\.isNarrative).flatMap { $0.memoryFiles.map(\.lastPathComponent) })
        var byDay: [String: [TrayTimelineItem]] = [:]
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = timeZone
        date.dateFormat = "yyyy-MM-dd"
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        stamp.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        for item in narrative.items {
            covered.formUnion(item.sourceMemories)
            guard item.apps != ["com.apple.loginwindow"] else { continue }
            byDay[date.string(from: item.timestamp), default: []].append(TrayTimelineItem(
                id: item.id, timestamp: item.timestamp, title: item.title, summary: item.summary,
                apps: item.apps, isNarrative: true, memoryFiles: item.sourceMemories.compactMap { lookup[$0] },
                coveredCount: max(1, item.sourceMemories.count), eventCount: nil,
                endTimestamp: item.sourceMemories.compactMap { stamp.date(from: String($0.prefix(20))) }.max() ?? item.timestamp))
        }
        for entry in index.entries where !covered.contains(entry.id) && entry.applications != ["com.apple.loginwindow"] {
            byDay[date.string(from: entry.startedAt), default: []].append(TrayTimelineItem(
                id: entry.id, timestamp: entry.startedAt, title: entry.title, summary: entry.summary,
                apps: entry.applications, isNarrative: false, memoryFiles: [entry.fileURL],
                coveredCount: 1, eventCount: nil, endTimestamp: entry.startedAt))
        }
        let existingIDs = Set(byDay.values.flatMap { $0 }.map(\.deletionID))
            .union(narrative.items.flatMap { ($0.previousIDs ?? []).map { "narrative:" + $0 } })
        for item in restored where !existingIDs.contains(item.deletionID) {
            byDay[date.string(from: item.timestamp), default: []].append(item)
        }
        for period in away.periods where period.end.timeIntervalSince(period.start) >= 60 {
            byDay[date.string(from: period.start), default: []].append(TrayTimelineItem(
                id: "away-\(period.start.timeIntervalSince1970)", timestamp: period.start,
                title: "离开电脑", summary: "登录界面", apps: [],
                isNarrative: false, memoryFiles: [], coveredCount: 1, eventCount: nil,
                endTimestamp: period.end, isAway: true))
        }
        return byDay.keys.sorted(by: >).map { day in
            TrayTimelineGroup(day: day, items: byDay[day]!.sorted { $0.timestamp > $1.timestamp })
        }
    }
}

/// 界面刷新请求合并：运行中最多保留一次后续刷新。
public struct TrayRefreshState: Sendable {
    private var loading = false
    private var pending = false
    public init() {}
    public mutating func request() -> Bool {
        if loading { pending = true; return false }
        loading = true
        return true
    }
    public mutating func finished() -> Bool {
        if pending { pending = false; return true }
        loading = false
        return false
    }
    public mutating func cancel() { loading = false; pending = false }
}
