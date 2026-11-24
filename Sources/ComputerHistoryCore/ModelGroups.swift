import Foundation

public struct ModelTaskConfiguration: Codable, Sendable, Equatable {
    public static let tasks = ["10min", "narrative-grouping", "narrative", "daily", "weekly"]
    public var groupID: String?
    public var reasoningEffort: String?
    public var outputTokenBudget: Int?
    public init(groupID: String? = nil, reasoningEffort: String? = nil, outputTokenBudget: Int? = nil) {
        self.groupID = groupID; self.reasoningEffort = reasoningEffort; self.outputTokenBudget = outputTokenBudget
    }
}

public struct ModelTaskTemplate: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var primaryGroupID: String
    public var fallbackGroupID: String?
    public var tasks: [String: ModelTaskConfiguration]
    public var dailyBudget: Double?
    public var monthlyBudget: Double?

    public init(id: String = UUID().uuidString, name: String, primaryGroupID: String, fallbackGroupID: String? = nil,
                tasks: [String: ModelTaskConfiguration] = [:], dailyBudget: Double? = nil, monthlyBudget: Double? = nil) {
        self.id = id; self.name = name
        self.primaryGroupID = primaryGroupID; self.fallbackGroupID = fallbackGroupID; self.tasks = tasks
        self.dailyBudget = dailyBudget; self.monthlyBudget = monthlyBudget
    }

    public mutating func fillTaskModels() {
        for task in ModelTaskConfiguration.tasks {
            var options = tasks[task] ?? .init()
            if options.groupID == nil { options.groupID = primaryGroupID }
            tasks[task] = options
        }
    }

    public mutating func removeModel(_ id: String, replacement: String) {
        if primaryGroupID == id { primaryGroupID = replacement }
        if fallbackGroupID == id { fallbackGroupID = nil }
        for task in Array(tasks.keys) where tasks[task]?.groupID == id { tasks[task]?.groupID = nil }
    }
}

public struct ModelEndpoint: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var requiresAPIKey: Bool
    public var allowInsecureHTTP: Bool?

    public init(id: String = UUID().uuidString, name: String, baseURL: URL,
                requiresAPIKey: Bool = true, allowInsecureHTTP: Bool = false) {
        self.id = id; self.name = name; self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey; self.allowInsecureHTTP = allowInsecureHTTP
    }
}

public struct ModelGroup: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var endpointID: String?
    public var allowInsecureHTTP: Bool?
    public var baseURL: URL?
    public var model: String
    public var requiresAPIKey: Bool?
    public var reasoningEffort: String?
    public var pricing: ModelPricing?
    public var requestStyle: ChatRequestStyle?
    public var timeoutSeconds: Double?
    public var outputTokenBudget: Int?
    public var fullInput: Bool?

    public init(id: String = UUID().uuidString, name: String, settings: ModelSettings, endpointID: String? = nil) {
        self.id = id; self.name = name; self.endpointID = endpointID
        if endpointID == nil {
            allowInsecureHTTP = settings.allowInsecureHTTP
            baseURL = settings.baseURL
            requiresAPIKey = settings.requiresAPIKey
        }
        model = settings.model
        reasoningEffort = settings.reasoningEffort; pricing = settings.pricing
        requestStyle = settings.requestStyle; timeoutSeconds = settings.timeoutSeconds
        outputTokenBudget = settings.outputTokenBudget; fullInput = settings.fullInput
    }

    var legacyEndpoint: ModelEndpoint? {
        guard let baseURL, let requiresAPIKey else { return nil }
        return ModelEndpoint(id: id, name: name, baseURL: baseURL, requiresAPIKey: requiresAPIKey,
                             allowInsecureHTTP: allowInsecureHTTP == true)
    }

    func settings(using endpoint: ModelEndpoint) -> ModelSettings {
        var value = ModelSettings(baseURL: endpoint.baseURL, model: model, requiresAPIKey: endpoint.requiresAPIKey,
            reasoningEffort: reasoningEffort, pricing: pricing, requestStyle: requestStyle, timeoutSeconds: timeoutSeconds,
            allowInsecureHTTP: endpoint.allowInsecureHTTP == true, outputTokenBudget: outputTokenBudget, fullInput: fullInput == true)
        value.credentialGroupID = endpoint.id
        return value
    }
}

