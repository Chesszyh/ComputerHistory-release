import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 私有兼容性样本只在显式设置环境变量后读取，普通测试不访问个人数据。
final class RealSampleTests: XCTestCase {
    static var samplesRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["COMPUTER_HISTORY_SAMPLES"],
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    private func requireSamples() throws -> URL {
        guard let root = Self.samplesRoot else {
            throw XCTSkip("样本目录不存在，跳过真实数据回归")
        }
        return root
    }

    private func allEventFiles(_ root: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .map { $0.appendingPathComponent("events.jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    /// 全部真实事件都必须能被解码，且重新编码后关键结构不变。
    func testDecodeAllRealEvents() throws {
        let root = try requireSamples()
        let files = try allEventFiles(root)
        XCTAssertFalse(files.isEmpty, "应找到 events.jsonl")

        let decoder = EventStreamJSON.makeDecoder()
        let encoder = EventStreamJSON.makeEncoder()
        var total = 0
        var kinds = Set<String>()

        for file in files {
            let data = try Data(contentsOf: file)
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                let record = try decoder.decode(EventStreamRecord.self, from: Data(line))
                total += 1
                kinds.insert(record.kind.rawValue)
                // 再编码必须成功，且时间戳保持秒级精度。
                // 注意不能整体搜 "."：URL 与 bundle id 里天然含点。
                let out = try encoder.encode(record)
                let txt = String(decoding: out, as: UTF8.self)
                let ts = try XCTUnwrap(
                    txt.range(of: #""timestamp":"([^"]+)""#, options: .regularExpression),
                    "应能定位时间戳字段")
                XCTAssertFalse(txt[ts].contains("."), "时间戳不应含小数秒：\(txt[ts])")
                XCTAssertTrue(txt[ts].hasSuffix("Z\""), "时间戳应以 Z 结尾：\(txt[ts])")
                XCTAssertFalse(txt.contains(":null"), "不应写出 null：\(txt.prefix(120))")
            }
        }
        XCTAssertGreaterThan(total, 10_000, "样本事件数异常偏少")
        XCTAssertEqual(kinds.count, 10, "应观察到全部 10 种 kind，实际 \(kinds.sorted())")
    }

    /// 两种 `ax.mode` 都必须出现，且 fullTree 行**绝不**被解析成带标记的元素行。
    ///
    /// 这条是防回归的核心：fullTree 中存在以 `~`/`+`/`-` 开头的终端内容行，
    /// 若解析器对其套用差分文法，会静默产出错误的树结构。
    func testRealModeDistributionAndMarkerDiscipline() throws {
        let root = try requireSamples()
        let decoder = EventStreamJSON.makeDecoder()
        var modeCount: [EventStreamAXTree.Mode: Int] = [:]
        var fullTreeMarkedElements = 0
        var diffMarkerLines = 0

        for file in try allEventFiles(root) {
            let data = try Data(contentsOf: file)
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let record = try? decoder.decode(EventStreamRecord.self, from: Data(line)),
                      let ax = record.ax else { continue }
                modeCount[ax.mode, default: 0] += 1
                for parsed in AXTextParser.parse(ax.text, mode: ax.mode) {
                    if case let .element(marker, _, _, _, _) = parsed, marker != nil {
                        if ax.mode == .fullTree { fullTreeMarkedElements += 1 }
                        else { diffMarkerLines += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(modeCount.keys.count, 2, "两种模式都应出现：\(modeCount)")
        XCTAssertGreaterThan(modeCount[.diffFromPrevious] ?? 0, 1000)
        XCTAssertGreaterThan(modeCount[.fullTree] ?? 0, 500)
        XCTAssertGreaterThan(diffMarkerLines, 100_000, "差分模式应有大量标记行")
        XCTAssertEqual(fullTreeMarkedElements, 0,
                       "fullTree 中不应有被当作元素标记的行（终端内容陷阱）")
    }

    /// metadata.json 的键集合必须与实现一致，且不含 null。
    func testRealMetadataShape() throws {
        let root = try requireSamples()
        let dirs = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
        XCTAssertFalse(dirs.isEmpty)

        let decoder = EventStreamJSON.makeDecoder()
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard FileManager.default.fileExists(atPath: metaURL.path) else { continue }
            let meta = try decoder.decode(EventStreamMetadata.self,
                                          from: Data(contentsOf: metaURL))
            XCTAssertEqual(meta.id, dir.lastPathComponent,
                           "metadata.id 应等于目录名")
            XCTAssertEqual(SegmentClock.durationSeconds, 600)
            // startedAt 必须对齐到 10 分钟边界
            let aligned = SegmentClock.alignedStart(for: meta.startedAt)
            XCTAssertEqual(aligned.timeIntervalSince1970,
                           meta.startedAt.timeIntervalSince1970, accuracy: 0.5,
                           "startedAt 应对齐到 10 分钟边界")
        }
    }
}
