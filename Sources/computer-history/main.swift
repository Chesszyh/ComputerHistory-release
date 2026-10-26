import Foundation
import AppKit
import ComputerHistoryCore

// 本地活动采集。需要 Accessibility 权限（系统设置 → 隐私与安全性 → 辅助功能），
// 默认读取辅助功能文本；显式配置的窗口文字识别只在本机处理图像，不保存截图。

let args = Array(CommandLine.arguments.dropFirst())
let flags = Set(args)

let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".computer-history")

func usage() {
    print("""
    computer-history — 本地活动采集

    用法：
      computer-history collect [--out <目录>] [--seconds <秒>]
                                            采集活动并写入 segments/
      computer-history supervise --daemon   后台常驻（脱离终端会话，崩溃自动重启）
      computer-history memorize [--limit N] [--segment <id>] [--print] [--overwrite]
                                [--granularity 10min|6h]
                                            把已封口的段写成记忆文件
      computer-history segments             列出可生成记忆的段
      computer-history narrative [--limit N] [--day <yyyy-MM-dd>] [--print] [--overwrite] [--wait-lock]
                                            把记忆归纳成前端叙述条目
      computer-history report [--kind daily|weekly] [--day yyyy-MM-dd] [--no-model] [--overwrite] [--print]
                                            先补齐所需记忆，再生成报告；省略日期补齐已结束时段
      computer-history export --day yyyy-MM-dd [--kind daily|weekly] [--material]
                              [--format md|txt] [--file <路径>] [--copy]
                                            导出报告或给 AI 的活动材料（不调用模型）
      computer-history backup [--repository owner/repo] [--disable] [--automatic]
                                            设置或执行可选 GitHub 私有备份
      computer-history model-key [--fallback] [--check|--authorize]
                                            保存密钥、静默检查读取或手动请求钥匙串授权
      computer-history verify               校验记忆链完整性
      computer-history --check              检查权限与落盘目录
      computer-history --status             查看长期运行状态
      computer-history --stop               停止后台采集
      computer-history --schema-version     打印事件种类
      computer-history --help               显示本帮助

    选项：
      --out <目录>     落盘根目录。默认 ~/.computer-history
      --seconds <秒>   采集指定时长后自动退出；省略则持续运行直到中断

    collect 仅在本地采集；生成任务使用 model.json 配置的服务或 DeepSeek 环境变量。
    请求输入、输出、用量与估算费用保存在 requests/，可在菜单栏查看。
    --no-model 禁止生成任务调用模型，适用于全部生成入口。
    supervise 在新段封口后生成记忆；日报和备份使用独立队列。--memorize-interval 0 关闭定时生成（仍接受手动请求）。
    """)
}

