import Foundation

/// 生成前端叙述条目：把十分钟记忆汇总成便于扫读的活动索引。
///
/// 与 `MemoryGenerator` 的分工：那个产出可追溯的记忆文件（含事件路径、完整分节），
/// 本类型产出面向快速回忆的条目（标题 + 一两句 + 时刻 + 应用）。
/// 两者都写盘，托盘优先展示叙述条目，缺失时回退到记忆标题。
public struct NarrativeGenerator: Sendable {

    /// 一次生成的结果。
    ///
    /// `newItems` 与 `totalItems` 分开：增量模式下两者差异很大，
    /// 混用会让「本次归纳了几条」的汇报变成「缓存里一共有几条」。
    public struct Outcome: Sendable {
        public var day: String
        /// 本次新增或重写的条目数。
        public var newItems: Int
        /// 该日在缓存中的条目总数。
        public var totalItems: Int
        public var usedModel: Bool
        public var usage: DeepSeekClient.Usage?
    }

    public enum GenerateError: Error, CustomStringConvertible {
        case noSourceMemories
        case modelFailed(String)

        public var description: String {
            switch self {
            case .noSourceMemories: return "没有可用于归纳的记忆文件"
            case .modelFailed(let detail): return "模型调用失败：\(detail)"
            }
        }
    }

    public let rootDirectory: URL
    public let memoriesDirectory: URL
    public let client: DeepSeekClient?

    public init(rootDirectory: URL, client: DeepSeekClient?) {
        self.rootDirectory = rootDirectory
        self.memoriesDirectory = rootDirectory.appendingPathComponent("memories")
        self.client = client
    }

    /// 为指定日期（本地时区的 `yyyy-MM-dd`）生成叙述条目。
    ///
    /// 只归纳该日的十分钟记忆；六小时记忆是更粗的层次，不参与——否则同一段活动
    /// 会被写两遍。
    public func generate(day: String, overwrite: Bool = false) throws -> Outcome {
        let index = MemoryIndex.load(from: memoriesDirectory)
        let sources = index.entries
            .filter { $0.granularity == "10min" && $0.dayLabel() == day }
            .sorted { $0.startedAt < $1.startedAt }
        guard !sources.isEmpty else { throw GenerateError.noSourceMemories }

        var narrative = ActivityNarrative.load(root: rootDirectory)
        // 覆盖判断按**来源集合的并集**，不是按条数。合并后的条目数少于源数，
        // 用「条数 == 源数」会让已完整的日期被反复重新生成、重复计费。
        let sourceNames = Set(sources.map { $0.fileURL.lastPathComponent })
        var covered = Set(narrative.items.flatMap(\.sourceMemories))
        if !overwrite, sourceNames.isSubset(of: covered) {
            return Outcome(day: day, newItems: 0,
                           totalItems: Self.countItems(narrative, on: day),
                           usedModel: false, usage: nil)
        }

        // **只归纳尚未覆盖的部分**。此前每轮重算全天：一轮两万余 tokens、
        // 且随当天累积越来越慢，把生成周期撑长，记忆与叙述双双落后于采集。
        // 增量后单轮开销与「新增活动量」成正比，而不是与「当天总量」成正比。
        var pending = sources
        var priorItems: [ActivityNarrative.Item] = []
        if !overwrite {
            pending = sources.filter { !covered.contains($0.fileURL.lastPathComponent) }
            // 取最近几条已有条目作为续写上下文，避免新条目丢掉前文承接。
            priorItems = narrative.items
                .filter { $0.timestamp < (pending.first?.startedAt ?? Date.distantFuture) }
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(4)
            if pending.isEmpty {
                return Outcome(day: day, newItems: 0,
                               totalItems: Self.countItems(narrative, on: day),
                               usedModel: false, usage: nil)
            }
        }

        guard let client else {
            // 无模型时用记忆的标题与描述原样充当条目：信息不如模型精炼，
            // 但保持可用，且不假装已经过归纳。
            let fallback = sources.map { entry in
                ActivityNarrative.Item(
                    id: Self.itemID(for: [entry.fileURL.lastPathComponent]),
                    timestamp: entry.startedAt,
                    title: entry.title,
                    summary: entry.summary,
                    apps: entry.applications,
                    sourceMemories: [entry.fileURL.lastPathComponent])
            }
            narrative.items.removeAll { item in
                sources.contains { $0.fileURL.lastPathComponent == item.sourceMemories.first }
            }
            narrative.items.append(contentsOf: fallback)
            narrative.items.sort { $0.timestamp > $1.timestamp }
            narrative.generatedAt = Date()
            try narrative.save(root: rootDirectory)
            return Outcome(day: day, newItems: fallback.count,
                           totalItems: Self.countItems(narrative, on: day),
                           usedModel: false, usage: nil)
        }

        let completion = try client.complete(
            system: Self.systemPrompt,
            user: Self.userPrompt(day: day, sources: pending,
                                  priorItems: priorItems),
            // 一天的记忆可能有二十余段，提示词较大，推理开销随之上升；
            // 上限过低会在推理阶段耗尽预算导致正文为空。
            maxTokens: 12000)
        let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw GenerateError.modelFailed(
                completion.truncatedByBudget
                    ? "输出预算被推理耗尽（推理 \(completion.usage?.reasoningTokens ?? 0) token）"
                    : "模型返回空内容")
        }
        let items = Self.parseItems(text, sources: sources, claimed: pending)
        guard !items.isEmpty else {
            throw GenerateError.modelFailed("输出中没有可解析的条目")
        }

