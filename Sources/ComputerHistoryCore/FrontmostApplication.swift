import Foundation
import AppKit
import ApplicationServices

/// 前台应用与窗口信息。
///
/// 采集器只关心"哪个应用、哪个窗口"，因此这里把 `NSWorkspace` 与 `CGWindowList`
/// 的细节收敛成 `EventStreamApp` / `EventStreamWindow`。
public enum FrontmostApplication {

    /// 当前前台应用。无法确定时返回 nil（调用方据此跳过该事件）。
    public static func current() -> EventStreamApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return EventStreamApp(
            name: app.localizedName,
            secureInput: secureInputState(),
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    /// 前台窗口。
    ///
    /// 窗口标题来自 AX（`kAXTitleAttribute`），URL 仅对浏览器类应用有意义——
    /// 官方也是取浏览器窗口的地址栏值，故此处同样优先读 AX 的 `kAXURLAttribute`，
    /// 读不到时退回 `kAXDocumentAttribute`。
    public static func frontWindow(for app: EventStreamApp?) -> EventStreamWindow? {
        guard let app else { return nil }
        // processIdentifier 为 nil 时无从查询。
        return window(pid: app.processIdentifier)
    }

    public static func window(pid: Int32?) -> EventStreamWindow? {
        guard let pid else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        guard let win = AXTreeReader.copyElement(axApp, kAXFocusedWindowAttribute as String) else {
            return nil
        }
        let title = AXTreeReader.copyString(win, kAXTitleAttribute as String)
        var url = AXTreeReader.copyString(win, kAXURLAttribute as String)
        if url == nil {
            url = AXTreeReader.copyString(win, kAXDocumentAttribute as String)
        }
        return EventStreamWindow(title: title ?? "", url: url,
                                 windowID: windowID(of: win))
    }

    /// 聚焦的 UI 元素，用于键盘/鼠标事件的 `target`。
    public static func focusedElement() -> EventStreamAXElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let el = AXTreeReader.focusedElement(ofApplication: app.processIdentifier)
        else { return nil }
        return element(el)
    }

    /// 聚焦元素当前的可编辑文本。
    ///
    /// 只读值**不**读选中文本：`kAXValueAttribute` 反映控件内容，
    /// 而输入法提交的结果会写进它，这正是 `keyboard.text` 要记的东西。
    /// 元素不可编辑或读不到时返回 nil，由跟踪器据此切块。
    public static func focusedElementValue() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let el = AXTreeReader.focusedElement(ofApplication: app.processIdentifier)
        else { return nil }
        return AXTreeReader.valueString(el)
    }

    /// 聚焦元素的文本与光标位置。
    ///
    /// 光标位置取 `kAXSelectedTextRangeAttribute` 的 `location`，与 AX 的
    /// UTF-16 `CFRange` 一致。只用增量切分——控件全值不能直接当输入。
    public static func focusedElementObservation() -> TextInputTracker.Observation {
        focusedElementObservation(for: current())
    }

    public static func focusedElementObservation(for app: EventStreamApp?) -> TextInputTracker.Observation {
        focusedTextSnapshot(for: app).0
    }

    static func focusedTextSnapshot(for app: EventStreamApp?)
        -> (TextInputTracker.Observation, EventStreamAXElement?) {
        guard let pid = app?.processIdentifier,
              let el = AXTreeReader.focusedElement(ofApplication: pid) else {
            return (.init(value: nil, caret: nil), nil)
        }
        let role = AXTreeReader.copyString(el, kAXRoleAttribute as String)
        let subrole = AXTreeReader.copyString(el, kAXSubroleAttribute as String)
        let placeholder = AXTreeReader.copyString(el, kAXPlaceholderValueAttribute as String)
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        var selection: CFRange?
        if let raw = AXTreeReader.copyValue(el, kAXSelectedTextRangeAttribute as String),
           CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &range) { selection = range }
        }
        let textRole = role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
            || role == kAXComboBoxRole as String
        // 某些网页编辑器不暴露可设置性；已知非文本角色不作为编辑缓冲。
        let knownNonText = ["AXButton", "AXStaticText", "AXLink", "AXMenuItem", "AXImage"].contains(role ?? "")
        let editable = !knownNonText && (textRole || settableResult == .success && settable.boolValue
            || selection != nil)
        let value = editable ? AXTreeReader.valueString(el) : nil
        let observation = TextInputTracker.Observation(
            value: value, caret: selection?.location,
            isEditableBuffer: value.map(AXTreeReader.isEditableBuffer) ?? false,
            focusIdentity: Int(truncatingIfNeeded: CFHash(el)),
            role: role, subrole: subrole,
            valueSettable: settableResult == .success ? settable.boolValue : nil,
            placeholder: placeholder, selectionLength: selection?.length)
        let target: EventStreamAXElement? = observation.isEditableBuffer ? .init(
            role: role, subrole: subrole,
            title: AXTreeReader.copyString(el, kAXTitleAttribute as String),
            description: AXTreeReader.copyString(el, kAXDescriptionAttribute as String),
            value: value, placeholder: placeholder,
            identifier: AXTreeReader.copyString(el, kAXIdentifierAttribute as String)) : nil
        return (observation, target)
    }

    /// 把 AXUIElement 转成落盘的 `target`/`element` 结构。
    public static func element(_ el: AXUIElement) -> EventStreamAXElement {
        EventStreamAXElement(
            role: AXTreeReader.copyString(el, kAXRoleAttribute as String),
            subrole: AXTreeReader.copyString(el, kAXSubroleAttribute as String),
            title: AXTreeReader.copyString(el, kAXTitleAttribute as String),
            description: AXTreeReader.copyString(el, kAXDescriptionAttribute as String),
            value: AXTreeReader.valueString(el),
            placeholder: AXTreeReader.copyString(el, kAXPlaceholderValueAttribute as String),
            identifier: AXTreeReader.copyString(el, kAXIdentifierAttribute as String)
        )
    }

    /// 从窗口的 `kAXWindowNumberAttribute` 取窗口号；缺失时返回 nil。
    static func windowID(of win: AXUIElement) -> UInt32? {
        guard let v = AXTreeReader.copyValue(win, "AXWindowNumber") as? NSNumber else {
            return nil
        }
        return v.uint32Value
    }

    /// 未实现安全输入模式检测；nil 表示未知，编码时省略该键。
    public static func secureInputState() -> Bool? { nil }
}