func warn(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// 把进程输出接到指定日志文件。
///
/// 不能只靠 shell 的 `>>`：重定向在进程启动前就打开了文件描述符，
/// 进程内重命名旧文件后 fd 仍指向已改名的旧文件，新写入不会进入新文件。
/// 因此用 `dup2` 换成自己打开的句柄。
///
/// **以追加方式打开，且不在此轮转**：被监督时监督进程也在写同一个日志，
/// 截断会抹掉它的记录。轮转在 `--daemon` 脱离会话时执行一次。
func redirectOutput(to url: URL) {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { return }
    dup2(fd, STDOUT_FILENO)
    dup2(fd, STDERR_FILENO)
    if fd > STDERR_FILENO { close(fd) }
    // 重定向到文件后 stdout 默认全缓冲，日志要等缓冲满或进程退出才可见。
    // 长期后台运行时这会让人误以为采集器没在工作。
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
}

/// 取 `--flag value` 形态的参数值。
func value(of flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    let next = args.index(after: i)
    return next < args.endIndex ? args[next] : nil
}

/// 解析 `--out`，缺省用默认目录。
func outputRoot() -> URL {
    value(of: "--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? defaultRoot
}

func loadConfig(root: URL) -> CollectorConfig {
    do { return try CollectorConfig.load(rootDirectory: root) }
    catch {
        warn("无法读取配置 \(CollectorConfig.fileURL(rootDirectory: root).path)：\(error)。请修复配置后重试。")
        exit(1)
    }
}

do {
    try ModelAPIKey.configureInteraction(allow: flags.contains("model-key") && !flags.contains("--check"))
} catch { warn(String(describing: error)); exit(1) }

if args.isEmpty || flags.contains("--help") || flags.contains("-h") {
    usage()
    exit(0)
}

if flags.contains("--schema-version") {
    for kind in EventStreamEventKind.allCases { print(kind.rawValue) }
    exit(0)
}

if flags.contains("--check") && !flags.contains("model-key") {
    let trusted = InputTap.hasAccessibilityPermission
    print("辅助功能权限：\(trusted ? "已授予" : "未授予")")
    print("屏幕录制权限：\(CGPreflightScreenCaptureAccess() ? "已授予" : "未授予")（窗口文字识别需要）")
    if !trusted {
        print("  请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选本程序。")
        print("  缺该权限时键盘/鼠标与 AX 树都采不到。")
    }
    let root = outputRoot()
    print("落盘目录：\(root.path)")
    let seg = root.appendingPathComponent("segments")
    if FileManager.default.fileExists(atPath: seg.path) {
        let n = (try? FileManager.default.contentsOfDirectory(
            at: seg, includingPropertiesForKeys: nil).count) ?? 0
        print("  已有 segment：\(n)")
    } else {
        print("  尚不存在，采集时会自动创建。")
    }
    exit(0)
}

if flags.contains("--status") {
    let root = outputRoot()
    let running = CollectorProcessLease.runningIdentity(root: root) != nil
    print("采集进程：\(running ? "运行中" : "未运行")")
    let seg = root.appendingPathComponent("segments")
    let cfg = loadConfig(root: root)
    print("落盘目录：\(seg.path)")
    print("保留策略：总量 \(cfg.retention.maxTotalBytes / 1_048_576) MB，"
          + "最长 \(cfg.retention.maxAgeDays) 天")
    print("屏蔽应用：\(cfg.policy.blocklist.count) 项")

    let data = CollectorStatus.read(root: root).data
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm"
    print("segment 数：\(data.segmentCount)")
    print("时间范围：\(data.earliest.map { fmt.string(from: $0) } ?? "-") → \(data.latest.map { fmt.string(from: $0) } ?? "-")")
    print("事件总数：\(data.eventCountIncomplete ? "至少 " : "")\(data.eventCount)")
    print("占用空间：\(data.bytes / 1_048_576) MiB")
    exit(0)
}

if flags.contains("verify") {
    let root = outputRoot()
    let gen = MemoryGenerator(rootDirectory: root,
                              memoriesDirectory: root.appendingPathComponent("memories"))
    let issues = gen.validateChain()
    let segments = gen.orderedSegments()
    print("已排序段：\(segments.count)")
    if issues.isEmpty {
        print("✅ 记忆链完整：无自引用、未来引用或成环。")
    } else {
        print("❌ 发现 \(issues.count) 处链条问题：")
        for issue in issues.prefix(20) {
            print("  [\(issue.kind.rawValue)] \(issue.memory)")
            print("      → \(issue.referenced)")
        }
    }
    exit(issues.isEmpty ? 0 : 1)
}

if flags.contains("model-key") {
    do {
        let settings = try ModelSettings.load(root: outputRoot())
        let fallback = flags.contains("--fallback")
        let groupID = fallback ? settings?.fallback?.credentialGroupID : settings?.credentialGroupID
        if fallback, settings?.credentialGroupID != nil, settings?.fallback == nil {
            throw ReportError.invalid("请先在 model.json 中选择备用模型组。")
        }
        if flags.contains("--check") || flags.contains("--authorize") {
            guard !(flags.contains("--check") && flags.contains("--authorize")) else {
                throw ReportError.invalid("--check 与 --authorize 不能同时使用。")
            }
            guard let key = try ModelAPIKey.load(root: outputRoot(), fallback: fallback, groupID: groupID), !key.isEmpty else {
                throw ReportError.invalid("当前模型组没有保存密钥。")
            }
            print("模型密钥可读取。")
            exit(0)
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let key = String(data: data, encoding: .utf8), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReportError.invalid("请从标准输入提供模型密钥。")
        }
        try ModelAPIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines), root: outputRoot(), fallback: fallback, groupID: groupID)
        print("模型密钥已保存到系统钥匙串。")
        exit(0)
    } catch { warn(String(describing: error)); exit(1) }
}

