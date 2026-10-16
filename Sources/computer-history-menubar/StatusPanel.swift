import SwiftUI
import AppKit
import ComputerHistoryCore

/// 菜单栏下拉面板。
struct StatusPanel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if model.showsUsage {
                ModelUsagePane(model: model)
            } else if let detail = model.detail {
                // 详情整屏替换列表。不作并排：MenuBarExtra 不会随内容变宽，
                // 并排的第二栏会被裁在可视区外。
                DetailPane(content: detail, model: model) { model.closeDetail() }
            } else {
                listBody
            }
        }
        .frame(width: 380, height: 640)
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            LiveActivityCard(model: model)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider().opacity(0.4)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    RuntimeSection(model: model)
                    SettingsSection(model: model)
                    Button { model.showsUsage = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 10)
                            Text("总结用量与费用")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("\(model.modelRequests.count) 次请求")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    TimelineSection(model: model)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(HistoryScrollObserver {
                    if model.timelineLimit < model.timelineCount {
                        model.timelineLimit = min(model.timelineLimit + 12, model.timelineCount)
                    }
                })
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.4)

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.stateColor.swatch)
                .frame(width: 8, height: 8)
                .shadow(color: model.stateColor.swatch.opacity(0.4), radius: 2)
            Text("计算机历史")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(model.stateLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(model.stateColor.swatch)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(model.stateColor.swatch.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ToolbarIconButton(icon: "arrow.clockwise", tooltip: "刷新状态") {
                model.refreshAll()
            }
            ToolbarIconButton(icon: "folder", tooltip: "打开数据目录") {
                model.openDataDirectory()
            }
            ToolbarIconButton(icon: "doc.text", tooltip: "查看日志") {
                model.openLog()
            }
            // 手动推一把积压的生成。监督进程按周期跑，但积压多时不必干等。
            ToolbarIconButton(
                icon: model.flushRequested ? "checkmark" : "bolt",
                tooltip: model.flushRequested ? "已请求生成" : "立即生成积压总结") {
                    model.requestFlush()
                }
            ToolbarIconButton(icon: "doc.on.doc", tooltip: "复制近期活动摘要") {
                model.copyRecentSummary()
            }
            Spacer()

            ToolbarIconButton(icon: "power", tooltip: "退出计算机历史") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - 当前活动聚焦卡片

struct LiveActivityCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            appIconView
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.frontApp)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(model.frontDurationLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                if let window = model.frontWindow, !window.isEmpty {
                    Text(window)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("当前前台窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var appIconView: some View {
        if let bundleID = model.frontBundleID,
           let icon = ApplicationBadges.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - 运行状态与指标网格

struct RuntimeSection: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.showsRuntimeDetails.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.showsRuntimeDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("运行状态")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(summaryLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.showsRuntimeDetails {
                RuntimeMetricsGrid(model: model)
            }
        }
    }

    private var summaryLine: String {
        let s = model.status
        return "\(s.data.segmentCount)段 · \(s.data.eventCount)事件 · \(s.memories.count)记忆"
    }
}

struct RuntimeMetricsGrid: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        let status = model.status
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                MetricCard(
                    title: "事件量",
                    value: "\(status.data.eventCount)",
                    subvalue: "\(status.data.segmentCount) 段落"
                )
                MetricCard(
                    title: "占用空间",
                    value: status.sizeLabel(),
                    subvalue: "已运行 \(status.uptimeLabel())"
                )
                MetricCard(
                    title: "记忆积累",
                    value: "\(status.memories.count) 份",
                    subvalue: "\(status.memories.tenMinuteCount) 刻度 · \(status.memories.pendingSegments) 待补"
                )
                MetricCard(
                    title: "最近写入",
                    value: model.relativeLabel(status.data.lastWriteAt),
                    subvalue: status.process.pid.map { "PID \($0)" } ?? "未运行"
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(status.rootDirectory.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            if model.isStalled {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("超过两个段周期未写入，可能卡住或缺少权限")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.top, 2)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let subvalue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(subvalue)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - 历史活动时间线

// 惰性行可能提前创建，分页依据实际滚动位置。
private struct HistoryScrollObserver: NSViewRepresentable {
    var onBottom: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onBottom: onBottom) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onBottom = onBottom
        DispatchQueue.main.async { context.coordinator.connect(view) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.disconnect() }

    @MainActor final class Coordinator {
        var onBottom: () -> Void
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var requested = false

        init(onBottom: @escaping () -> Void) { self.onBottom = onBottom }
        func connect(_ view: NSView) {
            guard let current = view.enclosingScrollView, let document = current.documentView else { return }
            if scroll !== current {
                disconnect()
                scroll = current
                current.contentView.postsBoundsChangedNotifications = true
                document.postsFrameChangedNotifications = true
                for (name, object) in [(NSView.boundsDidChangeNotification, current.contentView),
                                       (NSView.frameDidChangeNotification, document)] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.checkBottom() }
                    })
                }
            }
            checkBottom()
        }
        func disconnect() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            scroll = nil
            requested = false
        }
        private func checkBottom() {
            guard let scroll, let document = scroll.documentView else { return }
            let visible = scroll.contentView.bounds
            if document.bounds.height - visible.maxY > 1 { requested = false; return }
            guard visible.minY > 0, !requested else { return }
            requested = true
            DispatchQueue.main.async { self.onBottom() }
        }
    }
}

