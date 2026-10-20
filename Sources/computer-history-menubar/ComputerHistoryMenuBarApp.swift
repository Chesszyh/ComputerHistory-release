import SwiftUI
import AppKit
import ComputerHistoryCore

/// 菜单栏常驻应用。
///
/// 展示三层信息，与使用者的关注范围由近及远对应：
///   1. **当前活动**——此刻前台的应用与窗口，每秒刷新；
///   2. **运行状态**——采集器是否在写入、累计数据量、记忆生成进度，可折叠，
///      面向排查问题；
///   3. **历史活动**——按天分组的时间线，来自已生成的记忆文件。
///
/// 界面刷新只读取本地；用户明确生成报告或备份时由命令行入口执行网络任务。
@main
struct ComputerHistoryMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: StatusModel

    private let processLease: CollectorProcessLease

    init() {
        let args = CommandLine.arguments
        let dataRoot: URL
        if let index = args.firstIndex(of: "--out") {
            guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("--out 缺少数据目录。\n".utf8))
                exit(2)
            }
            dataRoot = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else { dataRoot = CollectorStatus.defaultRoot }
        _model = StateObject(wrappedValue: StatusModel(root: dataRoot))
        let root = dataRoot.appendingPathComponent(".menubar")
        if CommandLine.arguments.contains("--stop") {
            guard let identity = CollectorProcessLease.runningIdentity(
                root: root, executableName: "computer-history-menubar") else {
                print("未找到身份可验证的菜单栏实例。")
                exit(0)
            }
            guard identity.matchesLiveProcess, kill(identity.pid, SIGTERM) == 0 else { exit(1) }
            for _ in 0..<50 {
                if !identity.matchesLiveProcess { print("菜单栏应用已停止。"); exit(0) }
                usleep(100_000)
            }
            FileHandle.standardError.write(Data("菜单栏进程未在 5 秒内退出。\n".utf8))
            exit(1)
        }
        do {
            processLease = try CollectorProcessLease(root: root)
            try processLease.publish()
        } catch CollectorProcessLease.LeaseError.alreadyRunning {
            print("菜单栏应用已在运行。")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("无法取得菜单栏实例锁：\(error)\n".utf8))
            exit(1)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            // 宽度由面板自行决定：侧栏展开时整体加宽。这里不能再写死 width，
            // 否则详情打开后会被裁掉。
            StatusPanel(model: model)
                .frame(height: 640)
        } label: {
            // 用图形而非文字：菜单栏空间紧张，且状态靠标题栏提示即可。
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只驻留菜单栏，不占用 Dock 与程序切换器。
        NSApp.setActivationPolicy(.accessory)
    }
}