if flags.contains("report") || flags.contains("export") {
    let root = outputRoot()
    do {
        guard let kind = ReportKind(rawValue: value(of: "--kind") ?? "daily") else {
            throw ReportError.invalid("--kind 只支持 daily 或 weekly。")
        }
        if flags.contains("export") {
            let date = try value(of: "--day").map { try ReportPeriod.parseDay($0) } ?? Date()
            let period = ReportPeriod(kind: kind, date: date)
            let text: String
            if flags.contains("--material") { text = try ActivityExport.aiMaterial(root: root, period: period) }
            else {
                guard let report = try ActivityReport.load(root: root, period: period) else {
                    throw ReportError.invalid("尚无\(period.title)，请先生成报告，或使用 --material 导出活动材料。")
                }
                text = report.markdown
            }
            let format = value(of: "--format") ?? "md"
            guard ["md", "txt"].contains(format) else { throw ReportError.invalid("--format 只支持 md 或 txt。") }
            if let path = value(of: "--file") {
                try ActivityExport.write(ActivityExport.formatted(text, format: format), to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            } else if !flags.contains("--copy") { print(ActivityExport.formatted(text, format: format)) }
            if flags.contains("--copy") {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(ActivityExport.formatted(text, format: format), forType: .string) else { throw ReportError.invalid("写入剪贴板失败，请重试。") }
            }
        } else {
            guard let lock = ProcessLock(url: GenerationLock.lockURL("report", root: root)) else {
                throw ReportError.invalid("报告正在生成，请稍后重试。")
            }
            defer { lock.release() }
            let client = flags.contains("--no-model") ? nil : try DeepSeekClient.fromEnvironment(rootDirectory: root)
            let generator = ReportGenerator(root: root, client: client)
            if let day = value(of: "--day") {
                let period = ReportPeriod(kind: kind, date: try ReportPeriod.parseDay(day))
                let report = try generator.generate(period: period, overwrite: flags.contains("--overwrite"))
                print(flags.contains("--print") ? report.markdown : "已生成\(report.title)\(report.preview ? "（截至当前）" : "")。")
            } else {
                let count = try generator.generateMissing()
                print("已补齐 \(count) 份日报／周报。")
            }
        }
        exit(0)
    } catch { warn(String(describing: error)); exit(1) }
}

if flags.contains("backup") {
    let root = outputRoot()
    do {
        if flags.contains("--disable") {
            if var settings = try BackupSettings.load(root: root) { settings.enabled = false; try settings.save(root: root) }
            print("GitHub 备份已关闭。"); exit(0)
        }
        if let repository = value(of: "--repository") {
            try BackupSettings(repository: repository).save(root: root)
            print("已启用 GitHub 私有备份：\(repository)。"); exit(0)
        }
        let status = try GitHubBackup(root: root).sync(automatic: flags.contains("--automatic"))
        if let commit = status.commit { print("备份远端已确认：\(commit)") }
        else { print("GitHub 备份未启用。") }
        exit(0)
    } catch { warn(String(describing: error)); exit(1) }
}

if flags.contains("narrative") {
    let root = outputRoot()
    // 与 memorize 同理：并发会让两个进程各写一份相同的条目。
    var lock = GenerationLock.narrative(root: root)
    if flags.contains("--wait-lock") {
        let deadline = Date().addingTimeInterval(300)
        while lock == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            lock = GenerationLock.narrative(root: root)
        }
    }
    guard let generationLock = lock else {
        warn("已有一个叙述生成任务在运行，本次跳过。")
        exit(flags.contains("--overwrite") ? 75 : 0)
    }
    defer { generationLock.release() }
    var client: DeepSeekClient?
    if !flags.contains("--no-model") {
        do { client = try DeepSeekClient.fromEnvironment(rootDirectory: root) }
        catch DeepSeekClient.ClientError.missingAPIKey {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("model.json").path) {
                warn("模型配置缺少密钥，请在模型设置中填写或使用 --no-model。")
                exit(1)
            }
            warn("未配置模型，使用本地事实摘要。")
        }
        catch { warn("模型初始化失败：\(error)"); exit(1) }
    }
    let generator = NarrativeGenerator(rootDirectory: root, client: client)
    var outcomes: [NarrativeGenerator.Outcome] = []
    if let day = value(of: "--day") {
        do { outcomes = [try generator.generate(day: day,
                                               overwrite: flags.contains("--overwrite"))] }
        catch { warn("生成失败：\(error)"); exit(1) }
    } else {
        do {
            outcomes = try generator.generateMissing(
                limit: value(of: "--limit").flatMap(Int.init),
                overwrite: flags.contains("--overwrite"))
        } catch { warn("生成失败：\(error)"); exit(1) }
    }
    if outcomes.isEmpty {
        print("没有需要归纳的日期。")
    } else {
        var tokens = 0
        for o in outcomes {
            tokens += o.usage?.totalTokens ?? 0
            print("  \(o.day)  新增 \(o.newItems) 条，该日共 \(o.totalItems) 条")
        }
        if tokens > 0 { print("本次用量 \(tokens) tokens") }
    }
    if flags.contains("--print") {
        let narrative = ActivityNarrative.load(root: root)
        for group in narrative.groupedByDay().prefix(2) {
            print("\n【\(group.day)】")
            for item in group.items.prefix(12) {
                let t = DateFormatter()
                t.dateFormat = "HH:mm"
                print("  \(t.string(from: item.timestamp))  \(item.title)")
                print("          \(item.summary)")
            }
        }
    }
    exit(0)
}

if flags.contains("segments") {
    let root = outputRoot()
    let memories = value(of: "--memories").map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("memories")
    let gen = MemoryGenerator(rootDirectory: root, memoriesDirectory: memories)
    let ids = gen.completedSegmentIDs()
    print("可生成记忆的段（已封口）：\(ids.count)")
    for id in ids {
        let name = MemoryWriter.fileName(segmentID: id)
        let done = FileManager.default.fileExists(
            atPath: memories.appendingPathComponent(name).path)
        print("  \(done ? "✅" : "  ") \(id)")
    }
    exit(0)
}

