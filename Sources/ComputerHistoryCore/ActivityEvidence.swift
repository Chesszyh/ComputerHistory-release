import Foundation

/// 有界的时序材料同时保留应用上下文、编辑归属和界面结果，供各总结层复用。
public enum ActivityEvidence {
    private struct Observation {
        let reference: String
        let context: String
        let app: EventStreamApp
        let window: EventStreamWindow?
        let timestamp: Date
        let facts: [String]
        let nodes: [String]
        let hasContent: Bool
        let priority: Int
        let changedScreen: Bool

        func sharesPage(with other: Observation) -> Bool {
            guard app.bundleIdentifier == other.app.bundleIdentifier,
                  app.processIdentifier == other.app.processIdentifier,
                  window?.url == other.window?.url else { return false }
            if let id = window?.windowID, let otherID = other.window?.windowID { return id == otherID }
            return context == other.context
        }
    }

    public static let noActivityTitle = "无明显活动"
    public static let noActivitySummary = "本时段仅记录到前台界面变化，未记录到明确操作。"
    public static let inputDegradedTitle = "活动证据不足"
    public static let inputDegradedSummary = "未记录到明确操作，输入监听记录不足以确认本时段的操作情况。"

    public static func hasNoClearActivity(events: [EventStreamRecord]) -> Bool {
        !events.isEmpty && !hasMeaningfulInteraction(events: events)
    }

    public static func hasMeaningfulInteraction(events: [EventStreamRecord]) -> Bool {
        events.contains(where: isMeaningfulInteraction)
    }

