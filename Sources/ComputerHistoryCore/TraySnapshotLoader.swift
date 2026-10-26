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
    public var manualEdit: Bool? = nil
    public var sourceActivities: [String: [Int]]? = nil
    public var sourceSteps: [String: [Int]]? = nil
    public var sourceIncidental: [String: [Int]]? = nil
    public var sharesSourcePeriod: Bool? = nil
    public var children: [TrayTimelineItem]? = nil
    public var noClearActivity: Bool? = nil
    public var leafItems: [TrayTimelineItem] { children?.flatMap(\.leafItems) ?? [self] }
    public var incidentalCount: Int { sourceIncidental?.values.reduce(0) { $0 + $1.count } ?? 0 }
    public var isIncidentalOnly: Bool {
        guard let activities = sourceActivities, !activities.isEmpty else { return false }
        return activities.allSatisfy { name, numbers in Set(numbers).isSubset(of: sourceIncidental?[name] ?? []) }
    }
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
    public var timelineMode: SummarySettings.TimelineMode
    public var deletedSummaries: [TimelineDeletions.Record]
    /// 本轮实际读取的事件字节与解析的记忆数，用于固定数据性能验证。
    public var eventBytesRead: Int
    public var memoriesParsed: Int
}

/// 独立 actor 提供串行磁盘执行边界；快照只携带展示字段，不携带历史正文。
public actor TraySnapshotLoader {
    private typealias Stamp = FileStamp
    private struct Counter {
        var stamp: Stamp
        var offset: UInt64
        var newlines: Int
        var trailing: Bool
        var count: Int { newlines + (trailing ? 1 : 0) }
    }
    private var counters: [URL: Counter] = [:]
    private var sealedCounts: [URL: (events: Stamp, metadata: Stamp, count: Int)] = [:]
    private var memories: [URL: (stamp: Stamp, metadata: Stamp?, entry: MemoryIndex.Entry?)] = [:]
    private var narrativeStamp: Stamp?
    private var narrative = ActivityNarrative()
    private var previousTimelineEntries: [TimelineSource] = []
    private var previousNarrative: [ActivityNarrative.Item] = []
    private var previousDeletions = TimelineDeletions()
    private var previousAway = AwayPeriods()
    private var previousTimeZone: TimeZone?
    private var previousEdits = TimelineEdits()
    private var previousTimelineMode: SummarySettings.TimelineMode?
    private var groups: [TrayTimelineGroup] = []
    private var deletedSummaries: [TimelineDeletions.Record] = []
    private var contentVersion = 0

    private struct TimelineSource: Equatable {
        var url: URL
        var date: Date
        var firstEventAt: Date?
        var endedAt: Date?
        var title: String
        var summary: String
        var apps: [String]
        var activityFragmentCount: Int?
    }

    public init() {}

    private static func activityPresentation(_ entry: MemoryIndex.Entry) -> MemoryIndex.Entry {
        if entry.noClearActivity {
            var result = entry
            result.title = ActivityEvidence.noActivityTitle
            result.summary = ActivityEvidence.noActivitySummary
            result.activityFragmentCount = 1
            return result
        }
        let activity = entry.sections.filter { ["本次活动", "整体走向", "延续的工作线"].contains($0.heading) }
            .map(\.content).joined(separator: "\n\n")
        guard !activity.isEmpty else { return entry }
        var result = entry
        result.activityFragmentCount = ActivityFragment.fragments(in: entry).count
        result.summary = String(ActivityExport.formatted(activity, format: "txt").prefix(1800))
        if let first = activity.split(separator: "\n").first,
           let heading = first.range(of: #"^(?:[-*] )?\*\*[^*]+\*\*"#, options: .regularExpression) {
            result.title = ActivityFragment.title(String(first[heading]).replacingOccurrences(of: #"^[-*] "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: ""))
        }
        return result
    }

    private func stamp(_ url: URL) -> Stamp? { FileStamp(url) }

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
            let metadata = memories[file]?.entry.flatMap {
                stamp(root.appendingPathComponent("segments/\($0.sourceSegmentID)/metadata.json"))
            }
            if memories[file]?.stamp == current, memories[file]?.metadata == metadata { continue }
            parsed += 1
            var entry = MemoryIndex.parse(fileURL: file).map(Self.activityPresentation)
            entry?.body = ""
            entry?.sections = []
            memories[file] = (current, entry.flatMap {
                stamp(root.appendingPathComponent("segments/\($0.sourceSegmentID)/metadata.json"))
            }, entry)
        }
        let index = MemoryIndex(entries: memories.values.compactMap(\.entry).sorted { $0.startedAt > $1.startedAt })
        let nStamp = stamp(ActivityNarrative.fileURL(root: root))
        let narrativeChanged = nStamp != narrativeStamp
        if narrativeChanged {
            narrative = ActivityNarrative.load(root: root)
            narrativeStamp = nStamp
        }
        if parsed > 0 || removedMemories || narrativeChanged { contentVersion += 1 }
        let sources = index.entries.map { TimelineSource(url: $0.fileURL, date: $0.startedAt, firstEventAt: $0.firstEventAt, endedAt: $0.endedAt,
                                           title: $0.title, summary: $0.summary, apps: $0.applications, activityFragmentCount: $0.activityFragmentCount) }
        let deletions = (try? TimelineDeletions.load(root: root)) ?? previousDeletions
        let away = AwayPeriods.load(root: root)
        let mode = (try? SummarySettings.load(root: root))?.timelineMode ?? previousTimelineMode ?? .continuous
        let edits = (try? TimelineEdits.load(root: root)) ?? previousEdits
        if edits != previousEdits { contentVersion += 1 }
        if away != previousAway || deletions != previousDeletions { contentVersion += 1 }
        if edits != previousEdits || deletions != previousDeletions || away != previousAway || sources != previousTimelineEntries || narrative.items != previousNarrative || previousTimeZone != timeZone || previousTimelineMode != mode {
            if previousTimelineMode != mode { contentVersion += 1 }
            var displayNarrative = narrative
            let lookup = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.id, $0) })
            // Split placeholders have aliases but no revisions. Their frontmatter statistics are
            // not an activity summary; keep completed model narratives untouched.
            for i in displayNarrative.items.indices where displayNarrative.items[i].sourceRevisions == nil
                && !(displayNarrative.items[i].previousIDs ?? []).isEmpty {
                let entries = displayNarrative.items[i].sourceMemories.compactMap { lookup[$0] }
                guard let first = entries.first, entries.count == displayNarrative.items[i].sourceMemories.count else { continue }
                displayNarrative.items[i].title = first.title
                displayNarrative.items[i].summary = entries.map(\.summary)
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n\n")
            }
            displayNarrative = displayNarrative.separatingAwayPeriods(index: index, away: away, mode: mode)
            let allGroups = Self.timeline(index: index, narrative: displayNarrative, away: away, restored: deletions.restoredItems, timeZone: timeZone, mode: mode)
            deletedSummaries = deletions.trashEntries(candidates: allGroups.flatMap(\.items))
            let aliases = Dictionary(displayNarrative.items.map { ($0.id, $0.previousIDs ?? []) }, uniquingKeysWith: { first, _ in first })
            groups = allGroups.compactMap { group in
                var items = group.items.filter { item in
                    !deletions.ids.contains(item.deletionID)
                        && !(aliases[item.id] ?? []).contains { deletions.ids.contains("narrative:" + $0) }
                }
                if mode == .fixedTenMinutes {
                    for i in items.indices where !items[i].isAway && items[i].memoryFiles.count == 1 {
                        if let edit = edits.entries[items[i].memoryFiles[0].lastPathComponent] {
                            items[i].title = edit.title
                            items[i].summary = edit.summary
                            items[i].manualEdit = true
                        }
                    }
                }
                return items.isEmpty ? nil : TrayTimelineGroup(day: group.day, items: items)
            }
            let cards = TimelineLayout.cards(groups.flatMap(\.items))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            let days = Dictionary(grouping: cards, by: { formatter.string(from: $0.timestamp) })
            groups = days.keys.sorted(by: >).map { TrayTimelineGroup(day: $0, items: days[$0]!) }
            previousEdits = edits
            previousDeletions = deletions
            previousTimelineEntries = sources
            previousNarrative = narrative.items
            previousTimeZone = timeZone
            previousTimelineMode = mode
            previousAway = away
        }
        let data = CollectorStatus.DataStats(segmentCount: count, eventCount: events,
                    eventCountIncomplete: incomplete, bytes: bytes, earliest: earliest, latest: latest,
                    lastWriteAt: lastWrite, sealedSegmentIDs: sealed)
        let status = CollectorStatus(process: CollectorStatus.readProcess(root: root, fileManager: fm), data: data,
                     memories: CollectorStatus.memoryStats(index: index, data: data), rootDirectory: root,
                     awayReason: away.startedAt.map { _ in away.startedReason ?? .locked })
        return TraySnapshot(status: status, control: CollectorControl.load(root: root),
                            groups: Self.addingOpenAway(to: groups, away: away, timeZone: timeZone),
                            contentVersion: contentVersion, timelineMode: mode, deletedSummaries: deletedSummaries, eventBytesRead: bytesRead, memoriesParsed: parsed)
    }

    private static func addingOpenAway(to groups: [TrayTimelineGroup], away: AwayPeriods,
                                       timeZone: TimeZone) -> [TrayTimelineGroup] {
        let now = Date()
        guard let start = away.startedAt, now.timeIntervalSince(start) >= 60 else { return groups }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        // The visible endpoint changes by the minute; it must not invalidate historical sources.
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        let item = TrayTimelineItem(id: "away-\(start.timeIntervalSince1970)", timestamp: start,
            title: away.startedReason == .idle ? "用户离开电脑" : "离开电脑",
            summary: (away.startedReason ?? .locked).summary, apps: [], isNarrative: false,
            memoryFiles: [], coveredCount: 1, eventCount: nil, endTimestamp: max(start, end), isAway: true)
        let cards = TimelineLayout.cards(groups.flatMap(\.items) + [item])
        let days = Dictionary(grouping: cards, by: { formatter.string(from: $0.timestamp) })
        return days.keys.sorted(by: >).map { .init(day: $0, items: days[$0]!) }
    }

    private static func timeline(index: MemoryIndex, narrative: ActivityNarrative, away: AwayPeriods, restored: [TrayTimelineItem],
                                 timeZone: TimeZone, mode: SummarySettings.TimelineMode) -> [TrayTimelineGroup] {
        let lookup = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.id, $0) })
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
        var narrativeIDs: Set<String> = []
        func appendNarrative(_ item: ActivityNarrative.Item) {
            guard item.apps != ["com.apple.loginwindow"], narrativeIDs.insert(item.id).inserted else { return }
            let noClearActivity = !item.sourceMemories.isEmpty && item.sourceMemories.allSatisfy { lookup[$0]?.noClearActivity == true }
            var title = noClearActivity ? ActivityEvidence.noActivityTitle : ActivityFragment.title(item.title)
            if title == "期间的其他活动" {
                let fragment = item.sourceMemories.compactMap { name in
                    lookup[name].flatMap { MemoryIndex.parse(fileURL: $0.fileURL) }.flatMap { entry in
                        ActivityFragment.fragments(in: entry).first { item.sourceActivities?[name]?.contains($0.number) == true }
                    }
                }.first
                if let fragment {
                    let parts = fragment.text.components(separatedBy: "**")
                    title = ActivityFragment.title(parts.count >= 3 ? parts[1] : fragment.text)
                }
            }
            byDay[date.string(from: item.timestamp), default: []].append(TrayTimelineItem(
                id: item.id, timestamp: item.timestamp, title: title,
                summary: noClearActivity ? ActivityEvidence.noActivitySummary : item.summary,
                apps: item.apps, isNarrative: true, memoryFiles: item.sourceMemories.compactMap { lookup[$0]?.fileURL },
                coveredCount: max(1, item.sourceMemories.count), eventCount: nil,
                endTimestamp: max(item.timestamp, item.sourceMemories.compactMap { name in
                    lookup[name].map { away.activityEnd(for: $0) } ?? stamp.date(from: String(name.prefix(20)))
                }.max() ?? item.timestamp), sourceActivities: item.sourceActivities,
                sourceSteps: item.sourceSteps, sourceIncidental: nil,
                sharesSourcePeriod: item.sourceActivities?.contains { name, numbers in
                    lookup[name].map { numbers.count < ActivityFragment.count(in: $0) } ?? false
                }, noClearActivity: noClearActivity ? true : nil))
        }
        for item in narrative.items {
            covered.formUnion(item.sourceMemories)
            appendNarrative(item)
        }
        for entry in index.entries where entry.granularity == "10min" && !covered.contains(entry.id) && entry.applications != ["com.apple.loginwindow"] {
            let start = away.activityStart(for: entry)
            byDay[date.string(from: start), default: []].append(TrayTimelineItem(
                id: entry.id, timestamp: start, title: entry.title, summary: entry.summary,
                apps: entry.applications, isNarrative: false, memoryFiles: [entry.fileURL],
                coveredCount: 1, eventCount: nil, endTimestamp: away.activityEnd(for: entry),
                noClearActivity: entry.noClearActivity ? true : nil))
        }
        let existingIDs = Set(byDay.values.flatMap { $0 }.map(\.deletionID))
            .union(narrative.items.flatMap { ($0.previousIDs ?? []).map { "narrative:" + $0 } })
        for item in restored where !existingIDs.contains(item.deletionID) {
            if item.isNarrative {
                var restoredItem = ActivityNarrative.Item(id: item.id, timestamp: item.timestamp,
                    title: item.title, summary: item.summary, apps: item.apps,
                    sourceMemories: item.memoryFiles.map(\.lastPathComponent))
                restoredItem.sourceActivities = item.sourceActivities
                restoredItem.sourceSteps = item.sourceSteps
                restoredItem.sourceIncidental = item.sourceIncidental
                let restoredNarrative = ActivityNarrative(items: [restoredItem])
                    .separatingAwayPeriods(index: index, away: away, mode: mode)
                restoredNarrative.items.forEach(appendNarrative)
            } else { byDay[date.string(from: item.timestamp), default: []].append(item) }
        }
        for period in away.periods where period.end.timeIntervalSince(period.start) >= 60 {
            byDay[date.string(from: period.start), default: []].append(TrayTimelineItem(
                id: "away-\(period.start.timeIntervalSince1970)", timestamp: period.start,
                title: period.reason == .idle ? "用户离开电脑" : "离开电脑", summary: (period.reason ?? .locked).summary, apps: [],
                isNarrative: false, memoryFiles: [], coveredCount: 1, eventCount: nil,
                endTimestamp: period.end, isAway: true))
        }
        let chronological: [TrayTimelineItem] = byDay.values.flatMap { $0 }
        let days = Dictionary(grouping: chronological, by: { date.string(from: $0.timestamp) })
        return days.keys.sorted(by: >).map { day in
            TrayTimelineGroup(day: day, items: days[day]!)
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
