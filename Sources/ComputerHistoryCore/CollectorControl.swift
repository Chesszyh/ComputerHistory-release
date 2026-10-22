import Foundation

/// 采集与总结的运行开关，以及登录自启动的登记。
///
/// 用文件而非信号或 socket：开关要跨进程、跨重启保持，且应由使用者直接查看与编辑。
/// 采集器每个采样周期读一次（文件很小），监督进程每个生成周期读一次。
public struct CollectorControl: Codable, Sendable, Equatable {

    /// 是否记录活动。关闭后采集器不再采样，也不写入事件。
    public var recording: Bool
    /// 是否调用模型总结。关闭后只采集，不生成记忆与叙述。
    public var summarizing: Bool

    /// 一次性请求：置位后监督进程立即跑一轮生成，然后由监督进程清零。
    ///
    /// 用文件而非信号/socket：监督进程已经在按周期读这个文件，加一个字段即可；
    /// 信号需要知道 pid 且语义容易与停止混淆。
    public var flushRequested: Bool

    public init(recording: Bool = true, summarizing: Bool = true,
                flushRequested: Bool = false) {
        self.recording = recording
        self.summarizing = summarizing
        self.flushRequested = flushRequested
    }

    public static let fileName = "control.json"

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    /// 缺少文件使用初始开关；损坏或无法读取时暂停，避免意外恢复采集与外发。
    public static func load(root: URL) -> CollectorControl {
        do {
            let data = try Data(contentsOf: fileURL(root: root))
            return try JSONDecoder().decode(CollectorControl.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CollectorControl()
        } catch {
            return CollectorControl(recording: false, summarizing: false)
        }
    }

    // 旧版本写出的文件没有 flushRequested 字段，缺字段按 false 解码，
    // 否则升级后第一次读取会失败并退回默认值，把使用者的开关设置一并丢掉。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recording = try c.decodeIfPresent(Bool.self, forKey: .recording) ?? true
        summarizing = try c.decodeIfPresent(Bool.self, forKey: .summarizing) ?? true
        flushRequested = try c.decodeIfPresent(Bool.self, forKey: .flushRequested) ?? false
    }

    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.fileURL(root: root), options: .atomic)
    }

    /// 只改一项并写回。托盘应用的开关各自独立，避免互相覆盖。
    public static func update(root: URL,
                              recording: Bool? = nil,
                              summarizing: Bool? = nil,
                              flushRequested: Bool? = nil) throws {
        var control = load(root: root)
        if let recording { control.recording = recording }
        if let summarizing { control.summarizing = summarizing }
        if let flushRequested { control.flushRequested = flushRequested }
        try control.save(root: root)
    }
}

/// 登录项只启动菜单栏程序；采集器通过命令行单独启动。
public enum LoginItem {

    public static let label = "xyz.chesszyh.computerhistory.menubar"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 写入 LaunchAgent 并加载。托盘应用不需要特殊授权，launchd 可以拉起。
    public static func enable(executablePath: String) throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "Label": label, "ProgramArguments": [executablePath],
            "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Interactive"
        ], format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: plistURL, options: .atomic)
        // 先卸再装，避免重复加载报错。
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        guard run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "登录项加载失败，请检查 LaunchAgent 后重新启用。"])
        }
    }

    public static func disable() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
