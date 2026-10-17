import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ComputerHistoryCore

struct SummarySettingsPane: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.showsSummarySettings = false } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Text("总结提示词与配置").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Divider()
            Picker("设置", selection: $model.settingsTab) {
                ForEach(StatusModel.SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            switch model.settingsTab {
            case .prompts: promptEditor
            case .model: modelEditor
            case .collector: collectorEditor
            }
        }
        .padding(14)
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("阶段", selection: Binding(get: { model.summaryStage }, set: {
                model.summaryStage = $0
                model.loadSummaryDraft()
            })) {
                ForEach(SummarySettings.Stage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Text("系统提示词").font(.system(size: 11, weight: .semibold))
            TextEditor(text: $model.summaryDraft)
                .font(.system(size: 11))
                .frame(maxHeight: .infinity)
                .border(Color.primary.opacity(0.15))
                .accessibilityIdentifier("summary-prompt")
            Text("保留提示词中的输出格式，供时间线解析。修改仅影响后续生成。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            feedback(error: model.summarySettingsError, message: model.summaryMessage)
            HStack {
                Button("恢复默认") {
                    model.summaryDraft = model.summaryStage.defaultPrompt
                    model.summaryMessage = "默认提示词已载入，保存后生效"
                }.accessibilityIdentifier("summary-default")
                Spacer()
                Button("保存") { model.saveSummaryDraft() }
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("summary-save")
            }
            SettingsDisclosure("高级选项") { advancedFile("summary.json") }
        }
    }

    private var modelEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCard("模型服务") {
                        SettingsField("服务地址", text: $model.modelDraft.baseURL, placeholder: "https://api.deepseek.com", id: "model-url")
                        SettingsField("模型名称", text: $model.modelDraft.model, placeholder: "deepseek-flash", id: "model-name")
                        Toggle("服务需要密钥", isOn: $model.modelDraft.requiresAPIKey)
                        if model.modelDraft.requiresAPIKey {
                            SecureField("填写新密钥；留空保留现有密钥", text: $model.apiKeyDraft)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("model-key")
                            Text(!model.apiKeyDraft.isEmpty ? "保存后使用新密钥" : (model.removesAPIKey ? "保存后移除已存密钥" : model.apiKeyStatus))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Button(model.removesAPIKey ? "取消移除" : "移除已保存的密钥") { model.removesAPIKey.toggle() }
                                .font(.system(size: 10))
                            Text("密钥保存在 macOS 钥匙串，不写入配置文件或请求记录。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    SettingsDisclosure("费用与预算") {
                        Toggle("估算模型费用", isOn: $model.modelDraft.hasPricing)
                        if model.modelDraft.hasPricing { PricingFields(draft: $model.modelDraft.pricing) }
                        SettingsField("每日预算", text: $model.modelDraft.dailyBudget, placeholder: "留空表示不限制", id: "model-daily")
                        SettingsField("每月预算", text: $model.modelDraft.monthlyBudget, placeholder: "留空表示不限制", id: "model-monthly")
                        Text("预算与单价使用同一币种；达到预算后暂停新请求。未填写单价时费用显示为未知。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    SettingsDisclosure("对照模型") {
                        Toggle("同时请求对照模型", isOn: $model.modelDraft.hasComparison)
                        Text("对照结果仅供比较，不写入正式总结。目前支持无需密钥的服务。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if model.modelDraft.hasComparison {
                            SettingsField("服务地址", text: $model.modelDraft.comparisonURL, placeholder: "http://127.0.0.1:11434/v1", id: "comparison-url")
                            SettingsField("模型名称", text: $model.modelDraft.comparisonModel, placeholder: "服务端的模型名称", id: "comparison-name")
                            reasoningPicker($model.modelDraft.comparisonReasoning)
                            PricingFields(draft: $model.modelDraft.comparisonPricing)
                        }
                    }
                    SettingsDisclosure("高级选项") {
                        reasoningPicker($model.modelDraft.reasoningEffort)
                        advancedFile("model.json")
                    }
                }.padding(.vertical, 2)
            }
            feedback(error: model.modelSettingsError, message: model.modelSettingsMessage)
            HStack {
                Text("保存后，下一次总结使用新设置。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("保存") { model.saveModelConfiguration() }
                    .disabled(!model.modelConfigurationLoaded)
                    .keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("model-save")
            }
        }
    }

    private var collectorEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCard("记录范围") {
                        Picker("应用", selection: $model.collectorDraft.defaultApplications) {
                            Text("记录所有应用，排除名单除外").tag(ObservationPolicy.DefaultBehavior.observe)
                            Text("只记录指定应用").tag(ObservationPolicy.DefaultBehavior.doNotObserve)
                        }
                        SettingsDisclosure("不记录的应用") { ApplicationListEditor(apps: $model.collectorDraft.blockedApplications) }
                        SettingsDisclosure("指定记录的应用") { ApplicationListEditor(apps: $model.collectorDraft.allowedApplications) }
                        Text("排除名单优先；只记录指定应用时，请添加需要记录的应用。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    SettingsDisclosure("网站范围") {
                        Picker("网站", selection: $model.collectorDraft.defaultDomains) {
                            Text("记录所有网站，排除名单除外").tag(ObservationPolicy.DefaultBehavior.observe)
                            Text("只记录指定网站").tag(ObservationPolicy.DefaultBehavior.doNotObserve)
                        }
                        DomainField("不记录的网站", text: $model.collectorDraft.blockedDomains)
                        DomainField("指定记录的网站", text: $model.collectorDraft.allowedDomains)
                    }
                    SettingsDisclosure("窗口文字识别") {
                        Text("为读不到正文的应用补充本地文字识别，需要屏幕录制权限。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        ApplicationListEditor(apps: $model.collectorDraft.windowTextApplications)
                    }
                    SettingsCard("原始记录保留") {
                        SettingsField("最大容量（MB）", text: $model.collectorDraft.maxTotalMB, placeholder: "0 表示不限制", id: "collector-capacity")
                        SettingsField("保留天数", text: $model.collectorDraft.maxAgeDays, placeholder: "0 表示不按天数清理", id: "collector-days")
                        SettingsField("未总结记录保留天数", text: $model.collectorDraft.unsummarizedDays, placeholder: "例如 7", id: "collector-unsummarized")
                        Text("新限制在下次清理时使用；不清理已经生成的总结。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    SettingsDisclosure("高级选项") {
                        SettingsField("每次最多读取的界面节点数", text: $model.collectorDraft.maxNodes, placeholder: "例如 4000", id: "collector-nodes")
                        SettingsField("日志容量（MB）", text: $model.collectorDraft.maxLogMB, placeholder: "例如 8", id: "collector-log")
                        Text("日志容量在监督进程下次启动时应用。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        DomainField("强制排除的网站", text: $model.collectorDraft.forcedBlockedDomains)
                        advancedFile("config.json")
                    }
                }.padding(.vertical, 2)
            }
            feedback(error: model.collectorSettingsError, message: model.collectorSettingsMessage)
            HStack {
                Text("运行中的采集器会自动应用新设置。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("保存") { model.saveCollectorConfiguration() }
                    .disabled(!model.collectorConfigurationLoaded)
                    .keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("collector-save")
            }
        }
    }

    private func reasoningPicker(_ value: Binding<String>) -> some View {
        let options = ["none", "minimal", "low", "medium", "high"]
        return VStack(alignment: .leading, spacing: 4) {
            Picker("思考强度", selection: value) {
                Text("关闭（none）").tag("none")
                Text("最低（minimal）").tag("minimal")
                Text("低（low）").tag("low")
                Text("中（medium）").tag("medium")
                Text("高（high）").tag("high")
                if !options.contains(value.wrappedValue) { Text(value.wrappedValue).tag(value.wrappedValue) }
            }
            Text("服务端需要支持所选强度；通常保持关闭即可。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func advancedFile(_ name: String) -> some View {
        HStack {
            Button("打开 \(name)") { model.openConfiguration(name) }
            Spacer()
            Button("重新读取文件") {
                model.loadConfigurationDrafts()
                model.loadSummaryDraft()
            }
        }.font(.system(size: 10))
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
            Text(title).font(.system(size: 11))
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title).accessibilityIdentifier(id)
        }
    }
}

private struct PricingFields: View {
    @Binding var draft: PricingDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("单价按每百万 token 填写；token 是模型计费的文本单位。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
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
            Text(title).font(.system(size: 11))
            TextEditor(text: $text).font(.system(size: 11)).frame(height: 60)
                .border(Color.primary.opacity(0.15)).accessibilityLabel(title)
            Text("每行一个域名，例如 example.com；同时适用于子域名。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct ApplicationListEditor: View {
    @Binding var apps: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if apps.isEmpty { Text("尚未添加应用").font(.system(size: 10)).foregroundStyle(.secondary) }
            ForEach(apps, id: \.self) { id in
                HStack {
                    Text(applicationName(id)).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Button { apps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("移除 \(applicationName(id))")
                }
            }
            Button("添加应用…") {
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
            }.font(.system(size: 11))
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
            Text(title).font(.system(size: 11, weight: .semibold))
            content
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsDisclosure<Content: View>: View {
    let title: String
    @State private var expanded = false
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 10)
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { content }
        }
    }
}
