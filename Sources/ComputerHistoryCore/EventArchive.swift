import Foundation

/// 活动段保留 JSONL；封口段用系统 gzip 流式归档，读取端使用同一入口。
public enum EventArchive {
    public static func eventsURL(in directory: URL) -> URL {
        let plain = directory.appendingPathComponent("events.jsonl")
        if FileManager.default.fileExists(atPath: plain.path) { return plain }
        return directory.appendingPathComponent("events.jsonl.gz")
    }

    static func withReader<T>(at requested: URL, consumesEntireFile: Bool = true,
                              _ body: (FileHandle) throws -> T) throws -> T {
        let url = FileManager.default.fileExists(atPath: requested.path)
            ? requested : eventsURL(in: requested.deletingLastPathComponent())
        if url.pathExtension != "gz" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try body(handle)
        }
        let process = Process(), pipe = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        process.standardOutput = pipe; process.standardError = errors
        try process.run()
        do {
            let value = try body(pipe.fileHandleForReading)
            if !consumesEntireFile {
                if process.isRunning { process.terminate() }
                try? pipe.fileHandleForReading.close()
                process.waitUntilExit()
                return value
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ArchiveError.failed(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
            return value
        } catch {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
            process.waitUntilExit()
            throw error
        }
    }

    static func firstEvent(at url: URL) throws -> EventStreamRecord? {
        try withReader(at: url, consumesEntireFile: false) { handle in
            var line = Data()
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                if let newline = data.firstIndex(of: 10) {
                    line.append(data[..<newline])
                    return try? EventStreamJSON.makeDecoder().decode(EventStreamRecord.self, from: line)
                }
                line.append(data)
            }
            return try? EventStreamJSON.makeDecoder().decode(EventStreamRecord.self, from: line)
        }
    }

    public static func readEvents(at url: URL) throws -> [EventStreamRecord] {
        try withReader(at: url) { handle in
            var buffer = Data(), result: [EventStreamRecord] = []
            let decoder = EventStreamJSON.makeDecoder()
            func consume(_ line: Data) {
                if let value = try? decoder.decode(EventStreamRecord.self, from: line) { result.append(value) }
            }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    consume(Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                }
            }
            if !buffer.isEmpty { consume(buffer) }
            return result.sorted { $0.timestamp < $1.timestamp }
        }
    }

    public static func archive(directory: URL) throws {
        let fm = FileManager.default
        let source = directory.appendingPathComponent("events.jsonl")
        let target = directory.appendingPathComponent("events.jsonl.gz")
        guard fm.fileExists(atPath: directory.appendingPathComponent("metadata.json").path) else { return }
        let metaURL = directory.appendingPathComponent("metadata.json")
        var meta = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self, from: Data(contentsOf: metaURL))
        if meta.firstEventAt == nil, meta.eventCount > 0 {
            meta.firstEventAt = try firstEvent(at: eventsURL(in: directory))?.timestamp
            try EventStreamJSON.makeEncoder().encode(meta).write(to: metaURL, options: .atomic)
        }
        guard fm.fileExists(atPath: source.path) else { return }
        let temporary = directory.appendingPathComponent(".events-\(UUID().uuidString).gz")
        fm.createFile(atPath: temporary.path, contents: nil)
        defer { try? fm.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        let errors = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { try? output.close(); throw error }
        process.waitUntilExit()
        try output.close()
        guard process.terminationStatus == 0 else {
            throw ArchiveError.failed(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        // 先原子替换归档，再删原文；中断时读取端优先原文，可重新归档。
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: target) }
        try fm.removeItem(at: source)
    }

    public static func archiveCompleted(root: URL) throws {
        let directory = root.appendingPathComponent("segments")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where SegmentClock.date(fromSegmentID: dir.lastPathComponent) != nil {
            try archive(directory: dir)
        }
    }

    /// 采集启动持有实例锁后调用；只补写旧段元数据，不改写已有事件。
    static func recoverUnsealed(root: URL, excluding activeID: String) throws {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.lastPathComponent != activeID {
            guard let start = SegmentClock.date(fromSegmentID: dir.lastPathComponent),
                  !fm.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) else { continue }
            let url = eventsURL(in: dir)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
            let events = try readEvents(at: url)
            let metadata = EventStreamMetadata(id: dir.lastPathComponent, startedAt: start,
                endedAt: events.last?.timestamp, endReason: EventStreamEndReason.serviceTerminated.rawValue,
                eventCount: events.count, suppressedEventCount: 0, eventsPath: url.path,
                firstEventAt: events.first?.timestamp)
            try EventStreamJSON.makeEncoder().encode(metadata).write(
                to: dir.appendingPathComponent("metadata.json"), options: .atomic)
            } catch {
                FileHandle.standardError.write("恢复段封口失败（\(dir.lastPathComponent)）：\(error)\n".data(using: .utf8)!)
            }
        }
    }

    public enum ArchiveError: Error { case failed(String) }
}
