import SwiftUI
import AppKit
import ComputerHistoryCore

struct PermissionWindowRegression {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = root.appendingPathComponent("synthetic-command")
        try "#!/bin/sh\nprintf '%s' '{\"accessibility\":true,\"inputMonitoring\":true,\"screenRecording\":true}'\n"
            .write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let model = StatusModel(root: root, commandExecutable: command)
        defer { model.shutdown() }
        NSApplication.shared.setActivationPolicy(.regular)
        model.openPermissionSetup()
        guard let window = NSApplication.shared.windows.first(where: { $0.title == "设置 ComputerHistory" }) else {
            fatalError("The actual standalone setup window did not open")
        }
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)); window.contentView?.layoutSubtreeIfNeeded() }
        settle()
        model.permissionStatus = try JSONDecoder().decode(PermissionStatus.self,
            from: Data("{\"accessibility\":true,\"inputMonitoring\":true,\"screenRecording\":true}".utf8))
        model.permissionBusy = false
        settle()
        if let directory = ProcessInfo.processInfo.environment["COMPUTER_HISTORY_TEST_SCREENSHOTS"] {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), directory + "/permission-window.png"]
            try capture.run(); capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { fatalError("Synthetic window capture failed") }
        }
        func check(_ phase: String) {
            let size = window.contentLayoutRect.size
            print("WINDOW \(phase): \(Int(size.width)) × \(Int(size.height))")
            guard size.width >= 440, size.width <= 520, size.height >= 480, size.height <= 620 else {
                fputs("FAIL: standalone setup content collapsed or grew beyond the intended bounds\n", stderr)
                exit(1)
            }
        }
        check("opened")
        model.permissionMessage = String(repeating: "合成错误信息，需要换行并允许滚动查看。", count: 18)
        settle(); check("long-message")
        window.close()
        model.openPermissionSetup()
        settle(); check("reopened")
        print("PASS: actual standalone window bounds, long-message containment, close and reopen")
    }
}