struct TimelineSection: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("历史活动")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if model.timelineCount == 0 {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.tertiary)
                    Text("暂无历史活动")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(model.timelineGroups, id: \.day) { group in
                    LazyVStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(model.dayLabel(group.day))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 1)
                        }
                        .padding(.top, 4)

                        LazyVStack(spacing: 6) {
                            ForEach(group.items) { item in
                                TimelineRow(item: item, model: model)

                            }
                        }
                    }
                }
            }
        }
    }
}

struct TimelineRow: View {
    let item: StatusModel.TimelineItem
    @ObservedObject var model: StatusModel

    @State private var isHovered = false

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: item.timestamp)
    }

    /// 合并条目横跨多段时显示起止两行，中间用竖线连起来。
    ///
    /// 只显示起始时刻会让覆盖到的时段看起来像丢了：实测一条 17:20 的条目覆盖到
    /// 17:40，而下一条显示 17:50，使用者会以为 17:30 与 17:40 没有被总结。
    /// 一行放不下 `17:20–17:40`（时间列只有 36pt），故分两行。
    private var isMerged: Bool {
        item.isAway || item.endTimestamp.timeIntervalSince(item.timestamp) > 300
    }

    private var endTimeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: item.endTimestamp)
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(timeLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if isMerged {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 9)
                    .padding(.trailing, 3)
                Text(endTimeLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                timeColumn
                    .frame(width: 36, alignment: .trailing)
                    .padding(.top, 2)

                // 摘要本体：点击即复制。这是最高频的操作——把一段记录贴给别人
                // 或别处——所以给它最大的落点。
                Button {
                    model.copySummary(of: item)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if !item.summary.isEmpty {
                            Text(item.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !item.isAway && (!item.apps.isEmpty || !item.isNarrative) {
                            HStack(spacing: 6) {
                                if !item.apps.isEmpty {
                                    ApplicationBadges(bundleIDs: item.apps)
                                }
                                // 这一条还在记忆层、尚未被归纳进叙述层。标出来，
                                // 否则「还没总结」与「根本没采到」看着一样。
                                if !item.isNarrative {
                                    Text("待归纳")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06))
                                        .clipShape(RoundedRectangle(
                                            cornerRadius: 3.5, style: .continuous))
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击复制这条记录")

                // 概要展开：内容留在原地，不改变布局层级，也不打开新窗口。
                if !item.isAway {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.toggleExpanded(item.id)
                        }
                    } label: {
                        Image(systemName: model.isExpanded(item.id)
                              ? "ellipsis.circle.fill" : "ellipsis.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(model.isExpanded(item.id)
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.tertiary))
                            .opacity(isHovered || model.isExpanded(item.id) ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                    .help(model.isExpanded(item.id) ? "收起概要" : "展开概要详情")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.copiedItemID == item.id
                          ? Color.green.opacity(0.10)
                          : (isHovered ? Color.primary.opacity(0.05)
                             : (model.isExpanded(item.id) ? Color.primary.opacity(0.03)
                                : Color.clear)))
            )
            .overlay(alignment: .topTrailing) {
                // 复制反馈贴在行右上角，不占布局位置。
                if model.copiedItemID == item.id {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        Text("已复制").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.green.opacity(0.15)))
                    .padding(.top, 4)
                    .padding(.trailing, 6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.copiedItemID)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }

            if model.isExpanded(item.id) {
                SummaryDetails(item: item, model: model)
                    .padding(.leading, 46)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
                    // 只用淡入。此前用 `.move(edge: .top)`：插入时视图先向上偏移
                    // 一整个自身高度（约 250pt），再滑到位——看上去像是从很上方的
                    // 分割线掉下来，而不是从本行展开。位移交给布局动画即可。
                    .transition(.opacity)
            }
        }
    }
}

