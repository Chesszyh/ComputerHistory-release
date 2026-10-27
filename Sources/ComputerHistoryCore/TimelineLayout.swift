import Foundation

/// 时间容器只按区间排布；任务主题和重要性不参与时间轴计算。
public enum TimelineLayout {
    public static func cards(_ items: [TrayTimelineItem]) -> [TrayTimelineItem] {
        func sourceOrder(_ item: TrayTimelineItem) -> Int {
            guard let name = item.sourceActivities?.keys.min() else { return 0 }
            return item.sourceActivities?[name]?.min() ?? 0
        }
        let ordered = items.flatMap(\.leafItems).map { value in
            var item = value
            item.endTimestamp = max(item.timestamp, item.endTimestamp)
            return item
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            let left = sourceOrder($0), right = sourceOrder($1)
            return left == right ? $0.id < $1.id : left < right
        }
        var result: [TrayTimelineItem] = [], members: [TrayTimelineItem] = []
        var end = Date.distantPast
        func flush() {
            guard let first = members.first else { return }
            defer { members = [] }
            guard members.count > 1 else { result.append(first); return }
            var card = first
            card.id = "period:\(first.timestamp.timeIntervalSince1970)"
            let isDegraded = members.allSatisfy { $0.title == ActivityEvidence.inputDegradedTitle }
            let noClearActivity = !isDegraded && members.allSatisfy { $0.noClearActivity == true }
            if isDegraded {
                card.title = ActivityEvidence.inputDegradedTitle
                card.summary = ActivityEvidence.inputDegradedSummary
            } else if noClearActivity {
                card.title = ActivityEvidence.noActivityTitle
                card.summary = ActivityEvidence.noActivitySummary
            } else {
                card.title = "\(first.title)(...等\(members.count)项活动)"
                card.summary = members.dropFirst().prefix(3).map(\.title).joined(separator: "；")
            }
            card.noClearActivity = noClearActivity ? true : nil
            card.endTimestamp = end
            card.children = members
            card.isAway = false
            card.isNarrative = true
            card.taskID = nil
            card.taskTitle = nil
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
            if let first = members.first, item.timestamp != first.timestamp, item.timestamp >= end {
                let adjacentPassive = item.timestamp == end && item.noClearActivity == true
                    && members.allSatisfy { $0.noClearActivity == true }
                if !adjacentPassive { flush() }
            }
            if members.isEmpty { end = max(item.timestamp, item.endTimestamp) }
            else { end = max(end, item.endTimestamp) }
            members.append(item)
        }
        flush()
        return result.reversed()
    }
}
