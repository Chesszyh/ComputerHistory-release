import Foundation

/// 有界的时序材料同时保留应用上下文、编辑归属和界面结果，供各总结层复用。
public enum ActivityEvidence {
    public static func material(events: [EventStreamRecord], segmentID: String,
                                characterBudget: Int = 16000) -> String {
        var observations: [(reference: String, context: String, facts: [String], nodes: [String], hasContent: Bool)] = []
        var lastContext: String?
        let replaced = Set(events.flatMap { $0.keyboard?.textReplaces ?? [] })
        for event in events {
            guard let app = event.app else { continue }
            let context = [app.name ?? app.bundleIdentifier ?? "应用",
                           event.window?.title, event.window?.url].compactMap { $0 }.joined(separator: " | ")
            let reference = "[\(MemoryGenerator.hm(event.timestamp)); \(segmentID)#\(event.id)] \(context)"
            var facts: [String] = []
            var selectedNodes: [String] = []
            var hasContent = false
            if let activity = event.activityWatch {
                let state = activity.status == "afk" ? "空闲" : activity.status == "not-afk" ? "活动" : "状态未知"
                let seconds = Int(max(0, activity.endedAt.timeIntervalSince(activity.startedAt)))
                facts.append("ActivityWatch：\(state)，观测区间 \(seconds) 秒（窗口与网址元数据）")
            }
            if let keyboard = event.keyboard {
                if let text = keyboard.text, !text.isEmpty,
                   (keyboard.textEvidence == .editedValue || !isChatChrome(text, app: app)),
                   !(keyboard.target?.placeholder == text && keyboard.textEvidence != .editedValue),
                   !replaced.contains("\(segmentID)#\(event.id)") {
                    let label = keyboard.textEvidence == .editedValue ? "编辑片段" : "控件变化"
                    facts.append("\(label)：\(MemoryWriter.truncate(text, 2400))")
                    hasContent = true
                }
            }
            if let target = event.mouse?.target {
                if let label = [target.title, target.description].compactMap({ $0 }).first,
                   !isChatChrome(label, app: app) {
                    facts.append("点击：\(MemoryWriter.truncate(label, 100))")
                    hasContent = true
                }
            }
            if let ax = event.ax {
                // 按渲染节点切分，续行仍属于该节点；不能把旧差分的 ~ 续行误作新增内容。
                let nodes = screenNodes(ax).filter { !isChatChrome($0, app: app) }.map {
                    ax.source == "window_ocr" && $0.hasPrefix("Value: ") ? String($0.dropFirst(7)) : $0
                }
                selectedNodes = nodes
                if !selectedNodes.isEmpty { hasContent = true }
                else if ax.mode == .fullTree, nodes.isEmpty {
                    facts.append("仅记录到应用或窗口，未读取到有效正文")
                }
            }
            if facts.isEmpty, selectedNodes.isEmpty, event.kind == .windowChanged, context != lastContext {
                facts.append("查看窗口")
            }
            lastContext = context
            if !facts.isEmpty || !selectedNodes.isEmpty {
                observations.append((reference, context, facts, selectedNodes, hasContent))
            }
        }
        // 有正文时先覆盖正文的时序，重复的窗口与空闲元数据不能挤掉已采集内容。
        let content = observations.filter(\.hasContent)
        let selected = evenlySpaced(content.isEmpty ? observations : content, limit: max(1, characterBudget / 650))
        let slotBudget = max(0, characterBudget / max(1, selected.count) - 2)
        guard slotBudget > 0 else { return "" }
        var out = ""
        var seenScreen = Set<String>()
        for item in selected {
            var text = item.reference + "\n" + item.facts.joined(separator: "\n")
            if !item.nodes.isEmpty {
                let available = max(0, slotBudget - text.count - 8)
                // 只对最终选入材料的节点去重，未入选节点留给后续快照。
                let fresh = item.nodes.filter { !seenScreen.contains(item.context + "\n" + $0) }
                let full = fresh.joined(separator: "；")
                let nodes = full.count <= available ? fresh : evenlySpaced(fresh, limit: max(1, available / 80))
                if nodes.isEmpty, item.facts.isEmpty { continue }
                let perNode = max(1, available / max(1, nodes.count) - 1)
                let body = full.count <= available ? full
                    : nodes.map { MemoryWriter.truncate($0, perNode) }.joined(separator: "；")
                if !nodes.isEmpty { text += "\n界面显示：" + body }
                for node in nodes { seenScreen.insert(item.context + "\n" + node) }
            }
            if text.count > slotBudget { text = String(text.prefix(slotBudget - 1)) + "…" }
            out += text + "\n\n"
        }
        return out
    }

    static func evenlySpaced<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard values.count > limit else { return values }
        if limit == 1 { return [values[values.count - 1]] }
        return (0..<limit).map { values[$0 * (values.count - 1) / (limit - 1)] }
    }

    static func screenNodes(_ ax: EventStreamAXTree) -> [String] {
        var result: [String] = [], buffer = ""
        var include = false
        func appendNode() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(MemoryWriter.truncate(text, 1400)) }
        }
        for raw in ax.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = AXTextParser.parseLine(String(raw), mode: ax.mode)
            switch line {
            case .element(_, _, nil, _, _):
                if include, buffer.count < 1600 { buffer += " " + String(raw.prefix(1600 - buffer.count)) }
            case .element(let marker, _, _, _, let detail):
                appendNode()
                include = ax.mode == .fullTree || marker == "+"
                // 元素编号和 role 是树结构，不能解释为窗口数量或活动内容。
                buffer = include ? readableDetail(detail ?? "") : ""
            case .continuation(let text) where include:
                if buffer.count < 1600 { buffer += " " + String(text.prefix(1600 - buffer.count)) }
            default: break
            }
        }
        appendNode()
        return result
    }

    private static func readableDetail(_ detail: String) -> String {
        let text = detail
            .replacingOccurrences(of: #"^\([^)]*\)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?:^|, )ID: [^,]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^_?[A-Za-z][A-Za-z0-9_]*:$"#, options: .regularExpression) != nil { return "" }
        return text
    }

    static func isChatChrome(_ text: String, app: EventStreamApp) -> Bool {
        guard ["com.google.Chrome", "com.openai.chat", "com.openai.codex"].contains(app.bundleIdentifier ?? "") else { return false }
        let value = text.replacingOccurrences(of: #"^(?:Title|Value|Description|Placeholder):\s*"#,
            with: "", options: .regularExpression).filter { !$0.isWhitespace }
        return ["询问ChatGPT", "询问ChatGPT…", "询问ChatGPT...", "重新生成回复", "回答已完成"].contains(value)
    }

    static func summary(in text: String, limit: Int = 1800) -> String {
        let sections = MemoryIndex.parseSections(MemoryIndex.stripFrontmatter(text))
        let narrative = sections.filter {
            ["本次活动", "整体走向", "延续的工作线"].contains($0.heading)
        }.map(\.content).joined(separator: "\n")
        return String((narrative.isEmpty ? MemoryWriter.parseFrontmatter(text).description : narrative).prefix(limit))
    }
}
