import Foundation

public struct ModelGroup: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var allowInsecureHTTP: Bool?
    public var baseURL: URL
    public var model: String
    public var requiresAPIKey: Bool
    public var reasoningEffort: String?
    public var pricing: ModelPricing?
    public var requestStyle: ChatRequestStyle?
    public var timeoutSeconds: Double?

    public init(id: String = UUID().uuidString, name: String, settings: ModelSettings) {
        self.id = id; self.name = name
        allowInsecureHTTP = settings.allowInsecureHTTP
        baseURL = settings.baseURL; model = settings.model; requiresAPIKey = settings.requiresAPIKey
        reasoningEffort = settings.reasoningEffort; pricing = settings.pricing
        requestStyle = settings.requestStyle; timeoutSeconds = settings.timeoutSeconds
    }

    public var settings: ModelSettings {
        var value = ModelSettings(baseURL: baseURL, model: model, requiresAPIKey: requiresAPIKey,
            reasoningEffort: reasoningEffort, pricing: pricing, requestStyle: requestStyle, timeoutSeconds: timeoutSeconds, allowInsecureHTTP: allowInsecureHTTP == true)
        value.credentialGroupID = id
        return value
    }
}

public struct ModelGroups: Codable, Sendable {
    public var groups: [ModelGroup]
    public var primaryGroupID: String
    public var fallbackGroupID: String?
    public var dailyBudget: Double?
    public var monthlyBudget: Double?

    public init(groups: [ModelGroup], primaryGroupID: String, fallbackGroupID: String? = nil,
                dailyBudget: Double? = nil, monthlyBudget: Double? = nil) {
        self.groups = groups; self.primaryGroupID = primaryGroupID; self.fallbackGroupID = fallbackGroupID
        self.dailyBudget = dailyBudget; self.monthlyBudget = monthlyBudget
    }

    public static func load(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let file = root.appendingPathComponent("model.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["groups"] != nil {
                let value = try JSONDecoder().decode(Self.self, from: data)
                _ = try value.resolved()
                return value
            }
        }
        let old = try ModelSettings.load(root: root) ?? ModelSettingsDraft(environment: environment).value()
        var groups = [ModelGroup(id: "legacy-primary", name: "原主模型", settings: old)]
        if let fallback = old.fallback {
            groups.append(ModelGroup(id: "legacy-fallback", name: "原备用模型", settings: ModelSettings(
                baseURL: fallback.baseURL, model: fallback.model, requiresAPIKey: fallback.requiresAPIKey != false,
                reasoningEffort: fallback.reasoningEffort, pricing: fallback.pricing,
                requestStyle: fallback.requestStyle, timeoutSeconds: fallback.timeoutSeconds ?? 45, allowInsecureHTTP: fallback.allowInsecureHTTP == true)))
        }
        return Self(groups: groups, primaryGroupID: groups[0].id, fallbackGroupID: groups.count > 1 ? groups[1].id : nil,
                    dailyBudget: old.dailyBudget, monthlyBudget: old.monthlyBudget)
    }

    public func resolved() throws -> ModelSettings {
        func invalid(_ text: String) -> ModelSettings.SettingsError { .invalid("model.json：" + text) }
        guard !groups.isEmpty, Set(groups.map(\.id)).count == groups.count,
              groups.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw invalid("模型组的 id 必须唯一且非空，name 不能为空。")
        }
        for group in groups { try group.settings.validate() }
        guard let primary = groups.first(where: { $0.id == primaryGroupID }) else {
            throw invalid("primaryGroupID 必须指向已有模型组。")
        }
        var value = primary.settings
        value.dailyBudget = dailyBudget; value.monthlyBudget = monthlyBudget
        if let fallbackGroupID {
            guard fallbackGroupID != primaryGroupID, let group = groups.first(where: { $0.id == fallbackGroupID }) else {
                throw invalid("fallbackGroupID 必须指向另一个已有模型组，或设为 null。")
            }
            var fallback = FallbackModelSettings(baseURL: group.baseURL, model: group.model,
                reasoningEffort: group.reasoningEffort, pricing: group.pricing, requiresAPIKey: group.requiresAPIKey,
                requestStyle: group.requestStyle, timeoutSeconds: group.timeoutSeconds, allowInsecureHTTP: group.allowInsecureHTTP == true)
            fallback.credentialGroupID = group.id
            value.fallback = fallback
        }
        try value.validate()
        if (dailyBudget != nil || monthlyBudget != nil), value.pricing == nil {
            throw invalid("设置预算前，请为主模型组填写单价。")
        }
        return value
    }

    public func save(root: URL) throws {
        _ = try resolved()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: root.appendingPathComponent("model.json"), options: .atomic)
    }
}

public struct ModelGroupDraft: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var settings: ModelSettingsDraft
    public var apiKey = ""
    public var removesAPIKey = false
    public var hasStoredAPIKey = false
    public var availableModels: [ModelCatalog.Entry] = []
    public var manualModel = false
    public var catalogMessage: String?
    public var catalogLoading = false

    public init(_ group: ModelGroup) {
        id = group.id; name = group.name; settings = ModelSettingsDraft(group.settings, environment: [:])
    }

    public func value() throws -> ModelGroup {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw ConfigurationInputError.invalid("请填写模型组名称。") }
        return try ModelGroup(id: id, name: label, settings: settings.value())
    }
}