if flags.contains("memorize") {
    let root = outputRoot()
    // 同一类生成任务不得并发：两个进程各自读到旧状态、各自追加结果，会写出
    // 重复条目——实测叙述缓存里出现过三条完全相同的内容。
    guard let generationLock = GenerationLock.memorize(root: root) else {
        warn("已有一个记忆生成任务在运行，本次跳过。")
        exit(0)
    }
    _ = generationLock
    let memories = value(of: "--memories").map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("memories")

    // --no-model：只用事件本身可证实的部分，不联网。
    var client: DeepSeekClient?
    if !flags.contains("--no-model") {
        do {
            client = try DeepSeekClient.fromEnvironment(rootDirectory: root)
        } catch DeepSeekClient.ClientError.missingAPIKey {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("model.json").path) {
                warn("模型配置缺少密钥，请在模型设置中填写或使用 --no-model。")
                exit(1)
            }
            warn("未配置模型，使用本地事实摘要。")
        } catch {
            warn("模型初始化失败：\(error)")
            exit(1)
        }
    }

    do { try EventArchive.archiveCompleted(root: root) }
    catch { warn("事件归档失败，保留原始文件：\(error)") }
    let limit = value(of: "--limit").flatMap(Int.init)
    let granularity = value(of: "--granularity") ?? "10min"
    let generator = MemoryGenerator(rootDirectory: root,
                                    memoriesDirectory: memories,
                                    client: client)

    if granularity == "6h" {
        let includeOpen = flags.contains("--include-open")
        let buckets = generator.sixHourBuckets(includingOpenBuckets: includeOpen)
        guard !buckets.isEmpty else {
            print("没有可用于 6 小时汇总的段。")
            exit(0)
        }
        let outcomes = generator.generateMissingSixHour(
            limit: limit, overwrite: flags.contains("--overwrite"),
            includingOpenBuckets: includeOpen)
        if outcomes.isEmpty {
            let scope = includeOpen ? "含未结束共" : "已结束共"
            print("没有需要生成的 6 小时汇总（\(scope) \(buckets.count) 个时段）。")
        } else {
            var tokens = 0
            for o in outcomes {
                print("  \(o.segmentID)  [\(o.usedModel ? "模型" : "事实")]  "
                      + "\(o.memoryURL.lastPathComponent)")
                tokens += o.usage?.totalTokens ?? 0
            }
            print("共生成 \(outcomes.count) 份 6 小时汇总 → \(memories.path)")
            if tokens > 0 { print("本次用量 \(tokens) tokens") }
            if flags.contains("--print"), let last = outcomes.last,
               let text = try? String(contentsOf: last.memoryURL, encoding: .utf8) {
                print("\n" + String(repeating: "─", count: 60) + "\n")
                print(text)
            }
        }
        exit(0)
    }

    // 指定单段时只处理该段，便于逐段核对效果。
    var outcomes: [MemoryGenerator.Outcome] = []
    if let segment = value(of: "--segment") {
        do {
            let previous = generator.previousMemoryPath(before: segment)
            let outcome = try generator.generate(
                segmentID: segment,
                previousMemoryPath: flags.contains("--no-chain") ? nil : previous,
                overwrite: flags.contains("--overwrite"))
            outcomes = [outcome]
        } catch {
            warn("生成失败：\(error)")
            exit(1)
        }
    } else {
        var since: Date?
        if let raw = value(of: "--since") {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            f.timeZone = .current
            f.locale = Locale(identifier: "en_US_POSIX")
            since = f.date(from: raw)
            if since == nil { warn("--since 需形如 2026-10-14T16:00:00"); exit(1) }
        }
        outcomes = generator.generateMissing(
            limit: limit, overwrite: flags.contains("--overwrite"), since: since, recentFirst: flags.contains("--recent-first"))
    }

    if outcomes.isEmpty {
        print("没有需要生成的段。")
    } else {
        var tokens = 0
        for o in outcomes {
            let mark = o.usedModel ? "模型" : "事实"
            print("  \(o.segmentID)  [\(mark)]  \(o.memoryURL.lastPathComponent)")
            tokens += o.usage?.totalTokens ?? 0
        }
        print("共生成 \(outcomes.count) 份记忆 → \(memories.path)")
        if tokens > 0 { print("本次用量 \(tokens) tokens") }
        if flags.contains("--print"), let last = outcomes.last,
           let text = try? String(contentsOf: last.memoryURL, encoding: .utf8) {
            print("\n" + String(repeating: "─", count: 60) + "\n")
            print(text)
        }
    }
    if client != nil, outcomes.contains(where: { MemoryIndex.parse(fileURL: $0.memoryURL)?.generationStatus == "failed" }) {
        warn("模型总结失败，已保留带失败标记的事实摘要；请检查请求详情。")
        exit(1)
    }
    exit(0)
}

