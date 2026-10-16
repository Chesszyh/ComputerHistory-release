import Foundation

public struct ModelRequestFilter: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable {
        case today = "今天", yesterday = "昨天", week = "本周", month = "本月"
    }
    public enum Source: String, CaseIterable, Sendable {
        case all = "全部请求", primary = "正式请求", comparison = "对照请求"
    }
    public var period: Period = .today
    public var source: Source = .all
    public var task: String = ""
    public init() {}

    public func apply(_ records: [ModelRequest], now: Date = Date(), calendar: Calendar = .current) -> [ModelRequest] {
        var calendar = calendar
        calendar.firstWeekday = 2
        let anchor = period == .yesterday ? calendar.date(byAdding: .day, value: -1, to: now)! : now
        let component: Calendar.Component = period == .week ? .weekOfYear : (period == .month ? .month : .day)
        guard let interval = calendar.dateInterval(of: component, for: anchor) else { return [] }
        return records.filter {
            $0.startedAt >= interval.start && $0.startedAt < interval.end
                && (task.isEmpty || $0.task == task)
                && (source == .all || (source == .primary ? $0.comparisonOf == nil : $0.comparisonOf != nil))
        }
    }
}
