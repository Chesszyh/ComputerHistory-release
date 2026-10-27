import Foundation

public struct SummarySettings: Codable, Sendable, Equatable {
    public enum TimelineMode: String, Codable, CaseIterable, Sendable {
        case fixedTenMinutes = "fixed10min"
        case continuous = "continuous"
        public var label: String { self == .fixedTenMinutes ? "固定十分钟，不合并" : "按任务连续性合并" }
        public var explanation: String {
            self == .fixedTenMinutes ? "每段十分钟记忆单独总结，保留该时段的活动细节。"
                : "按具体目标整理活动，同一任务的步骤归组；重叠时段折叠展示，保留各项摘要和完整明细。"
        }
    }
    public var timelineMode: TimelineMode = .continuous
    public var tenMinutePrompt: String?
    public var sixHourPrompt: String?
    public var narrativePrompt: String?
    public var dailyPrompt: String?
    public var weeklyPrompt: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case timelineMode, tenMinutePrompt, sixHourPrompt, narrativePrompt, dailyPrompt, weeklyPrompt
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timelineMode = try values.decodeIfPresent(TimelineMode.self, forKey: .timelineMode) ?? .continuous
        tenMinutePrompt = try values.decodeIfPresent(String.self, forKey: .tenMinutePrompt)
        sixHourPrompt = try values.decodeIfPresent(String.self, forKey: .sixHourPrompt)
        narrativePrompt = try values.decodeIfPresent(String.self, forKey: .narrativePrompt)
        dailyPrompt = try values.decodeIfPresent(String.self, forKey: .dailyPrompt)
        weeklyPrompt = try values.decodeIfPresent(String.self, forKey: .weeklyPrompt)
    }

    public enum Stage: String, CaseIterable, Sendable {
        case tenMinute = "十分钟记忆"
        case sixHour = "六小时汇总"
        case narrative = "活动整理"
        case daily = "日报"
        case weekly = "周报"

        public var explanation: String {
            switch self {
            case .tenMinute: return "从事件中总结动作、对象与关键内容。无明显活动由程序判定，不调用模型。"
            case .sixHour: return "用于命令行手动生成六小时汇总。"
            case .narrative: return "先确定活动归属，再逐组生成概览；该提示词用于概览写法，输出格式由程序追加。"
            case .daily: return "从当天十分钟记忆生成日报，生成前自动补齐缺失或失败的记忆。"
            case .weekly: return "从完整日报生成周报，生成前自动补齐所需记忆与日报。"
            }
        }

        public var defaultPrompt: String {
            switch self {
            case .tenMinute: return MemoryGenerator.systemPrompt
            case .sixHour: return MemoryGenerator.sixHourSystemPrompt
            case .narrative: return NarrativeGenerator.systemPrompt
            case .daily: return ReportKind.daily.prompt
            case .weekly: return ReportKind.weekly.prompt
            }
        }
    }

    public subscript(stage: Stage) -> String {
        get {
            switch stage {
            case .tenMinute: return tenMinutePrompt ?? stage.defaultPrompt
            case .sixHour: return sixHourPrompt ?? stage.defaultPrompt
            case .narrative: return narrativePrompt ?? stage.defaultPrompt
            case .daily: return dailyPrompt ?? stage.defaultPrompt
            case .weekly: return weeklyPrompt ?? stage.defaultPrompt
            }
        }
        set {
            let override = newValue == stage.defaultPrompt ? nil : newValue
            switch stage {
            case .tenMinute: tenMinutePrompt = override
            case .sixHour: sixHourPrompt = override
            case .narrative: narrativePrompt = override
            case .daily: dailyPrompt = override
            case .weekly: weeklyPrompt = override
            }
        }
    }

    public static func load(root: URL) throws -> Self {
        let file = root.appendingPathComponent("summary.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        do {
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["timelineMode", "tenMinutePrompt", "sixHourPrompt", "narrativePrompt", "dailyPrompt", "weeklyPrompt"]) else {
                throw SettingsError.invalid("只支持 timelineMode、tenMinutePrompt、sixHourPrompt、narrativePrompt、dailyPrompt、weeklyPrompt。")
            }
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate()
            return value
        } catch {
            throw SettingsError.invalid("summary.json 无效：\(error)。请打开总结配置文件修正配置。")
        }
    }

    public func save(root: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent("summary.json"), options: .atomic)
    }

    private func validate() throws {
        for (name, prompt) in [("tenMinutePrompt", tenMinutePrompt), ("sixHourPrompt", sixHourPrompt),
                               ("narrativePrompt", narrativePrompt), ("dailyPrompt", dailyPrompt), ("weeklyPrompt", weeklyPrompt)] {
            if let prompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SettingsError.invalid("\(name) 不能为空；恢复默认请删除该字段。")
            }
        }
    }

    public enum SettingsError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): return message } }
    }

    public static let activityRules = """
    内容取舍：
    - 摘要必须经过语义概括。普通聊天不要引用原句，不用“输入/编辑/扩写了某句话”交代内容；
      例如“我对AI工具重度依赖了”应概括为“讨论对AI工具的依赖”。命令、文件名、必要术语和任务特有错误可以保留原文。
    - 应用短暂前台、零碎点击和控件状态本身不是活动；有具体内容的查看、聊天或休闲仍按正常活动总结。
      “页面出现/多次出现询问ChatGPT提示”“页面显示正在思考/回答已完成”等也属于应省略的噪声，不能换种措辞保留。
    - 总结交流、阅读和写作的主题与要点，不逐字搬运原话，不用“在输入区编辑/扩写了……”代替内容总结。
      例如将练习笔记概括为训练时长、交替击打、瞄准与双手配合、难度及准确率；区分讨论的事与电脑上实际完成的事。
    - 控件变化不自动代表用户写作；有编辑证据时概括所写内容，有对话上下文时描述交流主题。
      发送、执行、保存、重命名和导出等结果依据后续证据判断，Return 本身不证明提交。
    - 省略光标移动、快捷键、零碎切换和无关点击。仅在它们直接影响任务结果时概括为相应动作。
    - “询问 ChatGPT”是输入提示；“重新生成回复”“回答已完成”是通用界面反馈，不把它们写成活动。
      任务特有的错误或结果仍应保留；正文中真正讨论这些词语时按内容处理。
    - 会话使用可读标题；没有标题就写 ChatGPT 会话。省略原始会话ID、项目ID、节点编号、内部菜单方法名和 disabled 状态。
    - 按时序识别纠错和文件演变：命令以修正后的有效命令为准；若后续目录、文档路径或重命名/导出界面支持，
      将旧文件名→新文件名→PDF 合并为同一文档的修改、重命名与导出，不列成多个独立编辑任务。
      不能仅凭相似名称断定重命名，也不能凭空将拼错命令改成猜测的正确命令。
    - 只有应用名、空窗口、菜单结构而没有正文时，简述该应用处于前台、未读取到有效内容。
      不由此推断播放歌曲、阅读或持续操作；结构中的“0 标准窗口”是编号为0的节点，不是0个窗口。
    """
}
