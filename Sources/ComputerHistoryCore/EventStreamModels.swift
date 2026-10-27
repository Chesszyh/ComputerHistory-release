import Foundation

/// Computer History 事件流的落盘模型。
///
/// 字段名、类型与可选性对齐逆向所得的服务端类型（见 re/event-schema.md）。
///
/// **编码契约**（由 88 段真实样本全量实测确认）：
///   - 可选字段为 nil 时**整个键被省略**，绝不写 `null`——18 951 个事件中显式 null 为 0。
///   - 事件时间戳为秒级 RFC3339，按写入时系统时区保留偏移（旧记录的 `Z` 继续可读）。
///   - 服务端类型上标记为非可选的 `Bool`/数组字段（`app.secureInput`、
///     `mouse.modifiers`、`keyboard.modifiers`、`selection.selectedItems`）
///     在取值等于默认值（`false` / 空数组）时**同样被省略**，
///     因此解码必须容忍缺键——这正是本文件手写 `init(from:)` 的原因，
///     合成的 `Decodable` 会强制要求这些键存在而拒绝真实数据。

// MARK: - 顶层记录

public struct EventStreamRecord: Codable, Sendable {
    public var id: Int
    public var timestamp: Date
    public var kind: EventStreamEventKind
    public var app: EventStreamApp?
    public var window: EventStreamWindow?
    public var mouse: EventStreamMouseInteraction?
    public var keyboard: EventStreamKeyboardInteraction?
    public var selection: EventStreamSelection?
    public var ax: EventStreamAXTree?
    public var diagnostic: EventStreamDiagnostic?
    public var activityWatch: ActivityWatchEvidence?

    public init(
        id: Int,
        timestamp: Date,
        kind: EventStreamEventKind,
        app: EventStreamApp? = nil,
        window: EventStreamWindow? = nil,
        mouse: EventStreamMouseInteraction? = nil,
        keyboard: EventStreamKeyboardInteraction? = nil,
        selection: EventStreamSelection? = nil,
        ax: EventStreamAXTree? = nil,
        diagnostic: EventStreamDiagnostic? = nil,
        activityWatch: ActivityWatchEvidence? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.app = app
        self.window = window
        self.mouse = mouse
        self.keyboard = keyboard
        self.selection = selection
        self.ax = ax
        self.diagnostic = diagnostic
        self.activityWatch = activityWatch
    }
}

/// 事件种类。rawValue 即落盘字符串。
///
/// 顺序与枚举 case 索引**必须**与二进制一致：反汇编 rawValue.getter 得出
/// 0..9 的双射，索引 8 的字面量是 `terminal.value_changed`，
/// 而样本同一位置大量出现 `selection.changed`——两者是同一 case 的两个 rawValue。
public enum EventStreamEventKind: String, Codable, Sendable, CaseIterable {
    case sessionStarted = "session.started"
    case sessionEnded = "session.ended"
    case windowChanged = "window.changed"
    case mouseClick = "mouse.click"
    case mouseDrag = "mouse.drag"
    case mouseContextMenu = "mouse.context_menu"
    case keyboardTextInput = "keyboard.text_input"
    case keyboardShortcut = "keyboard.shortcut"
    case selectionChanged = "selection.changed"
    case keyboardSubmit = "keyboard.submit"
    case mouseScroll = "mouse.scroll"

    /// 索引 8 的另一个 rawValue，官方在终端场景下使用。
    public static let terminalValueChangedRawValue = "terminal.value_changed"
}

// MARK: - 嵌套类型

/// 前台应用。
///
/// `secureInput` 服务端为非可选 `Bool`（符号表 `...secureInputSbvg`），
/// 但样本 18 951 个事件里该键仅出现 2 次——默认值被省略。
public struct EventStreamApp: Codable, Sendable, Equatable {
    public var name: String?
    public var secureInput: Bool?
    public var processIdentifier: Int32?
    public var bundleIdentifier: String?

    public init(
        name: String? = nil,
        secureInput: Bool? = nil,
        processIdentifier: Int32? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.name = name
        self.secureInput = secureInput
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        secureInput = try c.decodeIfPresent(Bool.self, forKey: .secureInput)
        processIdentifier = try c.decodeIfPresent(Int32.self, forKey: .processIdentifier)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
    }
}

public struct EventStreamWindow: Codable, Sendable, Equatable {
    public var title: String?
    public var url: String?
    public var windowID: UInt32?

