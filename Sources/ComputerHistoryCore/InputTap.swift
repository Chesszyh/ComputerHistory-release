import Foundation
import CoreGraphics
import AppKit

/// 由 `CGEventTap` 捕获到的原始输入事件，已做初步归类。
///
/// 采集器需要的是"发生了什么"而非"按键的物理细节"，故这里把 CGEvents 归约成
/// 少量语义事件，再交给上层组装成 `EventStreamRecord`。
public enum InputEvent: Sendable {
    case leftMouseDown(clickCount: Int)
    case rightMouseDown(clickCount: Int)
    case otherMouseDown(clickCount: Int)
    case leftMouseDragged
    case keyDown(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool)
    case flagsChanged(flags: CGEventFlags)
}

/// 修饰键的落盘名称。实测样本取值集合：
/// `function` / `command` / `shift` / `control` / `option`。
public enum ModifierNames {
    public static func names(from flags: CGEventFlags) -> [String] {
        var out: [String] = []
        // 顺序与实测样本一致：command 在前，其后 function/shift/control/option。
        if flags.contains(.maskCommand) { out.append("command") }
        if flags.contains(.maskSecondaryFn) { out.append("function") }
        if flags.contains(.maskShift) { out.append("shift") }
        if flags.contains(.maskControl) { out.append("control") }
        if flags.contains(.maskAlternate) { out.append("option") }
        return out
    }

    /// 独立的修饰键按下事件映射到名字；非修饰键返回 nil。
    public static func name(forKeyCode code: UInt16) -> String? {
        switch code {
        case 55, 54: return "command"
        case 56, 60: return "shift"
        case 59, 62: return "control"
        case 58, 61: return "option"
        case 63:     return "function"
        default:     return nil
        }
    }
}

/// 事件 tap 的回调封装。
///
/// `CGEventTap` 的回调是 C 函数指针，没有捕获上下文，因此用全局实例转发。
/// 这层不做任何落盘或耗时工作——tap 回调在系统输入路径上，阻塞会影响全机输入。
public final class InputTap {
    public typealias Handler = (InputEvent) -> Void
    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 单调递增的按键计数，用于把连续可见字符聚成一次 text_input。
    private var lastFlags: CGEventFlags = []

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// 当前进程是否已获 Accessibility 权限（事件 tap 的前置条件）。
    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 请求权限：触发系统弹窗。仅应在交互式启动时调用一次。
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        // 不引用 kAXTrustedCheckOptionPrompt：它是非 Sendable 的全局 var，
        // Swift 6 严格并发下不能读。其字面值即 "AXTrustedCheckOptionPrompt"。
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 启动监听。
    ///
    /// 用 `kCGSessionEventTap`（会话级）而非 `kCGHIDEventTap`：前者足以覆盖本用户
    /// 的输入，且不需要 root。
    public func start() throws {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,       // 只监听，不改写事件
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                me.dispatch(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            throw InputTapError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    private func dispatch(type: CGEventType, event: CGEvent) {
        let flags = event.flags
        switch type {
        case .leftMouseDown:
            handler(.leftMouseDown(clickCount: Int(event.getIntegerValueField(.mouseEventClickState))))
        case .rightMouseDown:
            handler(.rightMouseDown(clickCount: Int(event.getIntegerValueField(.mouseEventClickState))))
        case .otherMouseDown:
            handler(.otherMouseDown(clickCount: Int(event.getIntegerValueField(.mouseEventClickState))))
        case .leftMouseDragged:
            handler(.leftMouseDragged)
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            handler(.keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat))
        case .flagsChanged:
            handler(.flagsChanged(flags: flags))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统会在超时或用户输入时临时禁用 tap，必须显式重新启用，
            // 否则采集会静默停止。
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }
}

public enum InputTapError: Error, CustomStringConvertible {
    case tapCreationFailed

    public var description: String {
        switch self {
        case .tapCreationFailed:
            return "无法创建事件 tap。请确认已授予辅助功能权限"
                + "（系统设置 → 隐私与安全性 → 辅助功能）。"
        }
    }
}