        // 覆盖写时清掉同日旧条目；增量时只清掉本次重新覆盖到的那部分。
        let toReplace = overwrite
            ? sourceNames
            : Set(items.flatMap(\.sourceMemories))
        narrative.items.removeAll { item in
            !toReplace.isDisjoint(with: item.sourceMemories)
        }
        narrative.items.append(contentsOf: items)
        covered.formUnion(items.flatMap(\.sourceMemories))
        narrative.items.sort { $0.timestamp > $1.timestamp }
        narrative.generatedAt = Date()
        try narrative.save(root: rootDirectory)

        return Outcome(day: day, newItems: items.count,
                       totalItems: Self.countItems(narrative, on: day),
                       usedModel: true, usage: completion.usage)
    }

    /// 为所有有十分钟记忆、但尚无叙述条目的日期补写。
    public func generateMissing(limit: Int? = nil, overwrite: Bool = false) -> [Outcome] {
        let index = MemoryIndex.load(from: memoriesDirectory)
        let days = Set(index.entries.filter { $0.granularity == "10min" }
            .map { $0.dayLabel() }).sorted()
        var outcomes: [Outcome] = []
        for day in days {
            if let limit, outcomes.count >= limit { break }
            do {
                let outcome = try generate(day: day, overwrite: overwrite)
                // 无新增的日期不计入结果——否则「处理了几天」会被误读为「生成了几条」。
                if outcome.newItems > 0 { outcomes.append(outcome) }
            } catch GenerateError.noSourceMemories {
                continue
            } catch {
                FileHandle.standardError.write(
                    "\(day) 叙述生成失败：\(error)\n".data(using: .utf8)!)
            }
        }
        return outcomes
    }

    /// 某日在缓存中的条目数。
    static func countItems(_ narrative: ActivityNarrative, on day: String) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return narrative.items.filter { f.string(from: $0.timestamp) == day }.count
    }

    static func itemID(for sourceMemories: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for name in sourceMemories.sorted() {
            for byte in name.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - 输出解析

    /// 解析模型输出。约定每条形如：
    ///
    ///     ## <时刻> <标题>
    ///     <摘要>
    ///
    /// 时刻取该条覆盖的源记忆中最早的一个——模型不必复述精确时间，
    /// 由本方法按顺序回填，避免它编造时刻。
    /// 解析模型输出。
    ///
    /// - Parameters:
    ///   - sources: **当天全部**来源。用于解析标题里的 `HH:MM`——增量模式下模型
    ///     可能引用前文或跨界的时刻，只用新增来源建表会查不到，时刻就剥不掉，
    ///     标题会变成「18:25 在 Gemini 讨论…」。
    ///   - claimed: 本次实际可认领的来源。覆盖范围只在此范围内计算，避免增量
    ///     生成时把早已归属他人的来源重复计入。
    static func parseItems(_ text: String,
                           sources: [MemoryIndex.Entry],
                           claimed: [MemoryIndex.Entry]? = nil) -> [ActivityNarrative.Item] {
        // 模型会合并同任务的段，因此**不能按下标**回填时刻——合并后条数少于段数，
        // 对应关系即断裂（实测会得到与摘要内容矛盾的时间）。
        // 改为要求模型照抄所覆盖**首段**的时刻，再据此在校验表里定位；
        // 覆盖范围由相邻两条的起始时刻界定，从而记录**完整**的来源集合。
        var byTime: [String: Int] = [:]      // 时刻 → 源下标
        for (index, entry) in sources.enumerated() {
            byTime[entry.timeLabel()] = index
        }

        let claimable = claimed ?? sources
        let claimNames = Set(claimable.map { $0.fileURL.lastPathComponent })
        // 认领只能落在本次可认领的来源上。
        let claimIndices = sources.indices.filter {
            claimNames.contains(sources[$0].fileURL.lastPathComponent)
        }
        let firstClaim = claimIndices.first ?? 0

        var parsed: [(declaredIndex: Int, title: String, summary: String)] = []
        var currentHeading: String?
        var buffer: [String] = []

        func flush() {
            guard let heading = currentHeading else { return }
            defer { buffer = [] }
            let summary = buffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }

            var title = heading
            var sourceIndex: Int?
            if let space = heading.firstIndex(of: " ") {
                let head = String(heading[heading.startIndex..<space])
                if let idx = Self.parseDeclaredTime(head, lookup: byTime) {
                    sourceIndex = idx
                    title = String(heading[heading.index(after: space)...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            guard !title.isEmpty else { return }
            // 未声明或声明了不存在的时刻：退回到「上一个未使用的源」，
            // 且不得早于第一个可认领的来源。
            var resolved = sourceIndex ?? (parsed.last.map { $0.declaredIndex + 1 } ?? firstClaim)
            if !claimIndices.contains(resolved) {
                resolved = claimIndices.first { $0 >= resolved } ?? firstClaim
            }
            parsed.append((min(resolved, sources.count - 1), title, summary))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                buffer.append(line)
            }
        }
        flush()

        // 覆盖范围按**声明时刻排序后**确定：每条覆盖到下一个更大的起点（不含），
        // 最大的一条覆盖到末尾。不能按输出顺序取「下一条」——模型可能乱序输出，
        // 那样最后一条会错误地覆盖到末尾并吞掉前面的来源。
        //
        // 且**同一来源只能被一条认领**。增量模式下可认领的来源可能只有一份，而模型
        // 仍会输出多条；若允许共享，多条会得到同一个来源集合，进而算出同一个 id，
        // 在 ForEach 里造成重复渲染——实测面板上出现过三条完全相同的内容。
        let order = parsed.indices.sorted { parsed[$0].declaredIndex < parsed[$1].declaredIndex }
        var endByItem: [Int: Int] = [:]
        var cursor = firstClaim
        for (position, itemIndex) in order.enumerated() {
            // 起点不得早于已分配到的位置。
            let start = max(parsed[itemIndex].declaredIndex, cursor)
            var end = sources.count
            if position + 1 < order.count {
                end = max(parsed[order[position + 1]].declaredIndex, start + 1)
            }
            endByItem[itemIndex] = end
            // 推进游标：下一条只能从本条之后开始。
            cursor = max(cursor, end)
        }

        var claimedIndices = Set<Int>()
        return parsed.indices.compactMap { position -> ActivityNarrative.Item? in
            let item = parsed[position]
            var start = item.declaredIndex
            while start < sources.count, claimedIndices.contains(start) { start += 1 }
            let end = endByItem[position] ?? sources.count
            // 覆盖范围必须落在可认领的来源内——增量生成时，区间里可能混进
            // 早已归属其他条目的来源。
            let covered = Array(sources[start..<min(end, sources.count)])
                .filter { claimNames.contains($0.fileURL.lastPathComponent) }
            guard !covered.isEmpty else {
                // 该条没有认领到任何新来源，丢弃而不是编造归属。
                return nil
            }
            for entry in covered {
                if let idx = sources.firstIndex(where: {
                    $0.fileURL.lastPathComponent == entry.fileURL.lastPathComponent
                }) { claimedIndices.insert(idx) }
            }
            let names = covered.map { $0.fileURL.lastPathComponent }
            return ActivityNarrative.Item(
                // id 并入标题：同一批来源可能产出多条（模型把一段拆成多个活动），
                // 只用来源集合做 id 会撞车，ForEach 遇到重复 id 会渲染错乱。
                id: itemID(for: names + [item.title]),
                timestamp: sources[start].startedAt,
                title: item.title,
                summary: item.summary,
                // 应用取覆盖范围的并集，保序去重。
                apps: covered.reduce(into: [String]()) { acc, entry in
                    for app in entry.applications where !acc.contains(app) { acc.append(app) }
                },
                sourceMemories: names)
        }
    }

    /// 解析 `HH:MM` 并查表。非法（如 `99:99`）或不存在时返回 nil。
    static func parseDeclaredTime(_ raw: String, lookup: [String: Int]) -> Int? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        // 归一成两位，避免模型写成 `9:05` 时查不到。
        let normalized = String(format: "%02d:%02d", hour, minute)
        return lookup[normalized]
    }

    // MARK: - 提示词

    /// 系统提示按使用者给定的规格撰写：目标是活动索引而非工作报告。
    public static let systemPrompt = """
    你的任务是将一段时间内采集的计算机活动事件，整理成活动记录。
    目标不是生成工作报告，而是生成便于用户快速回忆、定位和恢复上下文的活动索引。

    输出格式：每条记录写作 `## HH:MM 标题`，紧随其后另起一行写摘要。
    `HH:MM` 必须是该条**覆盖的第一段**在输入中给出的时刻，照抄即可，不要自己换算
    或推测。标题与摘要之间不要空行，条目之间空一行。不要输出其它标题或前言。

    标题规则：
    1. 使用「动词 + 对象」结构，通常控制在 8–20 个汉字。
    2. 优先使用准确的行为动词，例如查看、检索、对照、审阅、配置、验证、调试、修改、提交。
    3. 保留重要项目名、应用名和技术名称。
    4. 不添加「用户」「进行」「相关操作」「工作进展」等无意义表达。
    5. 不得将讨论、计划、尝试描述为已经完成的工作。

    摘要规则：
    1. 使用第二人称「你」，通常写 1–2 句话，建议 50–110 个汉字。
    2. 优先描述「任务目标 → 关键操作 → 实际结果或当前状态」。
    3. 只保留能够区分本次活动与其他活动的关键细节。
    4. 将同一任务涉及的多个窗口、应用和工具调用合并为连贯的活动，而不是逐项罗列。
    5. 明确区分意图、尝试、实际执行与已验证结果。
    6. 如果存在失败、阻塞、未完成或未验证的状态，应当保留。
    7. 不推测用户的情绪、动机或没有证据支持的行为。

    语言风格：
    - 信息密度高，表达自然、客观、克制。
    - 不使用 Markdown 强调、项目符号或章节标题。
    - 不使用「首先」「其次」「最后」等流程连接词。
    - 避免「深入研究」「全面分析」「成功完成」「进一步优化」等没有具体证据支撑的笼统表述。
    - 不添加评价、建议、总结感悟或下一步行动。

    压缩原则：每条记录只保留三个问题的答案——用户主要在做什么？
    发生了哪些值得保留的关键操作？最终产生了什么可观察的结果，或者停在什么状态？

    生成后进行一次自检：删除重复信息、冗余修饰、无意义的过程描述，
    并检查是否将用户意图误写成实际完成的结果。
    对重要事实缺乏证据时，应使用「尝试」「查看」「请求」「尚未确认」等准确措辞，
    不得自行补全结果。
    """

    static func userPrompt(day: String, sources: [MemoryIndex.Entry],
                           priorItems: [ActivityNarrative.Item] = []) -> String {
        var out = ""
        if !priorItems.isEmpty {
            // 增量续写：给出最近的已有条目，让新条目在措辞与视角上衔接，
            // 不重复已经写过的事。
            out += "## 今天此前的活动记录（仅供衔接，不要重复输出）\n"
            for item in priorItems {
                out += "- 《\(item.title)》：\(String(item.summary.prefix(120)))\n"
            }
            out += "\n"
        }
        out += "## 待整理的新增活动（\(day)）\n"
        out += "以下是按时序排列的 \(sources.count) 段十分钟活动记录。"
        out += "请把它们合并整理成若干条活动记录，条数由内容决定——"
        out += "同一任务的多段应合并，不同任务应分开。"
        if !priorItems.isEmpty {
            out += "只输出**新增**的活动，不要重复上面已列出的内容。"
        }
        out += "\n\n"
        for entry in sources {
            out += "### 时刻 \(entry.timeLabel())\n"
            out += "标题：\(entry.title)\n"
            out += "摘要：\(entry.summary)\n"
            if !entry.applications.isEmpty {
                out += "应用：\(entry.applications.joined(separator: "、"))\n"
            }
            // 正文里的叙事小节含更多细节，但过长会撑爆提示词，故截断。
            let detail = entry.sections
                .filter { !$0.heading.contains("Important") && !$0.heading.contains("prior") }
                .map(\.content).joined(separator: " ")
            if !detail.isEmpty {
                out += "细节：\(String(detail.prefix(400)))\n"
            }
            out += "\n"
        }
        return out
    }
}