    static func isMeaningfulInteraction(_ event: EventStreamRecord) -> Bool {
        if [.mouseClick, .mouseContextMenu, .mouseDrag, .mouseScroll, .keyboardShortcut, .keyboardSubmit].contains(event.kind) { return true }
        return event.kind == .keyboardTextInput && event.keyboard?.textEvidence == .editedValue
            && event.keyboard?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public static func interactionSummary(events: [EventStreamRecord], inputDegraded: Bool = false) -> String {
        let clicks = events.filter { [.mouseClick, .mouseContextMenu, .mouseDrag].contains($0.kind) }.count
        let scrolls = events.filter { $0.kind == .mouseScroll }.count
        let keys = events.filter { [.keyboardShortcut, .keyboardSubmit].contains($0.kind) }.count
        let edits = events.filter { $0.kind == .keyboardTextInput && $0.keyboard?.textEvidence == .editedValue }.count
        var text = "明确交互记录：鼠标 \(clicks) 次，浏览滚动证据 \(scrolls) 条，快捷键或提交 \(keys) 次，确证编辑片段 \(edits) 段。\n"
        if clicks + scrolls + keys + edits == 0 {
            if inputDegraded {
                text += "本段输入监听未处于活动状态，未能采集键鼠操作证据。只描述界面处于前台、停留或内容变化。\n"
            } else {
                text += "本段未记录到上述明确交互。只描述界面处于前台、停留或内容变化，不将页面刷新、倒计时或后台回复写成用户持续查看、阅读或操作。\n"
            }
        }
        return text + "记录首末时间是观测范围，不代表持续操作时长；不能由缺少交互推断用户离开、看手机或没有阅读。\n"
    }
    public static func material(events: [EventStreamRecord], segmentID: String,
                                characterBudget: Int? = 16000, useTextReferences: Bool = true) -> String {
        var observations: [Observation] = []
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
            var priority = 0
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
                    facts.append("\(label)：\(MemoryWriter.truncate(text, characterBudget == nil ? Int.max : 2400))")
                    hasContent = true
                    if keyboard.textEvidence == .editedValue { priority = 2 }
                }
                if characterBudget != nil {
                    if event.kind == .keyboardSubmit {
                        facts.append("按下回车")
                        hasContent = true
                        priority = 2
                    } else if event.kind == .keyboardShortcut, let key = keyboard.keyEquivalent {
                        facts.append("快捷键：" + (keyboard.modifiers + [key]).joined(separator: "+"))
                        hasContent = true
                        priority = 1
                    }
                }
            }
            if let target = event.mouse?.target {
                if let label = [target.title, target.description].compactMap({ $0 }).first,
                   !isChatChrome(label, app: app) {
                    let action = event.kind == .mouseScroll ? "浏览滚动" : "点击"
                    facts.append("\(action)：\(MemoryWriter.truncate(label, characterBudget == nil ? Int.max : 100))")
                    hasContent = true
                    if event.kind != .mouseScroll { priority = 1 }
                }
            } else if event.kind == .mouseScroll {
                facts.append("浏览滚动")
                hasContent = true
            }
            if let ax = event.ax {
                // 按渲染节点切分，续行仍属于该节点；不能把旧差分的 ~ 续行误作新增内容。
                let values = screenNodes(ax, limit: characterBudget == nil ? Int.max : 1400,
                    includeChanges: characterBudget == nil).filter { !isChatChrome($0, app: app) }
                let nodes = values.map { value in
                    ax.source == "window_ocr" && value.hasPrefix("Value: ") ? String(value.dropFirst(7)) : value
                }
                selectedNodes = nodes
                if !selectedNodes.isEmpty { hasContent = true }
                else if ax.mode == .fullTree, nodes.isEmpty {
                    facts.append("仅记录到应用或窗口，未读取到有效正文")
                }
            }
            if facts.isEmpty, selectedNodes.isEmpty, event.kind == .windowChanged, context != lastContext {
                facts.append("窗口状态变化")
            }
            lastContext = context
            if !facts.isEmpty || !selectedNodes.isEmpty {
                observations.append(Observation(reference: reference, context: context, app: app, window: event.window,
                    timestamp: event.timestamp,
                    facts: facts, nodes: selectedNodes, hasContent: hasContent, priority: priority,
                    changedScreen: event.ax?.mode == .diffFromPrevious))
            }
        }
        guard let characterBudget else {
            var seenScreen = Set<String>()
            var contexts: [String: Int] = [:]
            var encoder = EvidenceTextEncoder()
            return observations.compactMap { item in
                let fresh = item.nodes.enumerated().filter { seenScreen.insert(item.context + "\n" + $0.element).inserted }.map { _, node in
                    useTextReferences ? encoder.encode(node) : node
                }
                guard !fresh.isEmpty || !item.facts.isEmpty else { return nil }
                let reference: String
                if let number = contexts[item.context] {
                    reference = String(item.reference.dropLast(item.context.count)) + "上下文 C\(number)"
                } else {
                    let number = contexts.count + 1
                    contexts[item.context] = number
                    reference = String(item.reference.dropLast(item.context.count)) + "上下文 C\(number)：" + item.context
                }
                let facts = item.facts.map { fact in
                    useTextReferences ? encoder.encode(fact) : fact
                }
                var text = reference + "\n" + facts.joined(separator: "\n")
                if !fresh.isEmpty { text += "\n界面显示：" + fresh.joined(separator: "；") }
                return text + "\n\n"
            }.joined()
        }
        return compactMaterial(observations, budget: characterBudget)
    }

    private static func compactMaterial(_ observations: [Observation], budget: Int) -> String {
        let slots = max(1, budget / 650)
        let readingSlots = max(1, slots / 3)
        let actionSlots = slots - readingSlots
        let edits = observations.indices.filter { observations[$0].priority == 2 }
        let actions = observations.indices.filter { observations[$0].priority == 1 }
        let chosenActions = evenlySpaced(edits, limit: actionSlots)
            + representative(actions, in: observations, limit: max(0, actionSlots - edits.count))

        var results = Set<Int>()
        for index in chosenActions.sorted(by: { observations[$0].priority > observations[$1].priority }) {
            let action = observations[index]
            let following = observations.indices.dropFirst(index + 1).prefix { next in
                let observation = observations[next]
                return observation.sharesPage(with: action) && observation.priority == 0
                    && observation.timestamp.timeIntervalSince(action.timestamp) <= 12
            }
            if let result = following.first(where: { observations[$0].changedScreen && !observations[$0].nodes.isEmpty })
                ?? following.first(where: { !observations[$0].nodes.isEmpty }) {
                results.insert(result)
            }
            if results.count >= readingSlots { break }
        }
        let selected = Set(chosenActions).union(results)
        let reading = observations.indices.filter { !selected.contains($0) && observations[$0].priority == 0 }
        let available = slots - chosenActions.count
        let readingCount = max(min(readingSlots, available), available - results.count)
        let visible = reading.filter { !observations[$0].nodes.isEmpty }
        let candidates = reading.filter { observations[$0].hasContent }
        let chosenReading = representative(visible.isEmpty ? candidates : visible, in: observations, limit: readingCount)
        let fallback = chosenReading.isEmpty && selected.isEmpty ? evenlySpaced(reading, limit: slots) : chosenReading
        let ordered = selected.union(fallback).sorted()
        let weight = ordered.reduce(0) { $0 + (observations[$1].priority == 2 || results.contains($1) ? 2 : 1) }
        guard weight > 0 else { return "" }
        var output = ""
        var seenScreen = Set<String>()
        for index in ordered {
            let item = observations[index]
            let slot = budget / weight * (item.priority == 2 || results.contains(index) ? 2 : 1) - 2
            guard slot > 0 else { continue }
            let text = item.reference + "\n" + item.facts.joined(separator: "\n")
            let space = max(0, slot - text.count - 7)
            let fresh = item.nodes.filter { !seenScreen.contains(item.context + "\n" + $0) }
            let full = fresh.joined(separator: "；")
            let nodes = full.count <= space ? fresh
                : Array(fresh.sorted { readableLength($0) > readableLength($1) }.prefix(max(1, space / 230)))
            let perNode = max(1, space / max(1, nodes.count) - 1)
            let body = full.count <= space ? full : nodes.map { MemoryWriter.truncate($0, perNode) }.joined(separator: "；")
            if item.facts.isEmpty && (body.isEmpty || space == 0) { continue }
            let rendered = text + (body.isEmpty || space == 0 ? "" : "\n界面显示：" + body)
            output += (rendered.count <= slot ? rendered : String(rendered.prefix(slot - 1)) + "…") + "\n\n"
            if space > 0 {
                for node in nodes { seenScreen.insert(item.context + "\n" + node) }
            }
        }
        return output
    }

    private static func representative(_ candidates: [Int], in observations: [Observation], limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        var byContext: [String: Int] = [:]
        for index in candidates {
            let item = observations[index]
            if let old = byContext[item.context], observations[old].changedScreen || !item.changedScreen { continue }
            byContext[item.context] = index
        }
        let distinct = byContext.values.sorted()
        let selected = Array(evenlySpaced(distinct, limit: limit))
        let remaining = Set(selected)
        return selected + evenlySpaced(candidates.filter { !remaining.contains($0) }, limit: limit - selected.count)
    }

    private static func readableLength(_ node: String) -> Int {
        let content = node.hasPrefix("Value: ") || !node.contains(": ")
        return min(node.count, 360) + (content ? 80 : 0)
    }

    static func evenlySpaced<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard values.count > limit else { return values }
        if limit == 1 { return [values[values.count - 1]] }
        return (0..<limit).map { values[$0 * (values.count - 1) / (limit - 1)] }
    }

    static func screenNodes(_ ax: EventStreamAXTree, limit: Int = 1400, includeChanges: Bool = false) -> [String] {
        var result: [String] = [], buffer = ""
        var include = false
        func appendNode() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(MemoryWriter.truncate(text, limit)) }
        }
        for raw in ax.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = AXTextParser.parseLine(String(raw), mode: ax.mode)
            switch line {
            case .element(_, _, nil, _, _):
                if include, buffer.count < limit { buffer += " " + String(raw.prefix(limit - buffer.count)) }
            case .element(let marker, _, _, _, let detail):
                appendNode()
                include = ax.mode == .fullTree || marker == "+" || (includeChanges && marker == "~")
                // 元素编号和 role 是树结构，不能解释为窗口数量或活动内容。
                buffer = include ? readableDetail(detail ?? "") : ""
            case .continuation(let text) where include:
                if buffer.count < limit { buffer += " " + String(text.prefix(limit - buffer.count)) }
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

/// 每条观察保留独立来源；相同正文片段只定义一次，后续仅引用其内容。
struct EvidenceTextEncoder {
    private var references: [String: String] = [:]
    private var sequence = 0
    mutating func encode(_ text: String) -> String {
        guard text.count >= 512 else { return text }
        var chunks: [String] = [], buffer = "", count = 0
        for character in text {
            buffer.append(character); count += 1
            if count >= 768 || (count >= 384 && "。；！？\n ".contains(character)) {
                chunks.append(buffer); buffer = ""; count = 0
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        var definitions: [String] = [], parts: [String] = []
        for chunk in chunks {
            if let reference = references[chunk] { parts.append(reference) }
            else {
                sequence += 1
                let reference = "T\(sequence)"
                references[chunk] = reference; parts.append(reference)
                definitions.append("文本片段 \(reference)：" + chunk)
            }
        }
        return (definitions + ["本次文本按顺序拼接片段：" + parts.joined(separator: " + ")]).joined(separator: "\n")
    }
}