public struct ModelGroups: Codable, Sendable {
    public var groups: [ModelGroup]
    public var endpoints: [ModelEndpoint]?
    public var primaryGroupID: String
    public var fallbackGroupID: String?
    public var dailyBudget: Double?
    public var monthlyBudget: Double?
    public var tasks: [String: ModelTaskConfiguration]?
    public var templates: [ModelTaskTemplate]?
    public var activeTemplateID: String?

    public var activeTemplate: ModelTaskTemplate? {
        templates?.first { $0.id == activeTemplateID }
    }

    public var effectiveTasks: [String: ModelTaskConfiguration]? {
        activeTemplate?.tasks ?? tasks
    }

    public init(groups: [ModelGroup], primaryGroupID: String, fallbackGroupID: String? = nil,
                dailyBudget: Double? = nil, monthlyBudget: Double? = nil, tasks: [String: ModelTaskConfiguration]? = nil,
                endpoints: [ModelEndpoint]? = nil, templates: [ModelTaskTemplate]? = nil, activeTemplateID: String? = nil) {
        self.groups = groups; self.primaryGroupID = primaryGroupID; self.fallbackGroupID = fallbackGroupID
        self.dailyBudget = dailyBudget; self.monthlyBudget = monthlyBudget; self.tasks = tasks
        self.endpoints = endpoints; self.templates = templates; self.activeTemplateID = activeTemplateID
    }

    public static func load(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let value = try readForEditing(root: root, environment: environment)
        _ = try value.resolved()
        return value
    }

