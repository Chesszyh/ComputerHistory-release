import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ComputerHistoryCore

struct SummarySettingsPane: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider().opacity(0.4)

            Picker("设置", selection: $model.settingsTab) {
                ForEach(StatusModel.SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Group {
                switch model.settingsTab {
                case .timeline: timelineEditor
                case .prompts: promptEditor
                case .model: modelEditor
                case .collector: collectorEditor
                case .backup: backupEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 380, height: 640)
    }

    private var timelineEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("总结模式").font(.system(size: 12, weight: .semibold))
            Picker("总结模式", selection: $model.timelineMode) {
                ForEach(SummarySettings.TimelineMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("timeline-mode")
            .disabled(!model.timelineSettingsLoaded || model.timelineRebuilding)
            Text(model.timelineMode.explanation)
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("时间线按先后顺序排列，活动时段互不重叠。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            feedback(error: model.timelineSettingsError, message: model.timelineSettingsMessage)
            if model.showsTimelineRecalculation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("如何处理已有总结？").font(.system(size: 11, weight: .semibold))
                    Text("重算使用当前模型，保留原始记录和十分钟记忆。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("重算当天总结") { model.recalculateTimeline(.today) }.accessibilityIdentifier("timeline-recalculate-today")
                        Button("重算所有总结") { model.recalculateTimeline(.all) }.accessibilityIdentifier("timeline-recalculate-all")
                        Button("不重算") { model.recalculateTimeline(.none) }.accessibilityIdentifier("timeline-recalculate-none")
                    }.controlSize(.small)
                }
            }
            if model.timelineRebuilding {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("停止重算") { model.cancelTimelineRecalculation() }.accessibilityIdentifier("timeline-cancel")
                }
            }
            SettingsDisclosure("高级选项") { advancedFile("summary.json") }
            Spacer()
            Divider().opacity(0.4)
            HStack {
                Spacer()
                Button("保存模式…") { model.saveTimelineSettings() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!model.timelineSettingsLoaded || model.timelineRebuilding)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("timeline-save")
            }
        }
        .padding(14)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                model.showsSummarySettings = false
            } label: {
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
            .accessibilityIdentifier("summary-settings-back")

            Spacer()
            Text("总结提示词与配置")
                .font(.system(size: 12, weight: .semibold))
            Spacer()

            Color.clear.frame(width: 48, height: 20)
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("阶段", selection: Binding(get: { model.summaryStage }, set: {
                model.summaryStage = $0
                model.loadSummaryDraft()
            })) {
                ForEach(SummarySettings.Stage.allCases.filter { $0 != .sixHour }, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            Text("系统提示词")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextEditor(text: $model.summaryDraft)
                .font(.system(size: 11, design: .monospaced))
                .padding(4)
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityIdentifier("summary-prompt")

            Text("保留提示词中的输出格式，供时间线解析。修改仅影响后续生成。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            feedback(error: model.summarySettingsError, message: model.summaryMessage)

            Divider().opacity(0.4)

            HStack {
                Button("恢复默认") {
                    model.summaryDraft = model.summaryStage.defaultPrompt
                    model.summaryMessage = "默认提示词已载入，保存后生效"
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .accessibilityIdentifier("summary-default")

                Spacer()

                Button("保存 (⌘S)") { model.saveSummaryDraft() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("summary-save")
            }

            SettingsDisclosure("高级选项") { advancedFile("summary.json") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func requestStylePicker(_ style: Binding<ChatRequestStyle>) -> some View {
        Picker("请求格式", selection: style) {
            ForEach(ChatRequestStyle.allCases, id: \.self) { Text($0.label).tag($0) }
        }.font(.system(size: 11))
    }

    private var backupEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCard("GitHub 私有备份") {
                        Toggle("启用每日备份", isOn: $model.backupEnabled).accessibilityIdentifier("backup-enabled")
                        SettingsField("私有仓库", text: $model.backupRepository, placeholder: "owner/repository", id: "backup-repository")
                        Text("使用已登录的 GitHub CLI（gh），备份整理后的活动文本和正式报告。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(model.backupMessage).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("立即备份") { model.runReportCommand(["backup"], message: "备份完成，已核对远端提交") }
                            .disabled(!model.effectiveBackupEnabled || model.reportBusy)
                    }
                }.padding(14)
            }
            feedback(error: model.reportError, message: model.reportMessage)
            HStack {
                Spacer()
                Button("保存 (⌘S)") { model.saveBackupSettings() }.buttonStyle(.borderedProminent)
                    .controlSize(.small).disabled(!model.backupLoaded || model.reportBusy)
                    .accessibilityIdentifier("backup-save")
            }.padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    private func modelGroupEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsField("组名称", text: $model.modelGroups[index].name, placeholder: "例如：DeepSeek、工作网关、本地模型", id: "group-name")
            SettingsField("服务地址", text: Binding(get: {
                model.modelGroups[index].settings.baseURL
            }, set: { value in
                model.modelGroups[index].settings.baseURL = value
                model.modelGroups[index].availableModels = []
                model.modelGroups[index].catalogMessage = nil
                model.modelGroups[index].manualModel = false
            }), placeholder: "https://api.deepseek.com", id: "model-url")
            if !model.modelGroups[index].availableModels.isEmpty && !model.modelGroups[index].manualModel {
                Picker("模型", selection: $model.modelGroups[index].settings.model) {
                    ForEach(model.modelGroups[index].availableModels) { entry in
                        Text(entry.name.map { $0 + " · " + entry.id } ?? entry.id).tag(entry.id)
                    }
                    if !model.modelGroups[index].availableModels.contains(where: { $0.id == model.modelGroups[index].settings.model }) {
                        Text(model.modelGroups[index].settings.model + "（当前配置）").tag(model.modelGroups[index].settings.model)
                    }
                }
                Button("手动填写模型") { model.modelGroups[index].manualModel = true }.font(.system(size: 10))
            } else {
                SettingsField("模型名称", text: $model.modelGroups[index].settings.model, placeholder: "deepseek-flash", id: "model-name")
            }
            Button(model.modelGroups[index].catalogLoading ? "正在读取…" : "从服务获取模型") {
                model.fetchModelCatalog(groupID: model.modelGroups[index].id)
            }.disabled(model.modelGroups[index].catalogLoading).accessibilityIdentifier("model-catalog")
            if let message = model.modelGroups[index].catalogMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            requestStylePicker($model.modelGroups[index].settings.requestStyle)
            Text("参数格式不决定是否推理，需按服务接口选择。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            reasoningEditor(index)
            SettingsField("超时（秒）", text: $model.modelGroups[index].settings.timeoutSeconds, placeholder: "60", id: "model-timeout")
            Toggle("允许此服务使用明文 HTTP（活动内容和密钥可能被窃听）", isOn: $model.modelGroups[index].settings.allowInsecureHTTP)
            Toggle("服务需要密钥", isOn: $model.modelGroups[index].settings.requiresAPIKey)
            if model.modelGroups[index].settings.requiresAPIKey {
                SecureField("填写新密钥；留空保留现有密钥", text: $model.modelGroups[index].apiKey)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("model-key")
                Text(!model.modelGroups[index].apiKey.isEmpty ? "保存后使用新密钥" :
                    (model.modelGroups[index].removesAPIKey ? "保存后移除已存密钥" : model.apiKeyStatus(for: model.modelGroups[index])))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button(model.modelGroups[index].removesAPIKey ? "取消移除" : "移除已保存的密钥") {
                    model.modelGroups[index].removesAPIKey.toggle()
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Text("密钥跟随模型组保存在 macOS 钥匙串。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            SettingsDisclosure("费用单价") {
                Toggle("估算模型费用", isOn: $model.modelGroups[index].settings.hasPricing)
                if model.modelGroups[index].settings.hasPricing { PricingFields(draft: $model.modelGroups[index].settings.pricing) }
            }
        }.font(.system(size: 11))
    }

    private var modelEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCard("使用的模型组") {
                        Picker("主模型组", selection: Binding(get: { model.primaryGroupID }, set: { id in
                            model.primaryGroupID = id
                            if model.fallbackGroupID == id { model.fallbackGroupID = "" }
                        })) {
                            ForEach(model.modelGroups) { Text($0.name).tag($0.id) }
                        }
                        Picker("备用模型组", selection: $model.fallbackGroupID) {
                            Text("不使用").tag("")
                            ForEach(model.modelGroups.filter { $0.id != model.primaryGroupID }) { Text($0.name).tag($0.id) }
                        }
                        Text("主模型请求失败时尝试备用组；下次仍先使用主模型组。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    SettingsCard("管理模型组") {
                        Picker("编辑", selection: $model.editingGroupID) {
                            ForEach(model.modelGroups) { Text($0.name).tag($0.id) }
                        }
                        HStack {
                            Button("新增模型组") { model.addModelGroup() }
                            Spacer()
                            Button("删除模型组", role: .destructive) { model.removeEditingModelGroup() }
                                .disabled(model.modelGroups.count < 2 || model.editingGroupID == model.primaryGroupID || model.editingGroupID == model.fallbackGroupID)
                        }
                        if let index = model.modelGroups.firstIndex(where: { $0.id == model.editingGroupID }) {
                            modelGroupEditor(index)
                        }
                    }
                    SettingsDisclosure("预算") {
                        SettingsField("每日预算", text: $model.dailyBudget, placeholder: "留空表示不限制", id: "model-daily")
                        SettingsField("每月预算", text: $model.monthlyBudget, placeholder: "留空表示不限制", id: "model-monthly")
                        Text("预算使用主模型组的计费币种；设置预算前需填写该组单价。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    SettingsDisclosure("高级选项") {
                        advancedFile("model.json")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                feedback(error: model.modelSettingsError, message: model.modelSettingsMessage)
                HStack {
                    Text("保存后，下一次总结使用新设置。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("保存 (⌘S)") { model.saveModelConfiguration() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!model.modelConfigurationLoaded)
                        .keyboardShortcut("s", modifiers: .command)
                        .accessibilityIdentifier("model-save")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var collectorEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCard("记录范围") {
                        Picker("应用", selection: $model.collectorDraft.defaultApplications) {
                            Text("记录所有应用，排除名单除外").tag(ObservationPolicy.DefaultBehavior.observe)
                            Text("只记录指定应用").tag(ObservationPolicy.DefaultBehavior.doNotObserve)
                        }
                        .font(.system(size: 11))
                        SettingsDisclosure("不记录的应用") { ApplicationListEditor(apps: $model.collectorDraft.blockedApplications) }
                        SettingsDisclosure("指定记录的应用") { ApplicationListEditor(apps: $model.collectorDraft.allowedApplications) }
                        Text("排除名单优先；只记录指定应用时，请添加需要记录的应用。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    SettingsDisclosure("网站范围") {
                        Picker("网站", selection: $model.collectorDraft.defaultDomains) {
                            Text("记录所有网站，排除名单除外").tag(ObservationPolicy.DefaultBehavior.observe)
                            Text("只记录指定网站").tag(ObservationPolicy.DefaultBehavior.doNotObserve)
                        }
                        .font(.system(size: 11))
                        DomainField("不记录的网站", text: $model.collectorDraft.blockedDomains)
                        DomainField("指定记录的网站", text: $model.collectorDraft.allowedDomains)
                    }

                    SettingsDisclosure("窗口文字识别") {
                        Text("为读不到正文的应用补充本地文字识别，需要屏幕录制权限。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        ApplicationListEditor(apps: $model.collectorDraft.windowTextApplications,
                            disabledApps: $model.collectorDraft.windowTextDisabledApplications)
                    }

                    SettingsDisclosure("ActivityWatch") {
                        Toggle("接入本机 ActivityWatch", isOn: $model.collectorDraft.activityWatchEnabled)
                            .accessibilityIdentifier("activitywatch-enabled")
                        Text("补充当前应用、网址与空闲状态；连接 127.0.0.1:5600，不导入旧记录。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    SettingsCard("原始记录保留") {
                        SettingsField("最大容量（MB）", text: $model.collectorDraft.maxTotalMB, placeholder: "0 表示不限制", id: "collector-capacity")
                        SettingsField("保留天数", text: $model.collectorDraft.maxAgeDays, placeholder: "0 表示不按天数清理", id: "collector-days")
                        SettingsField("未总结记录保留天数", text: $model.collectorDraft.unsummarizedDays, placeholder: "例如 7", id: "collector-unsummarized")
                        Text("新限制在下次清理时使用；不清理已经生成的总结。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    SettingsDisclosure("高级选项") {
                        SettingsField("每次最多读取的界面节点数", text: $model.collectorDraft.maxNodes, placeholder: "例如 4000", id: "collector-nodes")
                        SettingsField("日志容量（MB）", text: $model.collectorDraft.maxLogMB, placeholder: "例如 8", id: "collector-log")
                        Text("日志容量在监督进程下次启动时应用。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        DomainField("强制排除的网站", text: $model.collectorDraft.forcedBlockedDomains)
                        advancedFile("config.json")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                feedback(error: model.collectorSettingsError, message: model.collectorSettingsMessage)
                HStack {
                    Text("运行中的采集器会自动应用新设置。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("保存 (⌘S)") { model.saveCollectorConfiguration() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!model.collectorConfigurationLoaded)
                        .keyboardShortcut("s", modifiers: .command)
                        .accessibilityIdentifier("collector-save")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private func reasoningEditor(_ index: Int) -> some View {
        let effort = model.modelGroups[index].availableModels.first { $0.id == model.modelGroups[index].settings.model }?.effort
        return VStack(alignment: .leading, spacing: 4) {
            SettingsField("推理强度", text: $model.modelGroups[index].settings.reasoningEffort,
                placeholder: "留空使用服务默认值", id: "model-reasoning")
            if let effort, !effort.supported_levels.isEmpty {
                HStack {
                    Menu("选择服务支持的强度") {
                        Button("服务默认值") { model.modelGroups[index].settings.reasoningEffort = "" }
                        ForEach(effort.supported_levels, id: \.self) { level in
                            Button(level) { model.modelGroups[index].settings.reasoningEffort = level }
                        }
                    }
                    if let value = effort.default_level { Text("服务默认：" + value).foregroundStyle(.secondary) }
                }.font(.system(size: 10))
            }
        }
    }

    private func advancedFile(_ name: String) -> some View {
        HStack {
            Button("打开 \(name)") { model.openConfiguration(name) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            Spacer()
            Button("重新读取文件") {
                model.loadConfigurationDrafts()
                model.loadSummaryDraft()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
    }

    @ViewBuilder private func feedback(error: String?, message: String?) -> some View {
        if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red).textSelection(.enabled) }
        if let message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
    }
}

private struct SettingsField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let id: String
    init(_ title: String, text: Binding<String>, placeholder: String, id: String) {
        self.title = title; _text = text; self.placeholder = placeholder; self.id = id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .accessibilityLabel(title)
                .accessibilityIdentifier(id)
        }
    }
}

private struct PricingFields: View {
    @Binding var draft: PricingDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("单价按每百万 token 填写；token 是模型计费的文本单位。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            SettingsField("币种", text: $draft.currency, placeholder: "CNY 或 USD", id: "pricing-currency")
            SettingsField("输入单价", text: $draft.input, placeholder: "0", id: "pricing-input")
            SettingsField("缓存输入单价", text: $draft.cachedInput, placeholder: "0", id: "pricing-cache")
            SettingsField("输出单价", text: $draft.output, placeholder: "0", id: "pricing-output")
        }
    }
}

private struct DomainField: View {
    let title: String
    @Binding var text: String
    init(_ title: String, text: Binding<String>) { self.title = title; _text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 60)
                .padding(2)
                .background(Color.primary.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityLabel(title)
            Text("每行一个域名，例如 example.com；同时适用于子域名。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

struct ApplicationListEditor: View {
    @Binding var apps: [String]
    var disabledApps: Binding<[String]>? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if apps.isEmpty {
                Text("尚未添加应用")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            }
            ForEach(apps, id: \.self) { id in
                HStack(spacing: 6) {
                    if let disabledApps {
                        Toggle(applicationName(id), isOn: Binding(
                            get: { !disabledApps.wrappedValue.contains(id) },
                            set: { enabled in
                                disabledApps.wrappedValue.removeAll { $0 == id }
                                if !enabled { disabledApps.wrappedValue.append(id) }
                            }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("ocr-application-\(id)")
                    } else {
                        Image(systemName: "app.fill").foregroundStyle(.secondary)
                        Text(applicationName(id)).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        apps.removeAll { $0 == id }
                        disabledApps?.wrappedValue.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除 \(applicationName(id))")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.applicationBundle]
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.prompt = "添加"
                if panel.runModal() == .OK {
                    for url in panel.urls {
                        if let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) { apps.append(id) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10))
                    Text("添加应用…")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 2)
        }
    }

    private func applicationName(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path)
        }
        let known = ["com.1password.1password": "1Password", "com.1password.1password7": "1Password 7",
            "com.agilebits.onepassword7": "1Password 7", "com.bitwarden.desktop": "Bitwarden",
            "com.lastpass.LastPass": "LastPass", "com.dashlane.dashlanephonefinal": "Dashlane",
            "in.sinew.Enpass-Desktop": "Enpass", "org.keepassxc.keepassxc": "KeePassXC",
            "com.apple.keychainaccess": "钥匙串访问", "com.apple.Passwords": "密码"]
        return known[id] ?? id
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

struct SettingsDisclosure<Content: View>: View {
    let title: String
    @State private var expanded = false
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.02))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "已展开" : "已收起")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(.horizontal, 4)
            }
        }
    }
}
