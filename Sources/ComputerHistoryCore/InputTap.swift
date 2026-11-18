import Foundation
import CoreGraphics
import AppKit

/// 由 `CGEventTap` 捕获到的原始输入事件，已做初步归类。
///
/// 采集器需要的是"发生了什么"而非"按键的物理细节"，故这里把 CGEvents 归约成
/// 少量语义事件，再交给上层组装成 `EventStreamRecord`。
public enum InputEvent: Sendable {
    case leftMouseDown(clickCount: Int, flags: CGEventFlags, location: CGPoint)
    case rightMouseDown(clickCount: Int, flags: CGEventFlags, location: CGPoint)
    case otherMouseDown(clickCount: Int, flags: CGEventFlags, location: CGPoint)
    case keyDown(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool)
    case flagsChanged(flags: CGEventFlags)
    case scroll(deltaX: Double, deltaY: Double, flags: CGEventFlags, location: CGPoint)
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
/// 在同一运行循环上启动、维护和停止监听。C 回调使用实例上下文，
/// 事件处理投递回原运行循环，等系统回调返回后执行。
public final class InputTap {
    struct System {
        var makePort: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort? = { mask, callback, context in
            // A passive session tap does not hold up keyboard or mouse delivery.
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                              eventsOfInterest: mask, callback: callback, userInfo: context)
        }
        var listensToKeys: () -> Bool = { InputTap.hasInputMonitoringPermission }
        var isEnabled: (CFMachPort) -> Bool = { CGEvent.tapIsEnabled(tap: $0) }
        var enable: (CFMachPort, Bool) -> Void = { CGEvent.tapEnable(tap: $0, enable: $1) }
        var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    private let system: System
    private var nextRecoveryAt = Date.distantPast
    private var pendingScroll = false
    private var deliveryGeneration: UInt64 = 0
    public private(set) var interruptionCount = 0

    public typealias Handler = (InputEvent) -> Void
    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var registeredLoop: CFRunLoop?

    public convenience init(handler: @escaping Handler) {
        self.init(system: .init(), handler: handler)
    }

    init(system: System, handler: @escaping Handler) {
        self.system = system
        self.handler = handler
    }

    deinit { stop() }

    /// 系统会话的输入时钟覆盖移动、滚轮和普通按键，不依赖历史中的语义事件。
    public static var secondsSinceLastInput: TimeInterval? {
        let kinds: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let seconds = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
        return seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
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

    /// 当前进程是否已获 Input Monitoring 权限（监听按键如 keyDown 的前置条件）。
    public static var hasInputMonitoringPermission: Bool {
        CGPreflightListenEventAccess()
    }

    /// 请求输入监控权限：触发系统弹窗。仅应在交互式启动时调用。
    @discardableResult
    public static func requestInputMonitoringPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    public var isEnabled: Bool {
        guard let tap, CFMachPortIsValid(tap) else { return false }
        return system.isEnabled(tap)
    }

    /// 当前 tap 是否包含键盘按键监听。
    public private(set) var hasKeyListening: Bool = false

    /// 检查并在监听被系统禁用或失效时重新激活。
    @discardableResult
    public func ensureActive(now: Date = Date()) -> Bool {
        guard isEnabled || now >= nextRecoveryAt else { return false }
        let canListenKeys = system.listensToKeys()
        if let tap, CFMachPortIsValid(tap) {
            // 如果此前未包含按键监听，而现在已获得输入监控授权，需要重建以升级掩码
            if hasKeyListening != canListenKeys {
                nextRecoveryAt = now.addingTimeInterval(30)
                stop()
                do {
                    try start()
                    return isEnabled
                } catch {
                    return false
                }
            }
            if !system.isEnabled(tap) {
                system.enable(tap, true)
            }
            if system.isEnabled(tap) {
                return true
            }
        }
        nextRecoveryAt = now.addingTimeInterval(30)
        stop()
        do {
            try start()
            return isEnabled
        } catch {
            return false
        }
    }

    /// 启动监听。
    ///
    /// 用 `kCGSessionEventTap`（会话级）而非 `kCGHIDEventTap`：前者足以覆盖本用户
    /// 的输入，且不需要 root。
    public func start() throws {
        if let tap, CFMachPortIsValid(tap) { return }
        if tap != nil { stop() }
        nextRecoveryAt = Date().addingTimeInterval(30)
        var mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let canListenKeys = system.listensToKeys()
        if canListenKeys {
            mask |= (1 << CGEventType.keyDown.rawValue)
            mask |= (1 << CGEventType.flagsChanged.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = system.makePort(mask, { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                me.handleDisabled(type: type)
                return nil
            }
            me.dispatch(type: type, event: event, deferred: true)
            return Unmanaged.passUnretained(event)
        }, refcon) else {
            throw InputTapError.tapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw InputTapError.tapCreationFailed
        }
        let loop = CFRunLoopGetCurrent()
        self.tap = tap
        self.runLoopSource = source
        self.registeredLoop = loop
        self.hasKeyListening = canListenKeys
        CFRunLoopAddSource(loop, source, .commonModes)
        system.enable(tap, true)
    }

    public func stop() {
        deliveryGeneration &+= 1
        pendingScroll = false
        hasKeyListening = false
        if let source = runLoopSource, let loop = registeredLoop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        if let tap, CFMachPortIsValid(tap) {
            system.enable(tap, false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        registeredLoop = nil
        tap = nil
    }

    func handleDisabled(type: CGEventType) {
        interruptionCount += 1
        if let tap, CFMachPortIsValid(tap) {
            system.enable(tap, true)
        }
    }

    func dispatch(type: CGEventType, event: CGEvent, deferred: Bool = false) {
        let flags = event.flags
        func send(_ value: InputEvent) {
            if !deferred { handler(value); return }
            // AX queries and persistence run after the system event callback has returned.
            let targetPID = Int32(event.getIntegerValueField(.eventTargetUnixProcessID))
            let generation = deliveryGeneration
            CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self, self.deliveryGeneration == generation else { return }
                if case .scroll = value { self.pendingScroll = false }
                if targetPID > 0, self.system.frontmostPID() != targetPID { return }
                self.handler(value)
            }
        }
        switch type {
        case .leftMouseDown:
            send(.leftMouseDown(clickCount: Int(event.getIntegerValueField(.mouseEventClickState)), flags: flags, location: event.location))
        case .rightMouseDown:
            send(.rightMouseDown(clickCount: Int(event.getIntegerValueField(.mouseEventClickState)), flags: flags, location: event.location))
        case .otherMouseDown:
            send(.otherMouseDown(clickCount: Int(event.getIntegerValueField(.mouseEventClickState)), flags: flags, location: event.location))
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            send(.keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat))
        case .flagsChanged:
            send(.flagsChanged(flags: flags))
        case .scrollWheel:
            guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
            let dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            let dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            guard dx != 0 || dy != 0 else { return }
            if deferred {
                guard !pendingScroll else { return }
                pendingScroll = true
            }
            send(.scroll(deltaX: dx, deltaY: dy, flags: flags, location: event.location))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            handleDisabled(type: type)
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
