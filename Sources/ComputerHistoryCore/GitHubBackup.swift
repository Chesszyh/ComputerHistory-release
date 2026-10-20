import Foundation

public struct BackupSettings: Codable, Sendable {
    public var repository: String
    public var enabled: Bool
    public init(repository: String, enabled: Bool = true) { self.repository = repository; self.enabled = enabled }
    public func validate() throws {
        guard repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            throw ReportError.invalid("backup.json 的 repository 应为 owner/repository。")
        }
    }
    public static func load(root: URL) throws -> Self? {
        let file = root.appendingPathComponent("backup.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let settings = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            try settings.validate(); return settings
        } catch { throw ReportError.invalid("backup.json 无效：\(error)。请在设置的备份页修正配置。") }
    }
    public func save(root: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("backup.json"), options: .atomic)
    }
}

public struct BackupStatus: Codable, Sendable {
    public var lastSuccess: Date?
    public var repository: String?
    public var commit: String?
    public var error: String?
    public static func load(root: URL) -> Self {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("backup-status.json")))) ?? Self()
    }
    func save(root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("backup-status.json"), options: .atomic)
    }
}

public enum LocalCommand {
    public static func executable(_ name: String) throws -> URL {
        if name.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: name) { return URL(fileURLWithPath: name) }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let path = paths.map({ $0 + "/" + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ReportError.invalid("找不到 \(name)。请安装后重新运行。")
        }
        return URL(fileURLWithPath: path)
    }
    @discardableResult public static func run(_ name: String, _ arguments: [String], directory: URL? = nil, timeout: TimeInterval = 120) throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process(); process.executableURL = try executable(name); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GH_PROMPT_DISABLED"] = "1"
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw ReportError.invalid("\(name)执行超时，请检查网络后重试。") }
        process.waitUntilExit()
        let text = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw ReportError.invalid("\(name)失败：\(text)") }
        return text
    }
}

public struct GitHubBackup {
    public let root: URL
    public init(root: URL) { self.root = root }
    @discardableResult public func sync(automatic: Bool = false, now: Date = Date()) throws -> BackupStatus {
        guard let settings = try BackupSettings.load(root: root), settings.enabled else {
            if automatic { return BackupStatus.load(root: root) }
            throw ReportError.invalid("请先设置 GitHub 私有备份仓库并启用备份。")
        }
        guard let lock = ProcessLock(url: GenerationLock.lockURL("backup", root: root)) else {
            throw ReportError.invalid("备份正在运行，请稍后查看结果。")
        }
        defer { lock.release() }
        var status = BackupStatus.load(root: root)
        if automatic, status.repository == settings.repository, status.error == nil,
           let last = status.lastSuccess, Calendar.current.isDate(last, inSameDayAs: now) { return status }
        do {
            let visibility = try LocalCommand.run("gh", ["api", "repos/\(settings.repository)", "--jq", ".private"])
            guard visibility == "true" else { throw ReportError.invalid("\(settings.repository)不是私有仓库，未上传。请选用独立的私有数据仓库。") }
            try ActivityExport.refresh(root: root)
            let checkout = root.appendingPathComponent(".github-backup/\(settings.repository)")
            let remote = "https://github.com/\(settings.repository).git"
            if !FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) {
                try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
                try LocalCommand.run("gh", ["repo", "clone", settings.repository, checkout.path])
            }
            let actual = try LocalCommand.run("git", ["remote", "get-url", "origin"], directory: checkout)
            guard [remote, "git@github.com:\(settings.repository).git"].contains(actual) else {
                throw ReportError.invalid("备份目录的 origin 与设置不符，请检查 \(checkout.path)。")
            }
            let branch = try LocalCommand.run("git", ["symbolic-ref", "--short", "HEAD"], directory: checkout)
            try LocalCommand.run("git", ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "fetch", "origin"], directory: checkout)
            let refs = try LocalCommand.run("git", ["for-each-ref", "--format=%(refname)", "refs/remotes/origin/\(branch)"], directory: checkout)
            if !refs.isEmpty {
                try LocalCommand.run("git", ["merge", "--ff-only", "origin/\(branch)"], directory: checkout)
            }
            let source = root.appendingPathComponent("exports")
            let destination = checkout.appendingPathComponent("archive")
            for folder in ["activities", "daily", "weekly"] {
                let dir = source.appendingPathComponent(folder)
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "md" {
                    try ActivityExport.write(String(contentsOf: file, encoding: .utf8), to: destination.appendingPathComponent(folder).appendingPathComponent(file.lastPathComponent))
                }
            }
            guard FileManager.default.fileExists(atPath: destination.path) else { throw ReportError.invalid("尚无可备份的文本，请先生成记忆。") }
            try LocalCommand.run("git", ["add", "--", "archive/activities", "archive/daily", "archive/weekly"].filter { item in
                !item.hasPrefix("archive/") || FileManager.default.fileExists(atPath: checkout.appendingPathComponent(item).path)
            }, directory: checkout)
            let staged = try LocalCommand.run("git", ["diff", "--cached", "--name-only"], directory: checkout)
            if !staged.isEmpty {
                guard staged.split(separator: "\n").allSatisfy({ $0.hasPrefix("archive/") }) else {
                    throw ReportError.invalid("备份目录存在其他已暂存文件，请先检查 \(checkout.path)。")
                }
                try LocalCommand.run("git", ["-c", "user.name=ComputerHistory", "-c", "user.email=computer-history@users.noreply.github.com", "commit", "-m", "Archive activity summaries"], directory: checkout)
            }
            try LocalCommand.run("git", ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "-c", "push.followTags=false", "push", "origin", "HEAD:refs/heads/\(branch)"], directory: checkout)
            let commit = try LocalCommand.run("git", ["rev-parse", "HEAD"], directory: checkout)
            let remoteTip = try LocalCommand.run("gh", ["api", "repos/\(settings.repository)/git/ref/heads/\(branch)", "--jq", ".object.sha"])
            guard commit == remoteTip else { throw ReportError.invalid("远端提交与本地备份不一致，请重试。") }
            status = BackupStatus(lastSuccess: now, repository: settings.repository, commit: commit, error: nil)
            try status.save(root: root)
            return status
        } catch {
            status.error = String(describing: error)
            try status.save(root: root)
            throw error
        }
    }
}