if flags.contains("supervise") {
    // 脱离会话后 stdout 指向文件，默认全缓冲会让监督进程的日志长时间不可见。
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    let root = outputRoot()
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cfg = loadConfig(root: root)
    let logURL = root.appendingPathComponent("collector.log")

    guard let exe = CollectorSupervisor.currentExecutablePath() else {
        warn("无法确定可执行文件路径，无法常驻。")
        exit(1)
    }

    if flags.contains("--daemon") {
        // 已有实例在跑就不重复启动。
        if CollectorProcessLease.runningIdentity(root: root) != nil {
            print("已有采集实例在运行（\(root.path)）。")
            exit(0)
        }
        do {
            // 子进程以 supervise 身份在新会话中运行，本进程随即退出。
            // 参数需完整转发——只传 --out 会丢掉 --memorize-interval 之类的选项，
            // 脱离后的实例将退回默认值。
            // args 已含 "supervise" 自身，不要重复前置。
            var forwarded: [String] = []
            var index = args.startIndex
            while index < args.endIndex {
                let arg = args[index]
                if arg == "--daemon" { index += 1; continue }
                // --out 的值统一换成已解析的绝对路径，避免子进程工作目录不同。
                if arg == "--out" {
                    forwarded.append("--out")
                    forwarded.append(root.path)
                    index += 2
                    continue
                }
                forwarded.append(arg)
                index += 1
            }
            if !forwarded.contains("--out") {
                forwarded.append(contentsOf: ["--out", root.path])
            }
            if !forwarded.contains("supervise") {
                forwarded.insert("supervise", at: 0)
            }
            try CollectorSupervisor.detach(
                executable: exe,
                arguments: forwarded,
                logURL: logURL, maxLogBytes: cfg.maxLogBytes)
        } catch {
            warn("常驻启动失败：\(error)")
            exit(1)
        }
        print("已在后台常驻（独立于当前终端会话）。")
        print("  日志：\(logURL.path)")
        print("  停止：computer-history --stop")
        exit(0)
    }

    // 监督循环：采集器长驻运行，本进程按周期生成派生产物并看护采集器。
    //
    // 生成任务**不阻塞看护**：同步等待期间采集器若崩溃将无人重启（实测在
    // 模拟接口阻塞时，配置的重试间隔为 0.1 秒，7 秒后采集器仍未重启）。
    // 因此生成作为独立、可跟踪的子进程运行，循环照常检查采集器。
    let retryDelay = value(of: "--retry-delay").flatMap(Double.init) ?? 30
    let memorizeInterval = value(of: "--memorize-interval").flatMap(Double.init) ?? 600
    // 每次最多补几段。停机后积压可能很多，一次全生成会产生一笔可观的用量，
    // 分批补写让成本可预期，也不至于长时间占用网络。
    let memorizeBatch = value(of: "--memorize-batch").flatMap(Int.init) ?? 6

    /// 按序执行的生成任务。一个跑完再起下一个，避免并发调用接口。
    struct GenerationTask {
        var label: String
        var arguments: [String]
    }

    var child = CollectorSupervisor.spawnDetachedChild(
        executable: exe, arguments: ["collect", "--out", root.path])
    if child == nil {
        warn("无法启动采集器。")
        exit(1)
    }
    print("采集器已启动（pid \(child!)）。")

    var pending: [GenerationTask] = []
    var running: (pid: pid_t, label: String)?

    var nextLogCheck = Date()
    var nextMemorize = Date()
    var nextBackground = Date()
    var completedRealtime = false
    var backgroundRequested = false
    var memoryCountAtLaunch = 0
    var pendingBackground: [GenerationTask] = []
    var runningBackground: (pid: pid_t, label: String)?
    let backlog = MemoryGenerator(rootDirectory: root, memoriesDirectory: root.appendingPathComponent("memories"))
    var observedSegments = Set(backlog.completedSegmentIDs())
    while true {
        Thread.sleep(forTimeInterval: 1)

        // ⓪ 运行期把日志截到上限内。只在启动时轮转不够——长期运行会持续增长。
        // 每 60 秒检查一次，避免频繁 stat。
        if Date() >= nextLogCheck {
            nextLogCheck = Date().addingTimeInterval(60)
            CollectorSupervisor.enforceLogBound(at: logURL,
                                               maxBytes: cfg.maxLogBytes)
        }

        // ① 看护采集器：每隔 1 秒检查，生成任务在跑也不中断。
        if let pid = child, let code = CollectorSupervisor.reap(pid) {
            if code == 0 || code == 74 {
                print(code == 0 ? "采集器正常停止，监督退出。" : "采集器停止时封口失败，监督退出；请检查日志与存储。")
                if let running { _ = CollectorSupervisor.terminate(running.pid) }
                if let runningBackground { _ = CollectorSupervisor.terminate(runningBackground.pid) }
                exit(code)
            }
            if code == 73 {
                print("已有采集实例，监督退出。")
                if let running { _ = CollectorSupervisor.terminate(running.pid) }
                if let runningBackground { _ = CollectorSupervisor.terminate(runningBackground.pid) }
                exit(0)
            }
            print("采集器异常退出（码 \(code)），\(Int(retryDelay)) 秒后重启…")
            child = nil
            // 生成任务与采集器无依赖，继续跑完即可，不必打断。
            Thread.sleep(forTimeInterval: retryDelay)
            child = CollectorSupervisor.spawnDetachedChild(
                executable: exe, arguments: ["collect", "--out", root.path])
            if child == nil { warn("重启失败，监督退出。"); exit(1) }
            print("采集器已重启（pid \(child!)）。")
        }

        // ② 回收已结束的生成任务，随即启动下一个。
        if let current = running, let code = CollectorSupervisor.reap(current.pid) {
            print(code == 0 ? "生成任务完成：\(current.label)" : "生成任务失败：\(current.label)（退出码 \(code)），请检查日志。")
            if current.label == "叙述层" { completedRealtime = true }
            let memoryCount = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("memories").path)) ?? []).count
            if current.label == "十分钟记忆", code == 0, memoryCount > memoryCountAtLaunch,
               ModelHealth.load(root: root)?.error == nil,
               backlog.completedSegmentIDs().contains(where: {
                   !FileManager.default.fileExists(atPath: root.appendingPathComponent("memories").appendingPathComponent(MemoryWriter.fileName(segmentID: $0)).path)
               }) { nextMemorize = Date() }
            running = nil
        }
        if let current = runningBackground, let code = CollectorSupervisor.reap(current.pid) {
            print(code == 0 ? "生成任务完成：\(current.label)" : "生成任务失败：\(current.label)（退出码 \(code)），请检查日志。")
            runningBackground = nil
        }
        if runningBackground == nil, !pendingBackground.isEmpty {
            let task = pendingBackground.removeFirst()
            let arguments = task.arguments + (flags.contains("--no-model") ? ["--no-model"] : [])
            if let pid = CollectorSupervisor.spawnDetachedChild(executable: exe, arguments: arguments) {
                runningBackground = (pid, task.label)
                print("生成任务启动：\(task.label)")
            }
        }
        if running == nil, !pending.isEmpty {
            let task = pending.removeFirst()
            if task.label == "十分钟记忆" {
                memoryCountAtLaunch = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("memories").path)) ?? []).count
            }
            let generationArguments = task.arguments + (flags.contains("--no-model") ? ["--no-model"] : [])
            if let pid = CollectorSupervisor.spawnDetachedChild(
                executable: exe, arguments: generationArguments) {
                running = (pid, task.label)
                print("生成任务启动：\(task.label)")
            }
        }

        // ③ 到点或收到手动请求时排队新一轮生成。上一轮未跑完时不重复排队。
        let control = CollectorControl.load(root: root)
        let sealed = Set(backlog.completedSegmentIDs())
        if !sealed.subtracting(observedSegments).isEmpty, memorizeInterval > 0 { nextMemorize = Date() }
        observedSegments = sealed
        if completedRealtime, control.summarizing, (memorizeInterval > 0 || backgroundRequested),
           Date() >= nextBackground, pendingBackground.isEmpty, runningBackground == nil {
            backgroundRequested = false
            nextBackground = Date().addingTimeInterval(memorizeInterval)
            pendingBackground = [
                GenerationTask(label: "日报／周报", arguments: ["report", "--out", root.path]),
                GenerationTask(label: "GitHub 私有备份", arguments: ["backup", "--automatic", "--out", root.path]),
            ]
        }
        let manual = control.flushRequested
        if (manual || memorizeInterval > 0), manual || Date() >= nextMemorize {
            // 上一轮没跑完时不排队，也**不清除请求标记**——清早了这次请求就丢了。
            // 手动请求最多积压一次：标记是布尔，连点多次与点一次等价。
            guard pending.isEmpty, running == nil else { continue }
            // 暂停总结时只保留采集。已经排队的任务跑完即可，不强杀。
            // 手动请求同样受开关约束——暂停是使用者的明确意图。
            guard control.summarizing else {
                if manual { try? CollectorControl.update(root: root, flushRequested: false) }
                continue
            }
            if manual {
                try? CollectorControl.update(root: root, flushRequested: false)
                backgroundRequested = true; nextBackground = Date()
                print("收到立即生成请求。")
            }
            nextMemorize = Date().addingTimeInterval(memorizeInterval)
            pending = [
                GenerationTask(label: "十分钟记忆",
                               arguments: ["memorize", "--out", root.path,
                                           "--limit", String(memorizeBatch), "--recent-first"]),
                // 叙述层只处理当天：更早的日期其记忆已稳定，不必反复归纳。
                GenerationTask(label: "叙述层",
                               arguments: ["narrative", "--out", root.path,
                                           "--day", todayLabel()]),
            ]
        }
    }
}

