import Foundation
import ApplicationServices

/// 从运行中的进程读取 Accessibility 树，并转成可渲染/可差分的 `UIElementRender`。
///
/// 这层是采集器唯一直接接触 `AXUIElement` 的地方；上层的渲染与差分只依赖
/// `UIElementRender`，因此可以脱离真实窗口做单元测试。
///
/// 需要 Accessibility 权限（系统设置 → 隐私与安全性 → 辅助功能）。
/// 官方同样不需要录屏权限。
public enum AXTreeReader {

    /// 读取某个进程的 AX 树。
    ///
    /// - Parameters:
    ///   - pid: 目标进程。
    ///   - maxNodes: 节点上限。AX 树可能极深（实测缩进达 28 层、
    ///     `fullTree` 单次最多 1 010 行），必须设限以免单帧耗时过长。
    ///   - maxDepth: 深度上限。
    public static func read(
        pid: pid_t,
        maxNodes: Int = 4000,
        maxDepth: Int = 40,
        isAllowed: @escaping () -> Bool = { !FrontmostApplication.secureInputState() }
    ) -> [UIElementRender] {
        snapshot(pid: pid, maxNodes: maxNodes, maxDepth: maxDepth, isAllowed: isAllowed) ?? []
    }

    static func snapshot(pid: pid_t, maxNodes: Int, maxDepth: Int = 40,
                         isAllowed: @escaping () -> Bool) -> [UIElementRender]? {
        let access = AccessibilityRead(isAllowed: isAllowed)
        guard access.canRead else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement]
        if let focused = copyElement(app, kAXFocusedWindowAttribute, access: access) {
            windows = [focused]
        } else {
            guard access.canRead else { return nil }
            windows = copyElements(app, kAXWindowsAttribute, access: access) ?? []
        }
        return snapshot(windows: windows, maxNodes: maxNodes, maxDepth: maxDepth, access: access)
    }

    static func snapshot(window: AXWindowReference, maxNodes: Int,
                         isAllowed: @escaping () -> Bool) -> [UIElementRender]? {
        snapshot(windows: [window.element], maxNodes: maxNodes, maxDepth: 40, access: .init(isAllowed: isAllowed))
    }

    private static func snapshot(windows: [AXUIElement], maxNodes: Int, maxDepth: Int,
                                 access: AccessibilityRead) -> [UIElementRender]? {
        var budget = maxNodes
        let roots = windows.compactMap {
            convert($0, budget: &budget, depth: 0, maxDepth: maxDepth, access: access)
        }
        return access.canRead ? roots : nil
    }

    static func hasReadableContent(_ roots: [UIElementRender]) -> Bool {
        func readable(_ node: UIElementRender) -> Bool {
            let role = node.accessibilityRole ?? node.text
            // Toolbar titles and address-field values are browser controls, not document text.
            if ["AXToolbar", "AXTabGroup", "AXMenuBar", "AXMenu", "工具栏", "标签组", "菜单栏", "菜单"].contains(role) { return false }
            let textRole = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "文本", "文本区域", "StaticText", "TextArea"].contains(role)
            let detail = node.detailText ?? ""
            if textRole && (detail.contains("Value:") || detail.contains("Title:")) { return true }
            return node.children.contains(where: readable)
        }
        return roots.contains(where: readable)
    }

    // MARK: - 单个元素转换

    static func convert(
        _ element: AXUIElement,
        budget: inout Int,
        depth: Int,
        maxDepth: Int,
        access: AccessibilityRead = .init()
    ) -> UIElementRender? {
        var seenHashes: [UInt: Int] = [:]
        return convert(element, budget: &budget,
                       depth: depth, maxDepth: maxDepth, seenHashes: &seenHashes, access: access)
    }

    /// 身份 = `CFHash` + 该哈希在本次快照中第几次出现。
    ///
    /// 依据（实测 1417 节点、跨三帧）：
    ///   - `CFHash` 跨帧 **1417/1417 一致**；
    ///   - 但 32 位哈希同帧内有 171 处碰撞，故需按遍历顺序加出现序号去重；
    ///   - 对象指针跨帧一致率 **0/1417**（每次重读都是新对象），不可用；
    ///   - `CFEqual` 跨帧 1417/1417 相等，可作等价判定但无法直接当哈希键。
    ///
    /// 该身份与遍历序号无关，因此在树中间插入或删除节点**不会**让其后的节点
    /// 身份改变——这正是启发式路径（按「同 role 第几个」）做不到的。
    static func convert(
        _ element: AXUIElement,
        budget: inout Int,
        depth: Int,
        maxDepth: Int,
        seenHashes: inout [UInt: Int],
        ancestors: [AXUIElement] = [],
        access: AccessibilityRead
    ) -> UIElementRender? {
        guard budget > 0, depth <= maxDepth, access.canRead,
              !ancestors.contains(where: { CFEqual($0, element) }) else { return nil }
        budget -= 1

        let role = copyString(element, kAXRoleAttribute as String, access: access) ?? ""
        let description = describeRole(element, role: role, access: access)
        let detail = buildDetail(element, access: access)

        let h = CFHash(element)
        let occurrence = seenHashes[h, default: 0]
        seenHashes[h] = occurrence + 1
        let id = identityHash(hash: h, occurrence: occurrence)

        var children: [UIElementRender] = []
        // WeChat scrolls when AXChildren is queried on static text, even though it returns no children.
        if role != kAXStaticTextRole as String, access.canRead,
           let kids = copyElements(element, kAXChildrenAttribute as String, access: access) {
            for kid in kids {
                guard access.canRead else { return nil }
                if let c = convert(kid, budget: &budget,
                                   depth: depth + 1, maxDepth: maxDepth,
                                   seenHashes: &seenHashes, ancestors: ancestors + [element],
                                   access: access) {
                    children.append(c)
                }
            }
        }
        guard access.canRead else { return nil }
        return UIElementRender(id: id, identityPath: "cfhash:\(h)#\(occurrence)",
                               text: description, detailText: detail, children: children, accessibilityRole: role)
    }

    /// 由 CFHash 与出现序号派生稳定的非负身份值。
    static func identityHash(hash: UInt, occurrence: Int) -> Int {
        var v = UInt64(truncatingIfNeeded: hash)
        v = v &* 0x9E37_79B9_7F4A_7C15          // 混合，避免低位规律性
        v ^= UInt64(truncatingIfNeeded: occurrence) &* 0xBF58_476D_1CE4_E5B9
        return Int(truncatingIfNeeded: v & 0x7fff_ffff_ffff_ffff)
    }

    /// 行主体：role 的本地化描述。
    ///
    /// 实测样本里出现的是人类可读词（`按钮`、`文本`、`滚动区`、`container`），
    /// 而非 `AXButton` 这类原始 role，故此处优先取 `kAXRoleDescriptionAttribute`。
    static func describeRole(_ element: AXUIElement, role: String,
                             access: AccessibilityRead = .init()) -> String {
        if let d = copyString(element, kAXRoleDescriptionAttribute as String, access: access), !d.isEmpty {
            return d
        }
        // 退回原始 role，去掉 AX 前缀以贴近样本形态。
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    /// 属性串保留标题、描述、帮助、值与定位信息。
    static func buildDetail(_ element: AXUIElement, attributes: Attributes? = nil,
                            access: AccessibilityRead = .init()) -> String? {
        let attributes = attributes ?? Attributes(element, access: access)
        guard !attributes.isSecure else { return nil }
        var parts: [String] = []
        if let v = attributes.readString(kAXTitleAttribute), !v.isEmpty {
            parts.append("Title: \(v)")
        }
        if let v = attributes.readString(kAXDescriptionAttribute), !v.isEmpty {
            parts.append("Description: \(v)")
        }
        // Help 在 AX 中是 kAXHelpAttribute；样本里出现过 `Help: ...`。
        if let v = attributes.readString(kAXHelpAttribute), !v.isEmpty {
            parts.append("Help: \(v)")
        }
        if let v = attributes.value, !v.isEmpty {
            parts.append("Value: \(v)")
        }
        if let v = attributes.readString(kAXIdentifierAttribute), !v.isEmpty {
            parts.append("ID: \(v)")
        }
        if let v = attributes.readString(kAXURLAttribute), !v.isEmpty {
            parts.append("URL: \(v)")
        }
        if let v = attributes.readString(kAXPlaceholderValueAttribute), !v.isEmpty {
            parts.append("Placeholder: \(v)")
        }
        // 可设置性与子角色以括号前缀形式出现（实测 `(disabled)`、`(settable, float)`）
        var flags: [String] = []
        if let enabled = copyBool(element, kAXEnabledAttribute as String, access: access), !enabled {
            flags.append("disabled")
        }
        if isValueSettable(element, access: access) {
            flags.append("settable")
        }
        var head = flags.isEmpty ? "" : "(\(flags.joined(separator: ", "))) "
        if parts.isEmpty && head.isEmpty { return nil }
        head += parts.joined(separator: ", ")
        return head.isEmpty ? nil : head.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - AX 取值助手

    static func copyValue(_ element: AXUIElement, _ attribute: String,
                          access: AccessibilityRead = .init()) -> CFTypeRef? {
        var out: CFTypeRef?
        let err = access.perform {
            AXUIElementCopyAttributeValue(element, attribute as CFString, &out)
        }
        return err == .success ? out : nil
    }

    static func copyString(_ element: AXUIElement, _ attribute: String,
                           access: AccessibilityRead = .init()) -> String? {
        guard let v = copyValue(element, attribute, access: access) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// `kAXValueAttribute` 是否可写。实测样本以 `(settable)` 标注。
    static func isValueSettable(_ element: AXUIElement, access: AccessibilityRead = .init()) -> Bool {
        var settable: DarwinBoolean = false
        let err = access.perform {
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        }
        return err == .success && settable.boolValue
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String,
                           access: AccessibilityRead = .init()) -> Bool? {
        guard let v = copyValue(element, attribute, access: access) else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    static func copyElement(_ element: AXUIElement, _ attribute: String,
                           access: AccessibilityRead = .init()) -> AXUIElement? {
        guard let v = copyValue(element, attribute, access: access) else { return nil }
        guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func copyElements(_ element: AXUIElement, _ attribute: String,
                           access: AccessibilityRead = .init()) -> [AXUIElement]? {
        guard let v = copyValue(element, attribute, access: access) else { return nil }
        guard let arr = v as? [Any] else { return nil }
        return arr.compactMap {
            guard CFGetTypeID($0 as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            return ($0 as! AXUIElement)
        }
    }

    /// 找到承载输入焦点的元素。
    ///
    /// 优先用 `kAXFocusedUIElementAttribute`。部分应用（实测 Electron 系）
    /// 在应用层不暴露该属性，此时回退到聚焦窗口的 `kAXFocusedUIElementAttribute`——
    /// Chromium 系通常在窗口这一层提供。
    public static func focusedElement(ofApplication pid: pid_t) -> AXUIElement? {
        focusedElement(ofApplication: pid, access: .init())
    }

    static func focusedElement(ofApplication pid: pid_t, access: AccessibilityRead) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let el = copyElement(app, kAXFocusedUIElementAttribute, access: access) { return el }
        if let win = copyElement(app, kAXFocusedWindowAttribute, access: access),
           let el = copyElement(win, kAXFocusedUIElementAttribute, access: access) {
            return el
        }
        return nil
    }

    static func focusedElement(ofApplication pid: pid_t, within window: ObservedWindow,
                               access: AccessibilityRead) -> AXUIElement? {
        guard let reference = window.reference else { return nil }
        let app = AXUIElementCreateApplication(pid)
        if let element = copyElement(app, kAXFocusedUIElementAttribute, access: access),
           let owner = copyElement(element, kAXWindowAttribute, access: access), window.owns(owner, access: access) {
            return element
        }
        guard let element = copyElement(reference.element, kAXFocusedUIElementAttribute, access: access) else { return nil }
        if let owner = copyElement(element, kAXWindowAttribute, access: access), !window.owns(owner, access: access) {
            return nil
        }
        return access.canRead ? element : nil
    }

    /// 聚焦元素的值是否**可以**作为编辑缓冲看待。
    ///
    /// `AXSelectedText` **不能**用作输入来源：实测其语义严格等于当前选区——
    /// 无选中时为空串，全选时为整个内容，选中一个词时为该词。把它当"刚键入字符"
    /// 会在用户选中文字准备替换时把选中内容误记为输入。聚焦一个已有内容的输入框
    /// 时系统常自动全选，该误记随即发生。
    ///
    /// 这里只判断值**是否像编辑缓冲**：终端把屏幕表示为定宽网格，命令区用 NUL
    /// 补齐（实测 iTerm `"~ ❯ whoami\0\0\0…"`）。含 NUL 的值是渲染缓冲而非
    /// 用户正在编辑的文本，对其做差分会把命令输出记为输入。
    static func isEditableBuffer(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value == 0 }
    }

    /// 聚焦元素的插入点位置。
    ///
    /// `kAXSelectedTextRangeAttribute` 是 `CFRange`；取其 `location` 即光标偏移
    /// （UTF-16，与 Swift 的 `String.utf16` 一致）。无选区信息时返回 nil，
    /// 调用方据此放弃猜测而不是记录可疑内容。
    static func caretLocation(of element: AXUIElement) -> Int? {
        guard let v = copyValue(element, kAXSelectedTextRangeAttribute as String) else { return nil }
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((v as! AXValue), .cfRange, &range) else { return nil }
        return range.location
    }

    struct Attributes {
        let readString: (String) -> String?
        let subrole: String?

        init(readString: @escaping (String) -> String?) {
            self.readString = readString
            subrole = readString(kAXSubroleAttribute)
        }

        init(_ element: AXUIElement, access: AccessibilityRead = .init()) {
            self.init { copyString(element, $0, access: access) }
        }

        var isSecure: Bool { subrole == kAXSecureTextFieldSubrole }
        var value: String? { isSecure ? nil : readString(kAXValueAttribute) }
    }
}