/// 概要详情：原地展开，展示这一条自身的元数据与完整摘要。
///
/// 与侧栏详情的分工：这里回答「这一条是什么」，侧栏回答「它底下记了什么」。
struct SummaryDetails: View {
    let item: StatusModel.TimelineItem
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)

            DetailLine("层级", item.isNarrative ? "叙述层（模型归纳）" : "记忆层（原始记录）")
            DetailLine("时刻", fullTime)
            DetailLine("覆盖", item.coveredCount > 1
                       ? "\(item.coveredCount) 段记忆" : "1 段记忆")
            if let count = item.eventCount {
                DetailLine("事件", "\(count) 条")
            }
            DetailLine("应用", item.apps.isEmpty
                       ? "—" : "\(item.apps.count) 个")

            if !item.summary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("完整摘要")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    // 摘要已在上方按三行截断，这里给全文。
                    Text(item.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            // 这一页多出来的是「逐应用明细」——上面的完整摘要已经有了叙述本身，
            // 所以按钮按它实际多出的内容命名，而不是笼统的「完整记忆」。
            if item.hasDetail {
                Button {
                    model.openDetail(for: item)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 10))
                        Text("逐应用明细").font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8))
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在面板内查看这份记忆的完整分节内容")
            }

            if !item.memoryFiles.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("来源")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(item.memoryFiles, id: \.self) { url in
                        // 直接点击打开，省去先去侧栏再找文件的步骤。
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                Text(url.lastPathComponent)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(Color.accentColor)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("用默认程序打开 \(url.lastPathComponent)")
                    }
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var fullTime: String {
        let f = DateFormatter()
        f.dateFormat = "M-d HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: item.timestamp)
    }
}

/// 一行「标签 值」。
struct DetailLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// 应用图标簇。
struct ApplicationBadges: View {
    let bundleIDs: [String]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(Array(bundleIDs.prefix(7).enumerated()), id: \.offset) { _, bundleID in
                if let icon = Self.icon(for: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                        )
                } else {
                    Text(Self.initial(bundleID))
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 15, height: 15)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                        )
                }
            }
            if bundleIDs.count > 7 {
                Text("+\(bundleIDs.count - 7)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
            }
        }
    }

    @MainActor private static var icons = NSCache<NSString, NSImage>()
    @MainActor private static var missing: Set<String> = []
    @MainActor static func icon(for bundleID: String) -> NSImage? {
        icons.countLimit = 64
        if let icon = icons.object(forKey: bundleID as NSString) { return icon }
        if missing.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            if missing.count >= 64 { missing.removeAll() }
            missing.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    static func initial(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return String(last.prefix(1)).uppercased()
    }
}

// MARK: - 工具栏按钮

struct ToolbarIconButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var showsTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    // 自实现的提示：系统 .help 的延迟固定在一秒以上且不可配置，
                    // 图标工具栏靠它认字太慢。
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard !Task.isCancelled else { return }
                    showsTooltip = true
                }
            } else {
                showsTooltip = false
            }
        }
        // 提示画在按钮上方：底部工具栏之上是滚动区，落在面板边界内不会被裁。
        .overlay(alignment: .bottom) {
            if showsTooltip {
                Text(tooltip)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.82))
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.1), value: showsTooltip)
    }
}

extension StatusModel.StatusColor {
    var swatch: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .secondary: return .secondary
        }
    }
}

// MARK: - 侧栏详情

/// 侧栏：在面板内渲染记忆文档全文。
///
/// 此前是交给默认 Markdown 阅读器打开文件，每看一次就多开一个软件。
/// 这里按记忆文件的固定结构（`###` 分节 + 列表项）就地渲染，
/// 保持与时间线一致的卡片语言。
struct DetailPane: View {
    let content: StatusModel.DetailContent
    @ObservedObject var model: StatusModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider().opacity(0.4)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(content.files) { file in
                        fileView(file)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.4)

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 380, height: 640)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("返回")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回时间线")

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if !content.apps.isEmpty {
                ApplicationBadges(bundleIDs: content.apps)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                model.copyDetail()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.copiedDetail ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(model.copiedDetail ? "已复制" : "复制全文")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.copiedDetail ? Color.green : Color.primary)
            .help("复制整份记忆的 Markdown 原文")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting(content.files.map(\.url))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text("在访达中显示")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在访达中定位该记忆文件")

            Button {
                if let first = content.files.first { NSWorkspace.shared.open(first.url) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                    Text("外部打开")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("使用系统默认应用打开文件")

            Spacer()
        }
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "M-d HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: content.timestamp)
    }

    @ViewBuilder
    private func fileView(_ file: StatusModel.DetailContent.MemoryFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 叙述条目可能覆盖多份记忆，逐份加标题区分。
            if content.files.count > 1 {
                HStack(spacing: 6) {
                    Text(file.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    GranularityTag(granularity: file.granularity)
                    Spacer(minLength: 0)
                }
            }

            if file.sections.isEmpty {
                Text("这份记忆没有分节内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(file.sections.enumerated()), id: \.offset) { _, section in
                    SectionBlock(heading: section.heading, content: section.content)
                }
            }
        }
    }
}