if flags.contains("--stop") {
    let root = outputRoot()
    guard let identity = CollectorProcessLease.runningIdentity(root: root) else {
        print("未找到身份可验证的运行中采集；未发送信号。")
        exit(0)
    }
    let pid = identity.pid
    // SIGINT 触发优雅收尾：封口当前 segment 并写出 metadata。
    guard identity.matchesLiveProcess, kill(pid, SIGINT) == 0 else {
        warn("采集进程已退出或无法发送停止信号。")
        exit(1)
    }
    print("已请求停止采集（pid \(pid)）。等待封口当前 segment…")
    for _ in 0..<50 {
        usleep(100_000)
        if !identity.matchesLiveProcess { break }
    }
    if identity.matchesLiveProcess {
        warn("进程 \(pid) 未在 5 秒内退出；如需强制结束：kill -9 \(pid)")
        exit(1)
    }
    print("已停止。")
    exit(0)
}

guard flags.contains("collect") else {
    usage()
    exit(1)
}

let root = outputRoot()
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

let processLease: CollectorProcessLease
do {
    processLease = try CollectorProcessLease(root: root)
} catch CollectorProcessLease.LeaseError.alreadyRunning {
    warn("目录已有采集实例：\(root.path)。请用 --status --out 查看，或用 --stop --out 停止。")
    // 监督脚本将此退出码视为无需重试的实例冲突。
    exit(73)
} catch {
    warn("无法取得采集锁（\(root.path)）：\(error)")
    exit(1)
}

