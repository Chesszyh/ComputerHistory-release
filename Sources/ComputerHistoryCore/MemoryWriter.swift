import Foundation

/// 把 `SegmentDigest` 写成与官方同构的记忆文件。
///
/// 官方产物形如
/// `~/.codex/memories/extensions/skysight/resources/<段时间>-<4位码>-10min-memory-summary.md`，
/// 结构为 frontmatter（title / description / applications）+ `## Memory summary`
/// （含 `### Relevant prior context`、`### Important non-obvious context about the user`）
/// + `## Recording summary`（按主题分小节）+ `## Citations`。
///
/// 本实现只写**可从事件直接证实**的内容：官方 `Memory summary` 里的判断性描述
/// （如「未观察到持续的开发工作」）出自语言模型，此处不臆造，改为给出可核对的
/// 活动事实。接入模型后可在 `enrichment` 处补写该段。
public enum MemoryWriter {

    /// 4 位标识码用的字母表（与官方文件名一致：大小写混合字母）。
    static let codeAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// 记忆文件名：`<段时间>-<4位码>-<粒度>-memory-summary.md`。
    ///
    /// 4 位码在官方产物中每份不同，作用是把同一时间窗的不同产物区分开。
    /// 这里由段 ID 稳定派生——同一段重复生成得到同名文件，便于幂等覆盖。
    public static func fileName(segmentID: String, granularity: String = "10min") -> String {
        let base = segmentID.split(separator: "_").first.map(String.init) ?? segmentID
        return "\(base)-\(stableCode(for: segmentID))-\(granularity)-memory-summary.md"
    }

    static func stableCode(for seed: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        var code = ""
        for _ in 0..<4 {
            code.append(codeAlphabet[Int(hash % UInt64(codeAlphabet.count))])
            hash /= UInt64(codeAlphabet.count)
        }
        return code
    }

    /// 渲染整份记忆。
    ///
    /// - Parameters:
    ///   - digest: 段摘要。
    ///   - eventsPath: 该段 `events.jsonl` 的绝对路径，写入 Citations。
    ///   - previousMemoryPath: 上一份记忆的路径，写入 Citations 以形成记忆链。
    ///   - enrichment: 语言模型补写的 `Memory summary` 正文；为空时该段用事实描述。
    public static func render(
        digest: SegmentDigest,
        eventsPath: String,
        previousMemoryPath: String? = nil,
        enrichment: String? = nil,
        modelNote: String? = nil,
        granularity: String = "10min",
        sources: [String] = [],
        titleOverride: String? = nil,
        evidenceMaterial: String? = nil
    ) -> String {
        var out = ""

        out += "---\n"
        let heading = titleOverride ?? title(for: digest)
        let summary = granularity == "6h"
            ? sixHourDescription(for: digest) : description(for: digest)
        out += "title: \(heading)\n"
        out += "description: \(summary)\n"
        out += "generation: \(enrichment != nil ? "model" : (modelNote != nil ? "failed" : "factual"))\n"
        out += "applications: [" + digest.applications.joined(separator: ", ") + "]\n"
        out += "---\n\n"

        out += "## Memory summary\n\n"
        if let enrichment, !enrichment.isEmpty {
            // 模型已按系统提示产出 Relevant prior context 等小节，此处不再补写，
            // 否则会出现两个同名小节。
            out += enrichment.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        } else {
            // 无模型时才由本地补出这些小节——它们需要跨段信息，本实现只写有据可依的。
            out += factualSummary(for: digest) + "\n\n"
            out += "### Relevant prior context\n\n"
            if let previousMemoryPath {
                out += "本段之前一次记录见 `\(previousMemoryPath)`。\n\n"
            } else {
                out += "无此前记录。\n\n"
            }
            out += "### Important non-obvious context about the user\n\n"
            if let modelNote {
                out += "- 本节未由语言模型归纳：\(modelNote)\n"
            } else {
                out += "- 本节只记录可由事件证实的事实，不作特征归纳。\n"
            }
            out += "\n"
        }

        out += "## Recording summary\n\n"
        for activity in digest.activities {
            out += recordingSection(for: activity) + "\n"
        }
        // recordingSection 已以换行收尾，此处再补一个即形成小节间单空行。

        if let evidenceMaterial, !evidenceMaterial.isEmpty {
            out += "### 时序证据\n\n" + evidenceMaterial + "\n"
        }
        out += "## Citations\n\n"
        out += "- \(eventsPath)\n"
        // 粗粒度汇总引用它所归纳的各份细粒度记忆。
        for source in sources { out += "- \(source)\n" }
        if let previousMemoryPath, !sources.contains(previousMemoryPath) {
            out += "- \(previousMemoryPath)\n"
        }
        _ = granularity
        return out
    }