/// 粒度标签（10min / 6h）。
struct GranularityTag: View {
    let granularity: String

    var body: some View {
        Text(granularity)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .foregroundStyle(.secondary)
    }
}

/// 一个小节：标题 + 正文（列表项与段落分开渲染）。
struct SectionBlock: View {
    let heading: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)

            // 记忆正文由模型生成，形态受控：`- ` 列表项与普通段落两类。
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("- ") {
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            inlineText(String(line.dropFirst(2)))
                        }
                    } else {
                        inlineText(line)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    /// 行内 Markdown（`代码`、**粗体**）交给 AttributedString 解析；
    /// 解析失败时退回纯文本，不让内容消失。
    private func inlineText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed).font(.system(size: 11))
        }
        return Text(raw).font(.system(size: 11))
    }
}

// MARK: - 设置

/// 运行开关。
///
/// 与运行状态一样默认收起——它们是「偶尔调一次」的设置，不是日常要看的信息。
struct SettingsSection: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.showsSettings.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.showsSettings ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("设置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.control.recording {
                        PillLabel(text: "已暂停记录", tint: .orange)
                    } else if !model.control.summarizing {
                        PillLabel(text: "已暂停总结", tint: .orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.showsSettings {
                VStack(alignment: .leading, spacing: 0) {
                    ToggleRow(
                        title: "记录活动",
                        subtitle: "关闭后不再采样，也不写入事件",
                        isOn: Binding(
                            get: { model.control.recording },
                            set: { model.setRecording($0) }))
                    Divider().opacity(0.4)
                    ToggleRow(
                        title: "模型总结",
                        subtitle: "关闭后只采集，不生成记忆与叙述",
                        isOn: Binding(
                            get: { model.control.summarizing },
                            set: { model.setSummarizing($0) }))
                    Divider().opacity(0.4)
                    ToggleRow(
                        title: "登录时启动托盘",
                        subtitle: model.loginItemEnabled
                            ? "已登记为登录项"
                            : "开机登录系统时自动启动托盘",
                        isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: { model.setLoginItem($0) }))
                }
                .padding(.top, 4)
            }
        }
    }
}

/// 一行开关：标题 + 说明 + Toggle。
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 6)
    }
}

/// 小圆角标签，用于在收起状态下提示当前处于暂停。
struct PillLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}


