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
                   !(keyboard.target?.placeholder == text && keyboard.textEvidence != .editedValue),
                   !replaced.contains("\(segmentID)#\(event.id)") {
                    let label = keyboard.textEvidence == .editedValue ? "编辑片段" : "控件变化"
                    facts.append("\(label)：\(MemoryWriter.truncate(text, 300))")
                }
                if let key = keyboard.keyEquivalent, !key.isEmpty {
                    facts.append("按键：\((keyboard.modifiers + [key == "\r" ? "Return" : key]).joined(separator: "+"))")
                }
            }
            if let target = event.mouse?.target {
                let label = [target.title, target.description, target.role].compactMap { $0 }.first ?? "控件"
                facts.append("点击：\(MemoryWriter.truncate(label, 100))")
            }
            if let ax = event.ax {
                // 按渲染节点切分，续行仍属于该节点；不能把旧差分的 ~ 续行误作新增内容。
                let nodes = screenNodes(ax)
                let fresh = nodes.filter { seenScreen.insert(context + "\n" + $0).inserted }
                let selected = evenlySpaced(fresh, limit: 6)
                if !selected.isEmpty { facts.append("界面显示：" + selected.joined(separator: "；")) }
            }
            if facts.isEmpty, event.kind == .windowChanged { facts.append("查看窗口") }
            if !facts.isEmpty { observations.append(reference + "\n" + facts.joined(separator: "\n")) }
        }
        // 先覆盖整个时间范围，再填预算，避免只保留长段开头。
        let selected = evenlySpaced(observations, limit: max(1, characterBudget / 650))
        var out = ""
        for item in selected {
            let remaining = characterBudget - out.count
            guard remaining > 0 else { break }
            out += String(item.prefix(remaining)) + "\n\n"
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
        let header = try! NSRegularExpression(pattern: #"^[~+\-]?\t*\d+ "#)
        for part in ax.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(part)
            let range = NSRange(line.startIndex..., in: line)
            if header.firstMatch(in: line, range: range) != nil {
                if include, !buffer.isEmpty { result.append(MemoryWriter.truncate(buffer, 400)) }
                include = ax.mode == .fullTree || line.hasPrefix("+")
                buffer = include ? line : ""
            } else if include, !line.hasPrefix("Removed element IDs:") {
                // 单个节点只保留有界文本，避免超大控件值占满材料。
                if buffer.count < 600 { buffer += " " + String(line.prefix(600 - buffer.count)) }
            }
        }
        if include, !buffer.isEmpty { result.append(MemoryWriter.truncate(buffer, 400)) }
        return result
    }

    static func summary(in text: String, limit: Int = 1800) -> String {
        let sections = MemoryIndex.parseSections(MemoryIndex.stripFrontmatter(text))
        let narrative = sections.filter {
            ["本次活动", "整体走向", "延续的工作线"].contains($0.heading)
        }.map(\.content).joined(separator: "\n")
        return String((narrative.isEmpty ? MemoryWriter.parseFrontmatter(text).description : narrative).prefix(limit))
    }
}