    public init(title: String? = nil, url: String? = nil, windowID: UInt32? = nil) {
        self.title = title
        self.url = url
        self.windowID = windowID
    }
}

/// Accessibility 元素快照。全部字段可选——实测多数事件只带 role，
/// title/description/value 按元素能力出现。
public struct EventStreamAXElement: Codable, Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var placeholder: String?
    public var identifier: String?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        identifier: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.value = value
        self.placeholder = placeholder
        self.identifier = identifier
    }
}

public struct EventStreamAXTree: Codable, Sendable, Equatable {
    public var mode: Mode
    public var text: String
    public var source: String?

    public init(mode: Mode, text: String, source: String? = nil) {
        self.mode = mode
        self.text = text
        self.source = source
    }

    /// 反汇编确认只有两个 case（`tst w0, #0x1`）。
    public enum Mode: String, Codable, Sendable {
        /// 与上一帧的差分，行带 `~`/`+`/`-` 前缀。
        case diffFromPrevious
        /// 整棵树，行无前缀（`<tab×N><elementID> <role> [detail]`）。
        case fullTree
    }
}

/// 编辑活动只说明附近发生过交互，不证明逐字键入、发送或任务完成。
public enum TextEvidence: String, Codable, Sendable {
    case editedValue = "edited_value"
    case uncertainValueChange = "uncertain_value_change"
}

public struct EventStreamKeyboardInteraction: Codable, Sendable, Equatable {
    public var text: String?
    public var textEvidence: TextEvidence?
    public var textReplaces: [String]
    public var focusIdentity: Int?
    public var keyEquivalent: String?
    public var modifiers: [String]
    public var target: EventStreamAXElement?
    enum CodingKeys: String, CodingKey {
        case text
        case textEvidence
        case textReplaces
        case focusIdentity
        case keyEquivalent
        case modifiers
        case target
    }


    public init(
        text: String? = nil,
        textEvidence: TextEvidence? = nil,
        focusIdentity: Int? = nil,
        textReplaces: [String] = [],
        keyEquivalent: String? = nil,
        modifiers: [String] = [],
        target: EventStreamAXElement? = nil
    ) {
        self.text = text
        self.textEvidence = textEvidence
        self.textReplaces = textReplaces
        self.focusIdentity = focusIdentity
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.target = target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        textEvidence = try c.decodeIfPresent(TextEvidence.self, forKey: .textEvidence)
        focusIdentity = try c.decodeIfPresent(Int.self, forKey: .focusIdentity)
        textReplaces = try c.decodeIfPresent([String].self, forKey: .textReplaces) ?? []
        keyEquivalent = try c.decodeIfPresent(String.self, forKey: .keyEquivalent)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        target = try c.decodeIfPresent(EventStreamAXElement.self, forKey: .target)
    }

    /// 与服务端一致：数组为空（默认值）时**省略该键**。
    /// 实测 EventStreamKeyboardInteraction.modifiers 一旦出现即非空，故空数组对应「键不存在」。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(textEvidence, forKey: .textEvidence)
        try c.encodeIfPresent(focusIdentity, forKey: .focusIdentity)
        if !textReplaces.isEmpty { try c.encode(textReplaces, forKey: .textReplaces) }
        try c.encodeIfPresent(keyEquivalent, forKey: .keyEquivalent)
        if !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
        try c.encodeIfPresent(target, forKey: .target)
    }
}

/// 拖拽的起止端点。`mouse.drag` 只用 origin/destination，从不带 target。
public struct EventStreamMouseInteractionDragEndpoint: Codable, Sendable, Equatable {
    public var app: EventStreamApp?
    public var window: EventStreamWindow?
    public var element: EventStreamAXElement?

    public init(
        app: EventStreamApp? = nil,
        window: EventStreamWindow? = nil,
        element: EventStreamAXElement? = nil
    ) {
        self.app = app
        self.window = window
        self.element = element
    }
}

public struct EventStreamMouseInteraction: Codable, Sendable, Equatable {
    public var button: String?
    public var clickCount: Int?
    public var modifiers: [String]
    public var target: EventStreamAXElement?
    public var origin: EventStreamMouseInteractionDragEndpoint?
    public var destination: EventStreamMouseInteractionDragEndpoint?
    enum CodingKeys: String, CodingKey {
        case button
        case clickCount
        case modifiers
        case target
        case origin
        case destination
    }


