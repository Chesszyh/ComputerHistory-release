import Foundation
import AppKit
import ApplicationServices
import Carbon

// Retain the immutable AX proxy so the worker can read the captured window itself.
struct AXWindowReference: @unchecked Sendable {
    let element: AXUIElement

    func matches(_ element: AXUIElement) -> Bool { CFEqual(self.element, element) }
}

struct ObservedWindow: Sendable {
    var details: EventStreamWindow
    var reference: AXWindowReference? = nil

    var hasIdentity: Bool { details.windowID != nil || reference != nil }

    func matches(_ other: Self?) -> Bool {
        guard let other, details.url == other.details.url else { return false }
        if let number = details.windowID, let otherNumber = other.details.windowID {
            return number == otherNumber
        }
        guard let reference, let otherReference = other.reference else { return false }
        return reference.matches(otherReference.element)
    }

    func owns(_ element: AXUIElement, access: AccessibilityRead) -> Bool {
        if reference?.matches(element) == true { return true }
        guard let number = details.windowID else { return false }
        return FrontmostApplication.windowID(of: element, access: access) == number
    }
}

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
        observedWindow(pid: pid, access: .init())?.details
    }

    static func observedWindow(pid: Int32?, access: AccessibilityRead) -> ObservedWindow? {
        guard let pid, access.canRead else { return nil }
        guard let win = focusedWindow(pid: pid, access: access) else { return nil }
        let title = AXTreeReader.copyString(win, kAXTitleAttribute, access: access)
        let url = windowURL(of: win, access: access)
        let id = windowID(of: win, access: access)
        guard access.canRead else { return nil }
        return ObservedWindow(details: .init(title: title ?? "", url: url, windowID: id),
                              reference: .init(element: win))
    }

    static func focusedWindowMatches(_ app: EventStreamApp, window: ObservedWindow, access: AccessibilityRead) -> Bool {
        guard let pid = app.processIdentifier else { return false }
        return focusedWindowMatches(window, access: access,
            readWindow: { focusedWindow(pid: pid, access: access) },
            readURL: { windowURL(of: $0, access: access) })
    }

    static func focusedWindowMatches(_ window: ObservedWindow, access: AccessibilityRead,
                                     readWindow: () -> AXUIElement?, readURL: (AXUIElement) -> String?) -> Bool {
        guard access.canRead, let focused = readWindow(), window.owns(focused, access: access),
              access.canRead else { return false }
        return readURL(focused) == window.details.url && access.canRead
    }

    private static func focusedWindow(pid: Int32, access: AccessibilityRead) -> AXUIElement? {
        AXTreeReader.copyElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute, access: access)
    }

    private static func windowURL(of window: AXUIElement, access: AccessibilityRead) -> String? {
        AXTreeReader.copyString(window, kAXURLAttribute, access: access)
            ?? AXTreeReader.copyString(window, kAXDocumentAttribute, access: access)
    }

    /// 聚焦的 UI 元素，用于键盘事件的 `target`。
    public static func focusedElement() -> EventStreamAXElement? {
        let access = AccessibilityRead()
        guard let pid = current()?.processIdentifier,
              let element = AXTreeReader.focusedElement(ofApplication: pid, access: access) else { return nil }
        let target = self.element(attributes: .init(element, access: access))
        return access.canRead ? target : nil
    }

    static func focusedElement(for app: EventStreamApp?, window: ObservedWindow?,
                               access: AccessibilityRead) -> EventStreamAXElement? {
        guard let pid = app?.processIdentifier, let window,
              let el = AXTreeReader.focusedElement(ofApplication: pid, within: window, access: access) else { return nil }
        let target = element(attributes: .init(el, access: access))
        return access.canRead ? target : nil
    }

    static func clickedElement(at point: CGPoint, for app: EventStreamApp?, window: ObservedWindow?,
                               access: AccessibilityRead) -> EventStreamAXElement? {
        guard let pid = app?.processIdentifier, let window, window.hasIdentity else { return nil }
        var hit: AXUIElement?
        let result = access.perform {
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        }
        guard result == .success, let hit else { return nil }
        var hitPID: pid_t = 0
        guard access.perform({ AXUIElementGetPid(hit, &hitPID) }) == .success, hitPID == pid,
              let hitWindow = AXTreeReader.copyElement(hit, kAXWindowAttribute, access: access),
              window.owns(hitWindow, access: access) else { return nil }
        // The policy was checked against this window's address before reading the target value.
        guard windowURL(of: hitWindow, access: access) == window.details.url, access.canRead else { return nil }
        let target = element(attributes: .init(hit, access: access))
        return access.canRead ? target : nil
    }

    /// 聚焦元素当前的可编辑文本。
    ///
    /// 只读值**不**读选中文本：`kAXValueAttribute` 反映控件内容，
    /// 而输入法提交的结果会写进它，这正是 `keyboard.text` 要记的东西。
    /// 元素不可编辑或读不到时返回 nil，由跟踪器据此切块。
    public static func focusedElementValue() -> String? {
        let access = AccessibilityRead()
        guard let pid = current()?.processIdentifier,
              let el = AXTreeReader.focusedElement(ofApplication: pid, access: access) else { return nil }
        let value = AXTreeReader.Attributes(el, access: access).value
        return access.canRead ? value : nil
    }

    /// 聚焦元素的文本与光标位置。
    ///
    /// 光标位置取 `kAXSelectedTextRangeAttribute` 的 `location`，与 AX 的
    /// UTF-16 `CFRange` 一致。只用增量切分——控件全值不能直接当输入。
    public static func focusedElementObservation() -> TextInputTracker.Observation {
        focusedElementObservation(for: current())
    }

    public static func focusedElementObservation(for app: EventStreamApp?) -> TextInputTracker.Observation {
        let access = AccessibilityRead()
        guard let pid = app?.processIdentifier,
              let element = AXTreeReader.focusedElement(ofApplication: pid, access: access) else {
            return .init(value: nil, caret: nil)
        }
        return focusedTextSnapshot(of: element, attributes: .init(element, access: access), access: access).0
    }

    static func focusedTextSnapshot(for app: EventStreamApp?, window: ObservedWindow?, access: AccessibilityRead)
        -> (TextInputTracker.Observation, EventStreamAXElement?) {
        guard let pid = app?.processIdentifier, let window,
              let el = AXTreeReader.focusedElement(ofApplication: pid, within: window, access: access) else {
            return (.init(value: nil, caret: nil), nil)
        }
        return focusedTextSnapshot(of: el, attributes: .init(el, access: access), access: access)
    }

    static func focusedTextSnapshot(of el: AXUIElement, attributes: AXTreeReader.Attributes,
                                    access: AccessibilityRead = .init())
        -> (TextInputTracker.Observation, EventStreamAXElement?) {
        guard !attributes.isSecure, access.canRead else {
            return (.init(value: nil, caret: nil, subrole: attributes.subrole), nil)
        }
        let role = attributes.readString(kAXRoleAttribute)
        let subrole = attributes.subrole
        let placeholder = attributes.readString(kAXPlaceholderValueAttribute)
        guard access.canRead else { return (.init(value: nil, caret: nil), nil) }
        var settable = DarwinBoolean(false)
        let settableResult = access.perform { AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) }
        var selection: CFRange?
        if let raw = AXTreeReader.copyValue(el, kAXSelectedTextRangeAttribute, access: access),
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
        let value = editable ? attributes.value : nil
        guard access.canRead else { return (.init(value: nil, caret: nil), nil) }
        var marked: Bool?
        var markedValue: CFTypeRef?
        let markedResult = access.perform {
            AXUIElementCopyAttributeValue(el, "AXTextInputMarkedTextMarkerRange" as CFString, &markedValue)
        }
        if markedResult == .success { marked = markedValue != nil }
        else if markedResult == .noValue { marked = false }
        if marked == nil, let raw = AXTreeReader.copyValue(el, "AXMarkedTextRange", access: access), CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &range) {
                marked = range.location != kCFNotFound && range.length > 0
            }
        }
        let observation = TextInputTracker.Observation(
            value: value, caret: selection?.location,
            isEditableBuffer: value.map(AXTreeReader.isEditableBuffer) ?? false,
            focusIdentity: Int(truncatingIfNeeded: CFHash(el)),
            role: role, subrole: subrole,
            valueSettable: settableResult == .success ? settable.boolValue : nil,
            placeholder: placeholder, selectionLength: selection?.length, hasMarkedText: marked)
        let target: EventStreamAXElement? = observation.isEditableBuffer ? .init(
            role: role, subrole: subrole,
            title: attributes.readString(kAXTitleAttribute),
            description: attributes.readString(kAXDescriptionAttribute),
            value: value, placeholder: placeholder,
            identifier: attributes.readString(kAXIdentifierAttribute)) : nil
        return access.canRead ? (observation, target) : (.init(value: nil, caret: nil), nil)
    }

    /// 把 AXUIElement 转成落盘的 `target`/`element` 结构。
    public static func element(_ el: AXUIElement) -> EventStreamAXElement {
        let access = AccessibilityRead()
        let target = element(attributes: .init(el, access: access))
        return access.canRead ? target : EventStreamAXElement()
    }

    static func element(attributes: AXTreeReader.Attributes) -> EventStreamAXElement {
        let role = attributes.readString(kAXRoleAttribute)
        guard !attributes.isSecure else { return EventStreamAXElement(role: role, subrole: attributes.subrole) }
        return EventStreamAXElement(
            role: role,
            subrole: attributes.subrole,
            title: attributes.readString(kAXTitleAttribute),
            description: attributes.readString(kAXDescriptionAttribute),
            value: attributes.value,
            placeholder: attributes.readString(kAXPlaceholderValueAttribute),
            identifier: attributes.readString(kAXIdentifierAttribute)
        )
    }

    /// 从窗口的 `kAXWindowNumberAttribute` 取窗口号；缺失时返回 nil。
    static func windowID(of win: AXUIElement, access: AccessibilityRead = .init()) -> UInt32? {
        guard let v = AXTreeReader.copyValue(win, "AXWindowNumber", access: access) as? NSNumber else {
            return nil
        }
        return v.uint32Value
    }

    public static func secureInputState() -> Bool { IsSecureEventInputEnabled() }
}