    // MARK: - 各段渲染

    /// 标题取自主应用与其首个窗口标题，避免空泛。
    static func title(for digest: SegmentDigest) -> String {
        guard let top = digest.dominantActivity else { return "无应用活动的记录段" }
        guard let window = top.windowTitles.first, !window.isEmpty else {
            return top.displayName
        }
        let cleaned = stripAppSuffix(window, appName: top.displayName)
        // 窗口名不含额外信息时（等于应用名，或去掉应用名后为空）只写应用名，
        // 否则会得到「ChatGPT：ChatGPT」这种重复。
        if cleaned.isEmpty || cleaned == top.displayName { return top.displayName }
        return "\(top.displayName)：\(truncate(cleaned, 40))"
    }

    /// 去掉窗口标题尾部的应用名。
    ///
    /// 浏览器等应用的窗口标题本身就带应用名（`… - Google Chrome`），
    /// 再前置一次会得到「Google Chrome：… - Google Chrome」这种重复。
    static func stripAppSuffix(_ title: String, appName: String) -> String {
        for separator in [" - ", " — ", " – "] {
            let suffix = separator + appName
            if title.hasSuffix(suffix) {
                return String(title.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    static func description(for digest: SegmentDigest) -> String {
        guard !digest.activities.isEmpty else {
            return "本段未记录到应用活动。"
        }
        let span = digest.endedAt.timeIntervalSince(digest.startedAt)
        var parts: [String] = []
        parts.append("本段约 \(Int(span / 60)) 分钟，记录 \(digest.eventCount) 条事件，"
                     + "涉及 \(digest.activities.count) 个应用。")
        let top = digest.activities.prefix(3).map(\.displayName).joined(separator: "、")
        parts.append("主要使用 \(top)。")
        if digest.suppressedEventCount > 0 {
            parts.append("另有 \(digest.suppressedEventCount) 条事件按观测策略抑制。")
        }
        return parts.joined()
    }

    /// 粗粒度汇总的描述：说明时间窗与窗口内**确实记录到**的范围。
    ///
    /// 用「各段首末事件跨度之和」而不是 `endedAt - startedAt`：后者是首末记录的
    /// 跨度，会把段间与段内的大片空白算成活动（实测某六小时记忆声称约 74 分钟活动，
    /// 而各段跨度相加仅 9.75 分钟）。措辞也不说「活动时长」——
    /// 即便相加，也只是各段内有活动的时间下界。
    static func sixHourDescription(for digest: SegmentDigest) -> String {
        guard !digest.activities.isEmpty else { return "本时段未记录到应用活动。" }
        let span = digest.recordedSpan
        let top = digest.activities.prefix(3).map(\.displayName).joined(separator: "、")
        var parts = "六小时时段内共 \(digest.coveredSegments) 段有记录，"
        parts += "各段首末事件跨度合计约 \(Int(span / 60)) 分钟"
        if span < 60 { parts += "（不足一分钟）" }
        parts += "，\(digest.eventCount) 条事件，涉及 \(digest.activities.count) 个应用。"
        parts += "主要使用 \(top)。"
        return parts
    }

    /// 无模型时的 `Memory summary` 正文：只列可核对的事实。
    static func factualSummary(for digest: SegmentDigest) -> String {
        guard let top = digest.dominantActivity else {
            return "本段未记录到应用活动。"
        }
        var lines: [String] = []
        let span = digest.endedAt.timeIntervalSince(digest.startedAt)
        lines.append("本段覆盖 \(format(digest.startedAt)) 至 \(format(digest.endedAt))"
                     + "（约 \(Int(span / 60)) 分钟）。")
        lines.append("活动最集中的是 \(top.displayName)（\(top.eventCount) 条事件"
                     + "\(top.clickCount > 0 ? "，\(top.clickCount) 次点击" : "")"
                     + "\(top.shortcutCount > 0 ? "，\(top.shortcutCount) 次快捷键" : "")）。")
        if !top.windowTitles.isEmpty {
            lines.append("其窗口标题包括："
                         + top.windowTitles.prefix(3).map { "「\(truncate($0, 40))」" }
                            .joined(separator: "、") + "。")
        }
        return lines.joined(separator: "\n\n")
    }

    static func recordingSection(for activity: SegmentDigest.AppActivity) -> String {
        var out = "### \(activity.displayName)\n\n"
        let span = activity.duration
        out += "- 活跃时段 \(format(activity.firstSeen))–\(format(activity.lastSeen))"
        out += "（约 \(Int(span / 60)) 分钟），共 \(activity.eventCount) 条事件。\n"

        var counts: [String] = []
        if activity.clickCount > 0 { counts.append("点击 \(activity.clickCount) 次") }
        if activity.shortcutCount > 0 { counts.append("快捷键 \(activity.shortcutCount) 次") }
        if !activity.typedTexts.isEmpty {
            counts.append("文本值变化 \(activity.typedTexts.count) 段")
        }
        if !counts.isEmpty {
            out += "- \(counts.joined(separator: "，"))。\n"
        }

        if !activity.urls.isEmpty {
            out += "- 访问地址："
            out += activity.urls.prefix(5).map { "`\(truncate($0, 80))`" }
                .joined(separator: "、")
            if activity.urls.count > 5 { out += " 等 \(activity.urls.count) 个" }
            out += "。\n"
        }

        out += textEvidenceSection(for: activity)
        return out
    }

    private static let editedTextLabel = "编辑片段"
    private static let uncertainTextLabel = "控件变化"

    /// 模型取材和本地事实版本共用，证据级别与引用不能在渲染时丢失。
    static func textEvidenceSection(for activity: SegmentDigest.AppActivity, limit: Int = 20) -> String {
        let excerpts = activity.selectedTextExcerpts(limit: limit)
        var out = ""
        for (edited, label) in [(true, editedTextLabel), (false, uncertainTextLabel)] {
            let group = excerpts.filter { ($0.evidence == .editedValue) == edited }
            guard !group.isEmpty else { continue }
            out += "- \(label)：\n"
            for item in group {
                var revision = item.wasReplaced ? "后续已覆盖部分或全部内容；" : ""
                if !item.replaces.isEmpty { revision += "覆盖来源 \(item.replaces.joined(separator: ", "))；" }
                out += "  - [\(revision)\(format(item.timestamp)); \(item.segmentID)#\(item.eventID)] `\(escape(truncate(item.text, 200)))`\n"
            }
        }
        return out
    }

    /// 从记忆文件里取出 frontmatter 的 title 与 description。
    ///
    /// 只做最简单的 `键: 值` 解析——这两个字段由本模块自己写出，
    /// 不含引号包裹或跨行等复杂形态。缺失时返回空串，不猜。
    public static func parseFrontmatter(_ text: String)
        -> (title: String, description: String) {
        var title = "", description = ""
        var inFrontmatter = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" {
                if inFrontmatter { break }
                inFrontmatter = true
                continue
            }
            guard inFrontmatter else { continue }
            if line.hasPrefix("title: ") {
                title = String(line.dropFirst("title: ".count))
            } else if line.hasPrefix("description: ") {
                description = String(line.dropFirst("description: ".count))
            }
        }
        return (title, description)
    }

    // MARK: - 工具

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func truncate(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// 反引号内的内容不能含反引号，否则会破坏 Markdown 结构。
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "'")
    }
}