    public init(
        button: String? = nil,
        clickCount: Int? = nil,
        modifiers: [String] = [],
        target: EventStreamAXElement? = nil,
        origin: EventStreamMouseInteractionDragEndpoint? = nil,
        destination: EventStreamMouseInteractionDragEndpoint? = nil
    ) {
        self.button = button
        self.clickCount = clickCount
        self.modifiers = modifiers
        self.target = target
        self.origin = origin
        self.destination = destination
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decodeIfPresent(String.self, forKey: .button)
        clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        target = try c.decodeIfPresent(EventStreamAXElement.self, forKey: .target)
        origin = try c.decodeIfPresent(EventStreamMouseInteractionDragEndpoint.self,
                                       forKey: .origin)
        destination = try c.decodeIfPresent(EventStreamMouseInteractionDragEndpoint.self,
                                            forKey: .destination)
    }

    /// 与服务端一致：数组为空（默认值）时**省略该键**。
    /// 实测 EventStreamMouseInteraction.modifiers 一旦出现即非空，故空数组对应「键不存在」。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(button, forKey: .button)
        try c.encodeIfPresent(clickCount, forKey: .clickCount)
        if !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(destination, forKey: .destination)
    }
}

public struct EventStreamTextRange: Codable, Sendable, Equatable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct EventStreamSelection: Codable, Sendable, Equatable {
    public var target: EventStreamAXElement?
    public var selectedText: String?
    public var selectedRange: EventStreamTextRange?
    public var selectedItems: [EventStreamAXElement]
    enum CodingKeys: String, CodingKey {
        case target
        case selectedText
        case selectedRange
        case selectedItems
    }


    public init(
        target: EventStreamAXElement? = nil,
        selectedText: String? = nil,
        selectedRange: EventStreamTextRange? = nil,
        selectedItems: [EventStreamAXElement] = []
    ) {
        self.target = target
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.selectedItems = selectedItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decodeIfPresent(EventStreamAXElement.self, forKey: .target)
        selectedText = try c.decodeIfPresent(String.self, forKey: .selectedText)
        selectedRange = try c.decodeIfPresent(EventStreamTextRange.self, forKey: .selectedRange)
        selectedItems = try c.decodeIfPresent([EventStreamAXElement].self,
                                              forKey: .selectedItems) ?? []
    }

    /// 与服务端一致：数组为空（默认值）时**省略该键**。
    /// 实测 EventStreamSelection.selectedItems 一旦出现即非空，故空数组对应「键不存在」。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(selectedText, forKey: .selectedText)
        try c.encodeIfPresent(selectedRange, forKey: .selectedRange)
        if !selectedItems.isEmpty { try c.encode(selectedItems, forKey: .selectedItems) }
    }
}

/// 服务内部诊断。样本 18 951 个事件中从未出现，且二进制内该类型无构造调用点
/// （只有 Decodable 解码器与元数据引用），故当前实现不会产生该字段。
public struct EventStreamDiagnostic: Codable, Sendable, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - 编解码

public enum EventStreamJSON {
    public static var timestampStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard,
            timeSeparator: .colon, timeZoneSeparator: .colon, includingFractionalSeconds: false,
            timeZone: .current)
    }

    public static func timestampString(from date: Date, timeZone: TimeZone = .current,
                                       preservingSubseconds: Bool = false) -> String {
        Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard,
            timeSeparator: .colon, timeZoneSeparator: .colon,
            includingFractionalSeconds: preservingSubseconds, timeZone: timeZone).format(date)
    }

    public static func makeEncoder(preservingSubseconds: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(timestampString(from: date, preservingSubseconds: preservingSubseconds))
        }
        // 与服务端一致：字典序输出键，保证同内容产生同字节（便于回归比对）。
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func makeDecoder(acceptingLegacyNumericDates: Bool = false) -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if acceptingLegacyNumericDates, let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let s = try container.decode(String.self)
            let fractional = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard,
                timeSeparator: .colon, timeZoneSeparator: .colon, includingFractionalSeconds: true,
                timeZone: TimeZone(secondsFromGMT: 0)!)
            let style = s.contains(".") ? fractional : timestampStyle
            guard let date = try? style.parse(s) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "非法时间戳：\(s)"))
            }
            return date
        }
        return d
    }
}
