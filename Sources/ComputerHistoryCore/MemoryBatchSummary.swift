import Foundation

enum MemoryBatchSummary {
    static func rejectedForContext(_ error: Error) -> Bool {
        if case DeepSeekClient.ClientError.previouslyRejectedContext = error { return true }
        return MemoryContextRejections.isContextLimit(error)
    }

    static func complete(_ material: String, send: (String) throws -> DeepSeekClient.Completion) throws -> DeepSeekClient.Completion {
        var usage: DeepSeekClient.Usage?
        func attempt(_ input: String) throws -> DeepSeekClient.Completion {
            let result = try send(input)
            if let next = result.usage {
                if var total = usage {
                    total.promptTokens += next.promptTokens
                    total.completionTokens += next.completionTokens
                    total.totalTokens += next.totalTokens
                    total.reasoningTokens += next.reasoningTokens
                    if let cached = next.cachedPromptTokens { total.cachedPromptTokens = (total.cachedPromptTokens ?? 0) + cached }
                    usage = total
                } else { usage = next }
            }
            return result
        }

        func reduce(_ text: Substring, instruction: String) throws -> [String] {
            do { return [try attempt(instruction + text).text] }
            catch where rejectedForContext(error) && text.utf8.count > 1024 {
                let count = text.count
                guard count > 1 else { throw error }
                let middle = text.index(text.startIndex, offsetBy: count / 2)
                return try reduce(text[..<middle], instruction: instruction) + reduce(text[middle...], instruction: instruction)
            }
        }

        // These batches contain inline evidence so the model can interpret each request independently.
        let extraction = "从下面这一批材料提取该时段的具体活动、时间、结果和来源编号。行首或行尾可能接续另一批。按证据写简明 Markdown，保留具体事实。\n\n"
        let merge = "合并以下同一十分钟时段的分批摘要，按原始总结要求输出一份记忆，去重并保留时间、动作、对象、结果和来源。\n\n"
        let limit = min(131_072, max(1, material.count / 2))
        var pending = material[...]
        var parts: [String] = []
        while !pending.isEmpty {
            let end = pending.index(pending.startIndex, offsetBy: limit, limitedBy: pending.endIndex) ?? pending.endIndex
            let split: String.Index
            if end != pending.endIndex {
                let preferredStart = pending.index(pending.startIndex, offsetBy: limit / 2)
                split = pending[preferredStart..<end].lastIndex(of: "\n").map { pending.index(after: $0) } ?? end
            } else { split = end }
            parts += try reduce(pending[..<split], instruction: extraction)
            pending = pending[split...]
        }

        for _ in 0..<6 {
            let combined = parts.joined(separator: "\n\n")
            do {
                var result = try attempt(merge + combined)
                result.usage = usage
                return result
            } catch where rejectedForContext(error) && parts.count > 1 {
                let middle = (parts.count + 1) / 2
                let groups = [parts[..<middle], parts[middle...]]
                let smaller = try groups.flatMap { try reduce($0.joined(separator: "\n\n")[...], instruction: merge) }
                guard smaller.joined(separator: "\n\n").utf8.count < combined.utf8.count else { throw error }
                parts = smaller
            }
        }
        throw DeepSeekClient.ClientError.malformedResponse("无法在上下文上限内合并分批记忆。")
    }
}
