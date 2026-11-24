import Foundation

/// 时间容器按来源起点排列。来源覆盖范围可以相交，不能用来推断活动持续时间。
public enum TimelineLayout {
    public static func cards(_ items: [TrayTimelineItem]) -> [TrayTimelineItem] {
        func sourceOrder(_ item: TrayTimelineItem) -> Int {
            guard let name = item.sourceActivities?.keys.min() else { return 0 }
            return item.sourceActivities?[name]?.min() ?? 0
        }
        let ordered = items.flatMap(\.leafItems).filter { !$0.isPassive }.map { value in
            var item = value
            item.endTimestamp = max(item.timestamp, item.endTimestamp)
            return item
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            let left = sourceOrder($0), right = sourceOrder($1)
            return left == right ? $0.id < $1.id : left < right
        }
        var result: [TrayTimelineItem] = [], members: [TrayTimelineItem] = []
        func flush() {
            guard let first = members.first else { return }
            defer { members = [] }
            guard members.count > 1 else { result.append(first); return }
            var card = first
            card.id = "period:\(first.timestamp.timeIntervalSince1970)"
            let isDegraded = members.allSatisfy { $0.title == ActivityEvidence.inputDegradedTitle }
            if isDegraded {
                card.title = ActivityEvidence.inputDegradedTitle
                card.summary = ActivityEvidence.inputDegradedSummary
            } else if members.contains(where: \.isAway) {
                card.title = "\(members.count) 条记录"
                card.summary = members.prefix(3).map(\.title).joined(separator: "；")
            } else {
                let lead = members.first(where: { $0.isPreferredTimelineTitle == true }) ?? first
                card.title = lead.title
                card.summary = members.lazy.filter { $0.id != lead.id }.prefix(3).map(\.title).joined(separator: "；")
            }
            card.noClearActivity = nil
            card.endTimestamp = first.timestamp
            card.children = members
            card.isAway = false
            card.isNarrative = true
            card.taskID = nil
            card.taskTitle = nil
            card.isPreferredTimelineTitle = nil
            card.sourceRevisions = nil
            card.sourceActivities = nil
            card.sourceSteps = nil
            card.sourceIncidental = nil
            card.sharesSourcePeriod = nil
            card.manualEdit = nil
            card.memoryFiles = Array(Set(members.flatMap(\.memoryFiles))).sorted { $0.path < $1.path }
            card.apps = Array(Set(members.flatMap(\.apps))).sorted()
            card.coveredCount = card.memoryFiles.count
            result.append(card)
        }
        for item in ordered {
            if let first = members.first, item.timestamp != first.timestamp { flush() }
            members.append(item)
        }
        flush()
        return result.reversed()
    }
}