// 先读配置（日志上限在其中），再接管输出。
var collectorConfig = loadConfig(root: root)
var configurationMonitor = CollectorConfigurationMonitor(root: root)
var lastConfigurationError: String?
redirectOutput(to: root.appendingPathComponent("collector.log"))
print("--- \(EventStreamJSON.timestampString(from: Date())) 启动 ---")

// 未获权限时不静默继续——那样只会产出缺一大半的数据。
let trusted = InputTap.hasAccessibilityPermission
if !trusted {
    warn("警告：未授予辅助功能权限，键盘/鼠标事件与 AX 树都无法采集。")
    warn("      运行 computer-history --check 查看详情。")
}

/// 本地时区的今天，格式 `yyyy-MM-dd`，与记忆文件的日期分组一致。
func todayLabel() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}

if !collectorConfig.windowTextApplications.isEmpty {
    NSApplication.shared.setActivationPolicy(.prohibited)
}
let session = CollectionSession(
    configuration: .init(rootDirectory: root, config: collectorConfig))
let windowTextSampler = WindowTextSampler()
let activityWatchSampler = ActivityWatchSampler()
session.isPaused = !CollectorControl.load(root: root).recording
let sampleInterval: TimeInterval = 1.0
let runSeconds = value(of: "--seconds").flatMap(Double.init)

do {
    try session.start()
} catch {
    warn("无法开始采集：\(error)")
    processLease.release()
    exit(1)
}

print("开始采集 → \(root.appendingPathComponent("segments").path)")
print("停止：Ctrl-C")
if let runSeconds { print("将在 \(Int(runSeconds)) 秒后自动停止。") }

/// 优雅收尾：Ctrl-C 与超时共用同一条封口路径，避免留下未写 metadata 的段。
///
/// 全程在主线程执行——`CGEventTap` 回调、`Timer` 与信号源都投递到主 runloop，
/// 因此无需额外加锁。
@MainActor
final class Shutdown {
    private var done = false
    private let session: CollectionSession
    private let root: URL
    private let lease: CollectorProcessLease

    init(session: CollectionSession, root: URL, lease: CollectorProcessLease) {
        self.session = session
        self.root = root
        self.lease = lease
    }

    @discardableResult
    func run() -> Int32 {
        guard !done else { return 0 }
        done = true
        windowTextSampler.update(nil) { _, _ in }
        activityWatchSampler.update(enabled: false) { _ in }
        defer { lease.release() }
        do { try session.stop() }
        catch {
            warn("停止采集时封口失败：\(error)。请检查存储空间和目录权限；该段尚未完成。")
            return 74
        }
        print("已停止。写入 \(session.totalEventsWritten) 条事件"
              + " → \(root.appendingPathComponent("segments").path)")
        if let p = session.lastPruneReport {
            print("已清理 \(p.removedSegments) 个旧 segment，"
                  + "释放 \(p.freedBytes / 1_048_576) MB")
        }
        return 0
    }
}
let shutdown = Shutdown(session: session, root: root, lease: processLease)

// Timer 与信号源都投递到主 runloop；显式标注 MainActor 以满足严格并发检查。
// COMPUTER_HISTORY_DEBUG_TEXT=1 时打印每轮看到的聚焦值，用于排查文本采集。
let debugText = ProcessInfo.processInfo.environment["COMPUTER_HISTORY_DEBUG_TEXT"] == "1"
var lastLogged: String? = nil
var debugTicks = 0

let timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { _ in
    MainActor.assumeIsolated {
        do {
            if let updated = try configurationMonitor.poll() {
                windowTextSampler.update(nil) { _, _ in }
                activityWatchSampler.update(enabled: false) { _ in }
                session.applyConfiguration(updated)
                collectorConfig = updated
                if !updated.windowTextApplications.isEmpty { NSApplication.shared.setActivationPolicy(.prohibited) }
                lastConfigurationError = nil
                print("采集配置已更新。")
            }
        } catch {
            let message = "采集配置未应用，继续使用上次有效设置：\(error)"
            if message != lastConfigurationError { warn(message) }
            lastConfigurationError = message
        }
        // 每周期读一次运行开关。文件很小，读取开销可忽略。
        let control = CollectorControl.load(root: root)
        let wasPaused = session.isPaused
        session.isPaused = !control.recording
        if wasPaused, !session.isPaused {
            print("已恢复记录。")
        } else if !wasPaused, session.isPaused {
            print("已暂停记录。")
        }
        session.sampleFrontmost()
        activityWatchSampler.update(enabled: collectorConfig.activityWatchEnabled && !session.isPaused && !session.isAway) { snapshot in
            guard CollectorControl.load(root: root).recording else { return }
            session.recordActivityWatch(snapshot)
        }
        // 文本输入按同一周期轮询；切块由跟踪器内部的停顿阈值决定，
        // 与采样周期解耦。
        session.sampleTextInput()
        windowTextSampler.update(session.windowTextContext, read: { pid, windowID in
            try await WindowTextReader.read(pid: pid, windowID: windowID, isAllowed: {
                await MainActor.run {
                    CollectorControl.load(root: root).recording
                        && FrontmostApplication.current()?.processIdentifier == pid
                }
            })
        }) { context, result in
            let current = FrontmostApplication.current()
            guard CollectorControl.load(root: root).recording,
                  current?.processIdentifier == context.app.processIdentifier,
                  FrontmostApplication.frontWindow(for: current) == context.window else { return }
            session.recordWindowText(result, context: context)
        }
        if debugText && !session.isPaused && !session.isAway {
            let app = FrontmostApplication.current()
            let window = FrontmostApplication.frontWindow(for: app)
            guard !collectorConfig.policy.shouldSuppress(app: app, window: window) else { return }
            let o = FrontmostApplication.focusedElementObservation(for: app)
            let v = o.value.map {
                "\($0)|caret=\(o.caret.map(String.init) ?? "-")"
                + "|editable=\(o.isEditableBuffer)|focus=\(o.focusIdentity.map(String.init) ?? "-")"
            }
            // 无条件打印前若干轮：用「值变化」做门槛会因值恒为 nil 而自我屏蔽。
            debugTicks += 1
            if debugTicks <= 5 || v != lastLogged {
                let shown = v.map { String($0.prefix(70)) } ?? "nil"
                warn("TEXT[\(debugTicks)] front=\(app?.bundleIdentifier ?? "?") "
                     + "pid=\(app?.processIdentifier.map(String.init) ?? "-") value=\(shown)")
                lastLogged = v
            }
        }
    }
}
RunLoop.current.add(timer, forMode: .common)

var tap: InputTap?
do {
    // tap 回调同样在主 runloop 上，故直接在主 actor 内归档。
    let t = InputTap { event in
      MainActor.assumeIsolated {
        switch event {
        case .leftMouseDown(let n, let flags, let location):
            session.noteInputActivity()
            session.recordClick(button: "left", clickCount: n,
                                modifiers: ModifierNames.names(from: flags), location: location)
        case .rightMouseDown(let n, let flags, let location):
            session.recordClick(button: "right", clickCount: n,
                                modifiers: ModifierNames.names(from: flags), location: location)
        case .otherMouseDown(let n, let flags, let location):
            session.recordClick(button: "middle", clickCount: n,
                                modifiers: ModifierNames.names(from: flags), location: location)
        case .keyDown(let keyCode, let flags, let isRepeat):
            session.noteInputActivity()
            guard !isRepeat else { break }
            let mods = ModifierNames.names(from: flags)
            // Shift/Option 可参与字符输入，只有操作组合键在此记录。
            if InputKey.action(for: keyCode, flags: flags) == .shortcut {
                session.recordShortcut(keyEquivalent: InputKey.name(for: keyCode), modifiers: mods)
            } else if InputKey.action(for: keyCode, flags: flags) == .submit {
                session.recordSubmit()
            }
        case .flagsChanged:
            break
        }
      }
    }
    try t.start()
    tap = t
} catch {
    warn("事件监听未启动：\(error)")
}

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    MainActor.assumeIsolated { () -> Void in exit(shutdown.run()) }
}
sigintSource.resume()

// 停止信号处理已就绪后才发布身份，避免启动期间收到信号而未封口。
do {
    try processLease.publish()
} catch {
    warn("无法写入采集进程身份：\(error)")
    shutdown.run()
    exit(1)
}

if let runSeconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + runSeconds) {
        MainActor.assumeIsolated { () -> Void in exit(shutdown.run()) }
    }
}

RunLoop.current.run()
