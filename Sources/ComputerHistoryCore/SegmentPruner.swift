import Foundation

/// 落盘保留：按总字节数与天数清理旧 segment。
///
/// 长期后台运行必须管磁盘——实测约 1.3 MB/分钟（≈1.9 GB/天），不限制会填满磁盘。
/// 清理是**按整个 segment 删除**，不做部分裁剪：半个 events.jsonl 无法解析，
/// 留着只会让读取方困惑。
public enum SegmentPruner {

    /// 执行清理。返回删除统计。
    ///
    /// 顺序：先按天数删超龄的，再按总量从旧到新删到达标。
    /// 两条硬约束：
    ///   - 显式保护活动 segment；未指定时保留排序最后的一个；
    ///   - 目录名解析不出时间的**不删**。那可能是使用者自己放进来的内容，
    ///     不归本清理管。
    @discardableResult
    public static func prune(
        rootDirectory: URL,
        retention: CollectorConfig.Retention,
        now: Date = Date(),
        activeSegmentID: String? = nil,
        fileManager: FileManager = .default
    ) -> PruneReport {
        var report = PruneReport()
        let segmentsDir = rootDirectory.appendingPathComponent("segments")
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: segmentsDir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            report.failures.append(.init(directory: segmentsDir, operation: .list,
                                         message: error.localizedDescription))
            return report
        }

        // 文件修改时间在复制或恢复后会失真；同段使用首条事件时间，
        // 无法区分时按目录名确定顺序，不把 UUID 当作创建时间。
        let candidates: [(url: URL, started: Date, firstEvent: Date)] = entries.compactMap { url in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue,
                  let started = SegmentClock.date(fromSegmentID: url.lastPathComponent)
            else { return nil }
            return (url, started, firstEventDate(in: url, started: started) ?? started)
        }.sorted {
            if $0.started != $1.started { return $0.started < $1.started }
            if $0.firstEvent != $1.firstEvent { return $0.firstEvent < $1.firstEvent }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        func noteFailure(_ url: URL, operation: PruneReport.Failure.Operation, error: Error) {
            guard !report.failures.contains(where: { $0.directory == url && $0.operation == operation }) else { return }
            report.failures.append(.init(directory: url, operation: operation,
                                         message: error.localizedDescription))
        }

        func size(of url: URL) -> Int? {
            do {
                let files = try fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)
                return try files.reduce(0) { sum, file in
                    let attributes = try fileManager.attributesOfItem(atPath: file.path)
                    guard let bytes = attributes[.size] as? NSNumber else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    return sum + bytes.intValue
                }
            } catch {
                noteFailure(url, operation: .measure, error: error)
                return nil
            }
        }

        let sizes = Dictionary(uniqueKeysWithValues: candidates.compactMap { item in
            size(of: item.url).map { (item.url, $0) }
        })
        var total: Int? = sizes.count == candidates.count ? sizes.values.reduce(0, +) : nil
        guard let newest = candidates.first(where: { $0.url.lastPathComponent == activeSegmentID })
                ?? candidates.last else {
            report.remainingBytes = total
            return report
        }
        let removable = candidates.filter { $0.url != newest.url }
        func summarized(_ item: URL) -> Bool {
            let memory = rootDirectory.appendingPathComponent("memories")
                .appendingPathComponent(MemoryWriter.fileName(segmentID: item.lastPathComponent))
            guard let text = try? String(contentsOf: memory, encoding: .utf8) else { return false }
            return !text.contains("\ngeneration: failed\n") && !text.contains("本节未由语言模型归纳：")
        }
        let hasSummary = Dictionary(uniqueKeysWithValues: removable.map { ($0.url, summarized($0.url)) })
        var attempted: Set<URL> = []
        var removed: Set<URL> = []

        func remove(_ url: URL) {
            guard let bytes = sizes[url], attempted.insert(url).inserted else { return }
            do {
                try fileManager.removeItem(at: url)
                removed.insert(url)
                report.removedSegments += 1
                if hasSummary[url] != true { report.removedWithoutSummary += 1 }
                report.freedBytes += bytes
                total = total.map { $0 - bytes }
            } catch {
                noteFailure(url, operation: .remove, error: error)
            }
        }

        if retention.maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retention.maxAgeDays) * 86_400)
            for item in removable where item.started < cutoff {
                let grace = retention.unsummarizedMaxAgeDays
                if hasSummary[item.url] != true, grace > retention.maxAgeDays,
                   item.started >= now.addingTimeInterval(-Double(grace) * 86_400) { continue }
                remove(item.url)
            }
        }

        // 读取不完整时无法判断是否超量；不能用缺失的字节数指导删除。
        if retention.maxTotalBytes > 0 {
            let priority = removable.filter { hasSummary[$0.url] == true } + removable.filter { hasSummary[$0.url] != true }
            for item in priority {
                guard let bytes = total, bytes > retention.maxTotalBytes else { break }
                remove(item.url)
            }
        }

        // 删除失败可能已部分移除内容，最终报告重新读取仍在磁盘上的文件。
        var remaining = 0
        var complete = true
        for item in candidates where !removed.contains(item.url) {
            if let bytes = size(of: item.url) { remaining += bytes } else { complete = false }
        }
        report.remainingBytes = complete ? remaining : nil
        return report
    }

    private static func firstEventDate(in directory: URL, started: Date) -> Date? {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
           let meta = try? EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self, from: data),
           let first = meta.firstEventAt, first >= started,
           first < started.addingTimeInterval(SegmentClock.durationSeconds) { return first }
        guard let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("events.jsonl")) else { return nil }
        defer { try? handle.close() }
        // 只读取首条完整记录；损坏的大文件不能让清理扫描无限占用内存。
        let limit = 1_048_576
        var line = Data()
        do {
            while line.count < limit {
                guard let chunk = try handle.read(upToCount: min(4096, limit - line.count)), !chunk.isEmpty else { return nil }
                if let newline = chunk.firstIndex(of: 0x0A) {
                    line.append(contentsOf: chunk[..<newline])
                    guard let event = try? EventStreamJSON.makeDecoder().decode(EventStreamRecord.self, from: line),
                          event.timestamp >= started,
                          event.timestamp < started.addingTimeInterval(SegmentClock.durationSeconds) else { return nil }
                    return event.timestamp
                }
                line.append(chunk)
            }
        } catch { return nil }
        return nil
    }
}
