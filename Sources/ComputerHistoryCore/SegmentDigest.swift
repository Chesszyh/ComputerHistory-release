import Foundation

/// 把一个 segment 的事件归纳成结构化摘要。
///
/// 这是**确定性**的：只用事件字段做聚合，不做自然语言推断。
/// 官方记忆里的 `Memory summary` 段含判断性描述（如「未观察到持续的开发工作」），
/// 那部分需要语言模型；本类型只产出可从数据直接证实的内容，
/// 让记忆在无模型时也可用，且内容可追溯。
public struct SegmentDigest: Sendable {

    /// 单个应用在本段内的活动。
    public struct AppActivity: Sendable {
        public var bundleIdentifier: String
        public var displayName: String
        public var eventCount: Int
        public var firstSeen: Date
        public var lastSeen: Date
        public var clickCount: Int
        public var shortcutCount: Int
        /// 本段内记录的输入片段，按时间顺序。
        public var typedTexts: [String]
        /// 出现过的窗口标题（去重、保序）。
        public var windowTitles: [String]
        /// 出现过的 URL（去重、保序）。
        public var urls: [String]

        public var duration: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
    }

    public var segmentID: String
    public var startedAt: Date
    public var endedAt: Date
    public var eventCount: Int
    public var suppressedEventCount: Int
    /// 组成该摘要的段数（含事件者），供粗粒度汇总如实描述记录范围。
    public var coveredSegments: Int
    /// 按事件数降序。
    public var activities: [AppActivity]

    /// 参与本段的应用，字典序，用于 frontmatter 的 `applications`。
    public var applications: [String] { activities.map(\.bundleIdentifier).sorted() }

    /// 事件最多的应用，用于取标题。
    public var dominantActivity: AppActivity? { activities.first }

    /// 各段「首末事件跨度」之和。
    ///
    /// 这是**可证实的下界**：只知道每段内首末事件之间的时间有活动，
    /// 段与段之间、以及段内事件之间的空隙都可能没有记录。
    /// 不能用 `endedAt - startedAt`——那是首末记录的跨度，会把大片空白算成活动。
    public var recordedSpan: TimeInterval {
        activities.map(\.duration).reduce(0, +)
    }

    /// 合并同一时间窗内的多段摘要，用于更粗粒度的汇总。
    ///
    /// 按 bundleID 合并同类活动：事件数与交互数相加，时间范围取并集，
    /// 窗口标题与 URL 去重后保序。合并结果与直接对全部事件归纳等价，
    /// 但无需重新读取事件文件。
    public static func merging(_ digests: [SegmentDigest], bucketID: String) -> SegmentDigest {
        var byApp: [String: AppActivity] = [:]
        var order: [String] = []
        var totalEvents = 0
        var totalSuppressed = 0
        var starts: [Date] = []
        var ends: [Date] = []

        for digest in digests {
            totalEvents += digest.eventCount
            totalSuppressed += digest.suppressedEventCount
            if digest.eventCount > 0 {
                starts.append(digest.startedAt)
                ends.append(digest.endedAt)
            }
            for activity in digest.activities {
                var merged: AppActivity
                if let existing = byApp[activity.bundleIdentifier] {
                    merged = existing
                } else {
                    // 首次出现：取标识与时间范围，但计数必须清零——
                    // 下面的累加会把它自己那份加回来，否则首项被计两次。
                    merged = activity
                    merged.eventCount = 0
                    merged.clickCount = 0
                    merged.shortcutCount = 0
                    merged.windowTitles = []
                    merged.urls = []
                    merged.typedTexts = []
                    order.append(activity.bundleIdentifier)
                }
                merged.eventCount += activity.eventCount
                merged.clickCount += activity.clickCount
                merged.shortcutCount += activity.shortcutCount
                merged.firstSeen = min(merged.firstSeen, activity.firstSeen)
                merged.lastSeen = max(merged.lastSeen, activity.lastSeen)
                for title in activity.windowTitles where !merged.windowTitles.contains(title) {
                    merged.windowTitles.append(title)
                }
                for url in activity.urls where !merged.urls.contains(url) {
                    merged.urls.append(url)
                }
                merged.typedTexts.append(contentsOf: activity.typedTexts)
                byApp[activity.bundleIdentifier] = merged
            }
        }

        let activities = order.compactMap { byApp[$0] }.sorted {
            if $0.eventCount != $1.eventCount { return $0.eventCount > $1.eventCount }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }

        return SegmentDigest(
            segmentID: bucketID,
            startedAt: starts.min() ?? Date(timeIntervalSince1970: 0),
            endedAt: ends.max() ?? Date(timeIntervalSince1970: 0),
            eventCount: totalEvents,
            suppressedEventCount: totalSuppressed,
            coveredSegments: digests.filter { $0.eventCount > 0 }.count,
            activities: activities)
    }

    /// 从事件列表归纳。
    ///
    /// - Parameters:
    ///   - events: 按时间升序的事件。
    ///   - segmentID: 段目录名。
    public static func make(events: [EventStreamRecord], segmentID: String,
                            suppressedEventCount: Int = 0) -> SegmentDigest {
        var byApp: [String: AppActivity] = [:]
        var order: [String] = []

        for event in events {
            guard let app = event.app, let bundle = app.bundleIdentifier else { continue }
            var activity: AppActivity
            if let existing = byApp[bundle] {
                activity = existing
            } else {
                activity = AppActivity(
                    bundleIdentifier: bundle,
                    displayName: app.name ?? bundle,
                    eventCount: 0, firstSeen: event.timestamp, lastSeen: event.timestamp,
                    clickCount: 0, shortcutCount: 0, typedTexts: [],
                    windowTitles: [], urls: [])
                order.append(bundle)
            }
            activity.eventCount += 1
            activity.firstSeen = min(activity.firstSeen, event.timestamp)
            activity.lastSeen = max(activity.lastSeen, event.timestamp)

            switch event.kind {
            case .mouseClick, .mouseContextMenu:
                activity.clickCount += 1
            case .keyboardShortcut:
                activity.shortcutCount += 1
            case .keyboardTextInput:
                if let text = event.keyboard?.text, !text.isEmpty {
                    activity.typedTexts.append(text)
                }
            default:
                break
            }

            if let title = event.window?.title, !title.isEmpty,
               !activity.windowTitles.contains(title) {
                activity.windowTitles.append(title)
            }
            if let url = event.window?.url, !url.isEmpty,
               !activity.urls.contains(url) {
                activity.urls.append(url)
            }
            byApp[bundle] = activity
        }

        let activities = order.compactMap { byApp[$0] }
            .sorted {
                if $0.eventCount != $1.eventCount { return $0.eventCount > $1.eventCount }
                return $0.bundleIdentifier < $1.bundleIdentifier
            }

        return SegmentDigest(
            segmentID: segmentID,
            startedAt: events.first?.timestamp ?? Date(timeIntervalSince1970: 0),
            endedAt: events.last?.timestamp ?? Date(timeIntervalSince1970: 0),
            eventCount: events.count,
            suppressedEventCount: suppressedEventCount,
            coveredSegments: events.isEmpty ? 0 : 1,
            activities: activities)
    }
}