    public static func readForEditing(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let file = root.appendingPathComponent("model.json")
        let old: ModelSettings
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["groups"] != nil {
                var value = try JSONDecoder().decode(Self.self, from: data)
                value.tasks?.removeValue(forKey: "6h")
                return value
            }
            old = try JSONDecoder().decode(ModelSettings.self, from: data)
        } else {
            old = try ModelSettingsDraft(environment: environment).value()
        }
        var groups = [ModelGroup(id: "legacy-primary", name: "原主模型", settings: old)]
        if let fallback = old.fallback {
            groups.append(ModelGroup(id: "legacy-fallback", name: "原备用模型", settings: ModelSettings(
                baseURL: fallback.baseURL, model: fallback.model, requiresAPIKey: fallback.requiresAPIKey != false,
                reasoningEffort: fallback.reasoningEffort, pricing: fallback.pricing,
                requestStyle: fallback.requestStyle, timeoutSeconds: fallback.timeoutSeconds ?? ModelSettings.defaultTimeoutSeconds, allowInsecureHTTP: fallback.allowInsecureHTTP == true, outputTokenBudget: fallback.outputTokenBudget, fullInput: fallback.fullInput == true)))
        }
        return Self(groups: groups, primaryGroupID: groups[0].id, fallbackGroupID: groups.count > 1 ? groups[1].id : nil,
                    dailyBudget: old.dailyBudget, monthlyBudget: old.monthlyBudget)
    }

    public func endpoint(for group: ModelGroup) throws -> ModelEndpoint {
        if let id = group.endpointID, let endpoint = endpoints?.first(where: { $0.id == id }) { return endpoint }
        if group.endpointID == nil, let legacy = group.legacyEndpoint,
           endpoints?.contains(where: { $0.id == legacy.id }) != true { return legacy }
        throw ModelSettings.SettingsError.invalid("model.json：模型「\(group.name)」缺少有效的端点。")
    }

    public func withExplicitEndpoints(savedKey: ((String) -> String?)? = nil) throws -> Self {
        var value = self
        var allEndpoints = endpoints ?? []
        var migrated: [ModelEndpoint] = []
        for i in value.groups.indices where value.groups[i].endpointID == nil {
            let endpoint = try endpoint(for: value.groups[i])
            let existing = migrated.first { candidate in
                guard candidate.baseURL.appendingPathComponent("models") == endpoint.baseURL.appendingPathComponent("models"),
                      candidate.requiresAPIKey == endpoint.requiresAPIKey,
                      candidate.allowInsecureHTTP == endpoint.allowInsecureHTTP else { return false }
                if !endpoint.requiresAPIKey { return true }
                guard let key = savedKey?(endpoint.id), !key.isEmpty else { return false }
                return savedKey?(candidate.id) == key
            }
            if existing == nil { migrated.append(endpoint) }
            value.groups[i] = ModelGroup(id: value.groups[i].id, name: value.groups[i].name,
                settings: value.groups[i].settings(using: endpoint), endpointID: (existing ?? endpoint).id)
        }
        allEndpoints.append(contentsOf: migrated)
        value.endpoints = allEndpoints
        return value
    }

    public func resolved(for task: String? = nil) throws -> ModelSettings {
        if activeTemplateID != nil {
            guard let activeTemplate else {
                throw ModelSettings.SettingsError.invalid("model.json：当前模板不存在。")
            }
            return try applying(activeTemplate).resolveRoute(for: task, allowsMatchingFallback: true)
        }
        return try resolveRoute(for: task)
    }

    private func resolveRoute(for task: String? = nil, allowsMatchingFallback: Bool = false) throws -> ModelSettings {
        func invalid(_ text: String) -> ModelSettings.SettingsError { .invalid("model.json：" + text) }
        guard !groups.isEmpty, Set(groups.map(\.id)).count == groups.count,
              groups.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw invalid("模型组的 id 必须唯一且非空，name 不能为空。")
        }
        if let endpoints {
            guard Set(endpoints.map(\.id)).count == endpoints.count,
                  endpoints.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw invalid("端点的 id 必须唯一且非空，name 不能为空。")
            }
            for endpoint in endpoints {
                try ModelTransport.validate(endpoint.baseURL, allowInsecureHTTP: endpoint.allowInsecureHTTP == true)
            }
        }
        for group in groups { try group.settings(using: endpoint(for: group)).validate() }
        for (name, options) in tasks ?? [:] where name != "6h" {
            guard ModelTaskConfiguration.tasks.contains(name),
                  options.groupID == nil || groups.contains(where: { $0.id == options.groupID }),
                  options.outputTokenBudget == nil || options.outputTokenBudget! > 0 else {
                throw invalid("tasks.\(name) 的任务名、模型组或输出额度无效。")
            }
        }
        if dailyBudget != nil || monthlyBudget != nil {
            let currency = groups.first(where: { $0.id == primaryGroupID })?.pricing?.currency
            for (name, options) in tasks ?? [:] where name != "6h" {
                let selected = groups.first(where: { $0.id == (options.groupID ?? primaryGroupID) })
                guard let pricing = selected?.pricing, pricing.currency == currency else {
                    throw invalid("tasks.\(name) 的模型组需填写与主模型相同计费币种的单价，才能应用统一预算。")
                }
            }
        }
        guard groups.contains(where: { $0.id == primaryGroupID }) else {
            throw invalid("primaryGroupID 必须指向已有模型组。")
        }
        let options = task.flatMap { tasks?[$0] }
        let selectedID = options?.groupID ?? primaryGroupID
        guard let primary = groups.first(where: { $0.id == selectedID }) else {
            throw invalid("primaryGroupID 必须指向已有模型组。")
        }
        var value = primary.settings(using: try endpoint(for: primary))
        if let effort = options?.reasoningEffort { value.reasoningEffort = effort }
        if let budget = options?.outputTokenBudget { value.outputTokenBudget = budget }
        value.dailyBudget = dailyBudget; value.monthlyBudget = monthlyBudget
        if let fallbackGroupID {
            guard (allowsMatchingFallback || fallbackGroupID != primaryGroupID), let group = groups.first(where: { $0.id == fallbackGroupID }) else {
                throw invalid("fallbackGroupID 必须指向另一个已有模型组，或设为 null。")
            }
            let endpoint = try endpoint(for: group)
            var fallback = FallbackModelSettings(baseURL: endpoint.baseURL, model: group.model,
                reasoningEffort: group.reasoningEffort, pricing: group.pricing, requiresAPIKey: endpoint.requiresAPIKey,
                requestStyle: group.requestStyle, timeoutSeconds: group.timeoutSeconds, allowInsecureHTTP: endpoint.allowInsecureHTTP == true,
                outputTokenBudget: group.outputTokenBudget, fullInput: group.fullInput == true)
            fallback.credentialGroupID = endpoint.id
            if fallbackGroupID != selectedID { value.fallback = fallback }
        }
        try value.validate()
        return value
    }

    public func applying(_ template: ModelTaskTemplate) -> Self {
        var value = self
        value.activeTemplateID = nil
        value.primaryGroupID = template.primaryGroupID
        value.fallbackGroupID = template.fallbackGroupID
        value.tasks = template.tasks.isEmpty ? nil : template.tasks
        value.dailyBudget = template.dailyBudget
        value.monthlyBudget = template.monthlyBudget
        return value
    }

    public func validateForSaving() throws {
        _ = try resolveRoute()
        _ = try resolved()
        if let templates {
            guard Set(templates.map(\.id)).count == templates.count,
                  Set(templates.map(\.name)).count == templates.count,
                  templates.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ConfigurationInputError.invalid("任务模板的名称和标识必须唯一且非空。")
            }
            for template in templates { _ = try applying(template).resolveRoute(allowsMatchingFallback: true) }
        }
    }

    public func save(root: URL) throws {
        try validateForSaving()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var value = self
        value.tasks?.removeValue(forKey: "6h")
        try encoder.encode(value).write(to: root.appendingPathComponent("model.json"), options: .atomic)
    }
}

