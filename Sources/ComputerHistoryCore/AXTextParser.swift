import Foundation

/// `ax.text` 的行文法解析。
///
/// 两种模式的文法**完全不同**，必须先看 `mode` 再解析：
///
/// - `diffFromPrevious`：`[\+\-~] <TAB×N> <elementID> <role> [detail]`
///   另有 `Removed element IDs: …` 摘要头，以及**无标记的续行**（元素文本自带换行）。
/// - `fullTree`：`<TAB×N> <elementID> <role> [detail]`，**无任何前缀标记**。
///
/// 易踩的坑：`fullTree` 中存在以 `~`/`+`/`-` 开头的行，但那是**终端元素的屏幕内容**
/// （提示符被当作文本），不是差分标记。因此 fullTree 绝不能按首字符判行类型。
///
/// 全部结论来自 88 段真实样本实测（diffFromPrevious 200 531 行 / fullTree 187 217 行）。
public enum AXTextLine: Equatable, Sendable {
    /// `Removed element IDs: 22, 27-113`
    case removedElementIDs(ranges: [ClosedRange<Int>], singles: [Int])
    /// 一个元素行。`marker` 为 nil 表示 fullTree 模式。
    case element(marker: Character?, depth: Int, elementID: Int?, role: String, detail: String?)
    /// 无标记、无元素 ID 的行——上一元素文本的换行续行。
    case continuation(String)
    case blank
}

public enum AXTextParser {

    /// 按模式解析为行序列。`mode` 决定是否接受前缀标记。
    public static func parse(_ text: String, mode: EventStreamAXTree.Mode) -> [AXTextLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            parseLine(String(rawLine), mode: mode)
        }
    }

    static func parseLine(_ line: String, mode: EventStreamAXTree.Mode) -> AXTextLine {
        if line.isEmpty { return .blank }

        // 摘要头在两种模式下都可能出现（实测 diffFromPrevious 有 2 371 行）。
        if line.hasPrefix(removedHeader) {
            let body = line.dropFirst(removedHeader.count)
            return .removedElementIDs(
                ranges: parseRanges(String(body)).ranges,
                singles: parseRanges(String(body)).singles)
        }

        // diffFromPrevious 的标记只在首位，且后面必须紧跟 TAB 或元素 ID。
        // fullTree 不做此判定——它的 '-' 行是终端内容。
        var marker: Character? = nil
        var rest = Substring(line)
        if mode == .diffFromPrevious, let first = rest.first, "+-~".contains(first) {
            // 仅当紧随其后是 TAB 或数字时才认定为标记，避免误吞终端文本。
            let after = rest.index(after: rest.startIndex)
            if after < rest.endIndex, rest[after] == "\t" || rest[after].isNumber {
                marker = first
                rest = rest[after...]
            }
        }

        // 缩进：TAB 个数即深度。
        var depth = 0
        while rest.first == "\t" { depth += 1; rest = rest.dropFirst() }

        // 元素 ID：行首的连续数字，后跟空格。
        var elementID: Int? = nil
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = rest.index(rest.startIndex, offsetBy: digits.count)
            if afterDigits < rest.endIndex, rest[afterDigits] == " " {
                elementID = Int(digits)
                rest = rest[rest.index(after: afterDigits)...]
            }
        }

        // 缩进之后既无元素 ID 也无内容 → 视为续行/空壳。
        if elementID == nil {
            // fullTree 的元素行必有 EID；diff 的续行没有。
            if depth == 0 && marker == nil {
                return .continuation(line)
            }
            if rest.isEmpty {
                return .continuation(line)
            }
        }

        let body = String(rest)
        guard let space = body.firstIndex(of: " ") else {
            // `<EID> <role>` 无 detail
            return .element(marker: marker, depth: depth,
                            elementID: elementID, role: body, detail: nil)
        }
        let role = String(body[body.startIndex..<space])
        let detail = String(body[body.index(after: space)...])
        return .element(marker: marker, depth: depth, elementID: elementID,
                        role: role, detail: detail.isEmpty ? nil : detail)
    }

    static let removedHeader = "Removed element IDs:"

    /// 解析 `22, 27-113` 形态的区间列表。实测形态有 `N`、`N-N` 及逗号组合。
    static func parseRanges(_ body: String) -> (ranges: [ClosedRange<Int>], singles: [Int]) {
        var ranges: [ClosedRange<Int>] = []
        var singles: [Int] = []
        for part in body.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let dash = t.firstIndex(of: "-") {
                let lo = Int(t[t.startIndex..<dash].trimmingCharacters(in: .whitespaces))
                let hi = Int(t[t.index(after: dash)...].trimmingCharacters(in: .whitespaces))
                if let lo, let hi, lo <= hi { ranges.append(lo...hi) }
            } else if let v = Int(t) {
                singles.append(v)
            }
        }
        return (ranges, singles)
    }
}
