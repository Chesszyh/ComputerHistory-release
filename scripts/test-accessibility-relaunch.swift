import AppKit
import ComputerHistoryCore

// Run with --chrome-executable /path/to/Google\ Chrome to use an isolated profile.
@main struct AccessibilityRelaunchTest {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--chrome-executable"), at + 1 < args.count else {
            fatalError("Provide --chrome-executable; the test never uses the personal browser profile")
        }
        let original = NSWorkspace.shared.frontmostApplication
        defer { original?.activate(options: []) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("synthetic.html")
        try "<html><title>Synthetic accessibility test</title><body><h1>SYNTHETIC RELAUNCH DOCUMENT</h1><p>Document body after restart.</p></body></html>".write(to: page, atomically: true, encoding: .utf8)
        var activation = AccessibilityActivation()
        func verify(executable: String, arguments: [String], name: String) throws {
            var pids: [Int32] = []
            for round in 1...2 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                let pid = process.processIdentifier
                defer {
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                }
                pids.append(pid)
                let deadline = Date().addingTimeInterval(15)
                var found = false
                while Date() < deadline {
                    activation.prepare(pid: pid)
                    let roots = AXTreeReader.read(pid: pid)
                    let text = UIElementRenderTree.text(roots)
                    if text.contains("SYNTHETIC RELAUNCH DOCUMENT") { found = true; break }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                }
                if !found { throw NSError(domain: "AccessibilityRelaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) document was unreadable after launch \(round)"]) }
                process.terminate()
                process.waitUntilExit()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                print("PASS: isolated \(name) launch \(round) exposes synthetic document body")
            }
            precondition(pids[0] != pids[1])
        }
        try verify(executable: args[at + 1], arguments: ["--user-data-dir=\(root.appendingPathComponent("profile").path)", "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-component-update", "--disable-sync", "--new-window", page.absoluteString], name: "Chrome")
        if let nativeAt = args.firstIndex(of: "--native-executable"), nativeAt + 1 < args.count {
            try verify(executable: args[nativeAt + 1], arguments: [], name: "AppKit")
        }
    }
}