public struct ModelEndpointDraft: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var requiresAPIKey: Bool
    public var allowInsecureHTTP: Bool
    public var apiKey = ""
    public var removesAPIKey = false
    public var hasStoredAPIKey = false
    public var availableModels: [ModelCatalog.Entry] = []
    public var catalogMessage: String?
    public var catalogLoading = false

    public init(_ endpoint: ModelEndpoint) {
        id = endpoint.id; name = endpoint.name; baseURL = endpoint.baseURL.absoluteString
        requiresAPIKey = endpoint.requiresAPIKey; allowInsecureHTTP = endpoint.allowInsecureHTTP == true
    }

    public func value() throws -> ModelEndpoint {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw ConfigurationInputError.invalid("请填写端点名称。") }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
            throw ConfigurationInputError.invalid("请为「\(label)」填写完整的服务地址。")
        }
        return ModelEndpoint(id: id, name: label, baseURL: url, requiresAPIKey: requiresAPIKey, allowInsecureHTTP: allowInsecureHTTP)
    }
}

public struct ModelGroupDraft: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var endpointID: String
    public var settings: ModelSettingsDraft
    public var manualModel = false

    public init(_ group: ModelGroup, endpoint: ModelEndpoint? = nil) {
        id = group.id; name = group.name
        let connection = endpoint ?? group.legacyEndpoint ?? ModelEndpoint(id: group.id, name: group.name,
            baseURL: DeepSeekClient.defaultBaseURL)
        endpointID = connection.id
        settings = ModelSettingsDraft(group.settings(using: connection), environment: [:])
    }

    public func value(endpoint: ModelEndpoint? = nil) throws -> ModelGroup {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw ConfigurationInputError.invalid("请填写模型配置名称。") }
        var draft = settings
        if let endpoint {
            draft.baseURL = endpoint.baseURL.absoluteString
            draft.requiresAPIKey = endpoint.requiresAPIKey
            draft.allowInsecureHTTP = endpoint.allowInsecureHTTP == true
        }
        return try ModelGroup(id: id, name: label, settings: draft.value(), endpointID: endpoint?.id)
    }
}
