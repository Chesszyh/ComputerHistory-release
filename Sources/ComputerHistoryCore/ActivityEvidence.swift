import Foundation

/// 有界的时序材料同时保留应用上下文、编辑归属和界面结果，供各总结层复用。
public enum ActivityEvidence {
    public static func material(events: [EventStreamRecord], segmentID: String,
                                characterBudget: Int = 16000) -> String {
        var observations: [String] = []
        var seenScreen = Set<String>()
        let replaced = Set(events.flatMap { $0.keyboard?.textReplaces ?? [] })
        for event in events {
            guard let app = event.app else { continue }
            let context = [app.name ?? app.bundleIdentifier ?? "应用",
                           event.window?.title, event.window?.url].compactMap { $0 }.joined(separator: " | ")
            let reference = "[\(MemoryGenerator.hm(event.timestamp)); \(segmentID)#\(event.id)] \(context)"
            var facts: [String] = []
            if let keyboard = event.keyboard {
                if let text = keyboard.text, !text.isEmpty,
                   (keyboard.textEvidence == .editedValue || !isChatChrome(text, app: app)),
                   !(keyboard.target?.placeholder == text && keyboard.textEvidence != .editedValue),
                   !replaced.contains("\(segmentID)#\(event.id)") {
                    let label = keyboard.textEvidence == .editedValue ? "编辑片段" : "控件变化"
                    facts.append("\(label)：\(MemoryWriter.truncate(text, 2400))")
                }
            }
            if let target = event.mouse?.target {
                if let label = [target.title, target.description].compactMap({ $0 }).first,
                   !isChatChrome(label, app: app) {
                    facts.append("点击：\(MemoryWriter.truncate(label, 100))")
                }
            }
            if let ax = event.ax {
                // 按渲染节点切分，续行仍属于该节点；不能把旧差分的 ~ 续行误作新增内容。
                let nodes = screenNodes(ax).filter { !isChatChrome($0, app: app) }
                let fresh = nodes.filter { seenScreen.insert(context + "\n" + $0).inserted }
                let selected = evenlySpaced(fresh, limit: 6)
                if !selected.isEmpty { facts.append("界面显示：" + selected.joined(separator: "；")) }
                else if ax.mode == .fullTree, nodes.isEmpty {
                    facts.append("仅记录到应用或窗口，未读取到有效正文")
                }
            }
            if facts.isEmpty, event.kind == .windowChanged { facts.append("查看窗口") }
            if !facts.isEmpty { observations.append(reference + "\n" + facts.joined(separator: "\n")) }
        }
        // 先覆盖整个时间范围，再填预算，避免只保留长段开头。
        let selected = evenlySpaced(observations, limit: max(1, characterBudget / 650))
        let slotBudget = max(0, characterBudget / max(1, selected.count) - 2)
        guard slotBudget > 0 else { return "" }
        var out = ""
        for item in selected {
            let text = item.count <= slotBudget ? item : String(item.prefix(slotBudget - 1)) + "…"
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