struct ModelUsagePane: View {
    @ObservedObject var model: StatusModel
    @State private var filter = ModelRequestFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if model.requestDetail != nil { model.requestDetail = nil }
                    else { model.closeUsage() }
                } label: { Label("返回", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                Spacer()
                Text(model.requestDetail == nil ? "总结用量与费用" : "请求详情")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    model.refreshSlow()
                    if let detail = model.requestDetail { model.openRequest(detail) }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let request = model.requestDetail {
                        requestBody(request)
                    } else {
                        Picker("时段", selection: $filter.period) {
                            ForEach(ModelRequestFilter.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        HStack(spacing: 12) {
                            Picker("任务", selection: $filter.task) {
                                Text("全部任务").tag("")
                                Text("十分钟记忆").tag("10min")
                                Text("六小时汇总").tag("6h")
                                Text("活动整理").tag("narrative")
                            }
                            Picker("来源", selection: $filter.source) {
                                ForEach(ModelRequestFilter.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        }
                        .font(.system(size: 11))
                        totals(filter.period.rawValue, records: filteredRequests)
                        Text("费用按配置单价估算")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        if filteredRequests.isEmpty {
                            Text("这个范围内暂无请求")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.vertical, 16)
                        }
                        if let error = model.requestError { Text(error).foregroundStyle(.red) }
                        ForEach(requestDays, id: \.self) { day in
                            Text(day).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(tasks(on: day), id: \.self) { task in
                                ModelRequestGroup(records: requests(on: day, task: task), model: model)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(.system(size: 11)).padding(14)
    }

    private var filteredRequests: [ModelRequest] { filter.apply(model.modelRequests) }
    private func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private var requestDays: [String] { Set(filteredRequests.map { day($0.startedAt) }).sorted(by: >) }
    private func tasks(on date: String) -> [String] {
        var seen = Set<String>()
        return filteredRequests.filter { day($0.startedAt) == date }.compactMap {
            seen.insert($0.task).inserted ? $0.task : nil
        }
    }
    private func requests(on date: String, task: String) -> [ModelRequest] {
        filteredRequests.filter { day($0.startedAt) == date && $0.task == task }
    }

    private func totals(_ title: String, records: [ModelRequest]) -> some View {
        let costs = records.reduce(into: [String: Double]()) { values, record in
            if let price = record.pricing, let cost = record.estimatedCost {
                values[price.currency, default: 0] += cost
            }
        }
        let input = records.compactMap(\.usage).reduce(0) { $0 + $1.promptTokens }
        let output = records.compactMap(\.usage).reduce(0) { $0 + $1.completionTokens }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(costs.isEmpty ? "—" : costs.keys.sorted().map { "\($0) " + String(format: "%.4f", costs[$0]!) }.joined(separator: " / "))
            }
            Text("\(records.count) 次请求 · 输入 \(input) · 输出 \(output) token")
                .font(.caption).foregroundStyle(.secondary)
            let unknown = records.filter { $0.usage == nil || $0.estimatedCost == nil }.count
            if unknown > 0 { Text("\(unknown) 次请求的用量或费用未知").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func requestBody(_ request: ModelRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(request.taskLabel + " · " + request.statusLabel)
                    .font(.system(size: 12, weight: .semibold))
                Text(request.model).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Text(request.startedAt, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    Text(request.costLabel)
                    if let duration = request.durationSeconds {
                        Text(String(format: "%.1f 秒", duration))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let error = request.error { textBlock("错误", error) }
            textBlock("模型输出", request.output ?? "尚无输出")
            if let parent = request.comparisonOf {
                if let primary = model.modelRequests.first(where: { $0.id == parent }) {
                    Button("查看正式结果") { model.openRequest(primary) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            } else {
                ForEach(model.modelRequests.filter { $0.comparisonOf == request.id }) { secondary in
                    Button("查看对照结果 · " + secondary.model) { model.openRequest(secondary) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
            if let usage = request.usage {
                VStack(alignment: .leading, spacing: 4) {
                    Text("输入 \(usage.promptTokens) · 输出 \(usage.completionTokens) token")
                    HStack {
                        if let cached = usage.cachedPromptTokens { Text("缓存命中 \(cached)") }
                        Text("思考 \(usage.reasoningTokens)")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else { Text("服务未返回用量").font(.system(size: 10)).foregroundStyle(.secondary) }
            Divider().opacity(0.4)
            if !request.sources.isEmpty { RequestDisclosure(title: "原始来源", text: request.sources.joined(separator: "\n")) }
            RequestDisclosure(title: "系统提示词", text: request.system)
            RequestDisclosure(title: "原始输入", text: request.input)
            RequestDisclosure(title: "服务地址", text: request.endpoint)
        }
        .font(.system(size: 11))
        .id(request.id)
    }

    private func textBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.buttonStyle(.plain).font(.caption)
            }
            Text(text).font(.system(size: 11)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Color.primary.opacity(0.04)).cornerRadius(6)
        }
    }
}


struct ModelRequestGroup: View {
    let records: [ModelRequest]
    @ObservedObject var model: StatusModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LazyVStack(spacing: 6) {
                ForEach(records) { request in
                    Button { model.openRequest(request) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(request.comparisonOf == nil ? "正式" : "对照")
                                Text(request.model).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(request.costLabel)
                            }.font(.system(size: 11))
                            HStack {
                                Text(request.startedAt, style: .time)
                                Text(request.statusLabel)
                                Spacer()
                                if let usage = request.usage { Text("入 \(usage.promptTokens) / 出 \(usage.completionTokens)") }
                                else { Text("用量未知") }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 6)
        } label: {
            HStack {
                Text(taskLabel).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(records.count) 次").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var taskLabel: String {
        switch records.first?.task {
        case "10min": return "十分钟记忆"
        case "6h": return "六小时汇总"
        case "narrative": return "活动整理"
        default: return records.first?.task ?? "请求"
        }
    }
}

struct RequestDisclosure: View {
    let title: String
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }.buttonStyle(.plain).font(.system(size: 10))
                }
                Text(text).font(.system(size: 11)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.top, 6)
        } label: {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}
