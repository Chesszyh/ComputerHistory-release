import Foundation

public enum ConfigurationInputError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}

private func number(_ text: String, label: String, optional: Bool = false) throws -> Double? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if optional && value.isEmpty { return nil }
    guard let result = Double(value), result.isFinite, result >= 0 else {
        throw ConfigurationInputError.invalid("\(label)请填写不小于 0 的数字。")
    }
    return result
}

private func integer(_ text: String, label: String, minimum: Int = 0) throws -> Int {
    guard let result = Int(text), result >= minimum else {
        throw ConfigurationInputError.invalid("\(label)请填写不小于 \(minimum) 的整数。")
    }
    return result
}

private func serviceURL(_ text: String, label: String) throws -> URL {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme), url.host != nil else {
        throw ConfigurationInputError.invalid("\(label)请填写完整的 http:// 或 https:// 地址。")
    }
    return url
}

public struct PricingDraft: Sendable {
    public var currency = "CNY"
    public var input = "0"
    public var cachedInput = "0"
    public var output = "0"

    public init(_ pricing: ModelPricing? = nil) {
        if let pricing {
            currency = pricing.currency
            input = String(pricing.inputPerMillion)
            cachedInput = String(pricing.cachedInputPerMillion)
            output = String(pricing.outputPerMillion)
        }
    }

    public func value() throws -> ModelPricing {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw ConfigurationInputError.invalid("请填写计费币种，例如 CNY 或 USD。") }
        return try ModelPricing(currency: code,
            inputPerMillion: number(input, label: "输入单价")!,
            cachedInputPerMillion: number(cachedInput, label: "缓存输入单价")!,
            outputPerMillion: number(output, label: "输出单价")!)
    }
}

public struct ModelSettingsDraft: Sendable {
    public var baseURL: String
    public var model: String
    public var requiresAPIKey: Bool
    public var reasoningEffort: String
    public var hasPricing: Bool
    public var pricing: PricingDraft
    public var dailyBudget: String
    public var monthlyBudget: String
    public var hasComparison: Bool
    public var comparisonURL: String
    public var comparisonModel: String
    public var comparisonReasoning: String
    public var comparisonPricing: PricingDraft

    public init(_ settings: ModelSettings? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        baseURL = settings?.baseURL.absoluteString ?? environment["DEEPSEEK_BASE_URL"] ?? DeepSeekClient.defaultBaseURL.absoluteString
        model = settings?.model ?? environment["DEEPSEEK_MODEL"] ?? DeepSeekClient.defaultModel
        requiresAPIKey = settings?.requiresAPIKey ?? true
        reasoningEffort = settings?.reasoningEffort ?? "none"
        hasPricing = settings?.pricing != nil
        pricing = PricingDraft(settings?.pricing)
        dailyBudget = settings?.dailyBudget.map(String.init(describing:)) ?? ""
        monthlyBudget = settings?.monthlyBudget.map(String.init(describing:)) ?? ""
        hasComparison = settings?.comparison != nil
        comparisonURL = settings?.comparison?.baseURL.absoluteString ?? "http://127.0.0.1:11434/v1"
        comparisonModel = settings?.comparison?.model ?? ""
        comparisonReasoning = settings?.comparison?.reasoningEffort ?? "none"
        comparisonPricing = PricingDraft(settings?.comparison?.pricing)
    }

    public func value() throws -> ModelSettings {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationInputError.invalid("请填写模型名称和思考强度。")
        }
        var comparison: ComparisonModelSettings?
        if hasComparison {
            let secondary = comparisonModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secondary.isEmpty, !comparisonReasoning.isEmpty else {
                throw ConfigurationInputError.invalid("请填写对照模型名称和思考强度。")
            }
            comparison = try ComparisonModelSettings(baseURL: serviceURL(comparisonURL, label: "对照服务地址"),
                model: secondary, reasoningEffort: comparisonReasoning, pricing: comparisonPricing.value())
        }
        let daily = try number(dailyBudget, label: "每日预算", optional: true)
        let monthly = try number(monthlyBudget, label: "每月预算", optional: true)
        if !hasPricing && (daily != nil || monthly != nil) {
            throw ConfigurationInputError.invalid("设置预算前，请先开启费用估算并填写单价。")
        }
        return try ModelSettings(baseURL: serviceURL(baseURL, label: "服务地址"), model: name,
            requiresAPIKey: requiresAPIKey, reasoningEffort: reasoningEffort,
            pricing: hasPricing ? pricing.value() : nil, dailyBudget: daily, monthlyBudget: monthly,
            comparison: comparison)
    }
}

public struct CollectorSettingsDraft: Sendable {
    public var defaultApplications: ObservationPolicy.DefaultBehavior
    public var defaultDomains: ObservationPolicy.DefaultBehavior
    public var allowedApplications: [String]
    public var blockedApplications: [String]
    public var allowedDomains: String
    public var blockedDomains: String
    public var forcedBlockedDomains: String
    public var windowTextApplications: [String]
    public var maxTotalMB: String
    public var maxAgeDays: String
    public var unsummarizedDays: String
    public var maxNodes: String
    public var maxLogMB: String

    public init(_ config: CollectorConfig = .init()) {
        defaultApplications = config.policy.defaultApplicationBehavior
        defaultDomains = config.policy.defaultURLBehavior
        allowedApplications = config.policy.allowlist.filter { $0.scope == .app }.compactMap(\.bundleID)
        blockedApplications = config.policy.blocklist.filter { $0.scope == .app }.compactMap(\.bundleID)
        allowedDomains = config.policy.allowlist.filter { $0.scope == .url }.compactMap(\.urlDomain).joined(separator: "\n")
        blockedDomains = config.policy.blocklist.filter { $0.scope == .url }.compactMap(\.urlDomain).joined(separator: "\n")
        forcedBlockedDomains = config.policy.forcedBlockedDomains.joined(separator: "\n")
        windowTextApplications = config.windowTextApplications
        maxTotalMB = String(Double(config.retention.maxTotalBytes) / 1_048_576)
        maxAgeDays = String(config.retention.maxAgeDays)
        unsummarizedDays = String(config.retention.unsummarizedMaxAgeDays)
        maxNodes = String(config.maxNodesPerSnapshot)
        maxLogMB = String(Double(config.maxLogBytes) / 1_048_576)
    }

    public func value() throws -> CollectorConfig {
        func domains(_ text: String) -> [String] {
            text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).map(String.init)
        }
        func bytes(_ text: String, label: String, minimum: Int) throws -> Int {
            let mb = try number(text, label: label)!
            let result = mb * 1_048_576
            guard result < Double(Int.max), result >= Double(minimum) else {
                throw ConfigurationInputError.invalid("\(label)超出可用范围。")
            }
            return Int(result.rounded())
        }
        let policy = ObservationPolicy(defaultApplicationBehavior: defaultApplications, defaultURLBehavior: defaultDomains,
            allowlist: allowedApplications.map(ObservationPolicy.Rule.application) + domains(allowedDomains).map(ObservationPolicy.Rule.domain),
            blocklist: blockedApplications.map(ObservationPolicy.Rule.application) + domains(blockedDomains).map(ObservationPolicy.Rule.domain),
            forcedBlockedDomains: domains(forcedBlockedDomains))
        let config = try CollectorConfig(policy: policy, maxNodesPerSnapshot: integer(maxNodes, label: "界面读取上限", minimum: 1),
            retention: .init(maxTotalBytes: bytes(maxTotalMB, label: "记录容量", minimum: 0),
                maxAgeDays: integer(maxAgeDays, label: "保留天数"),
                unsummarizedMaxAgeDays: integer(unsummarizedDays, label: "未总结记录保留天数")),
            maxLogBytes: bytes(maxLogMB, label: "日志容量", minimum: 1), windowTextApplications: windowTextApplications)
        do { return try CollectorConfig.decode(from: config.jsonData()) }
        catch { throw ConfigurationInputError.invalid("请检查应用名单和网站域名；网站只填写域名，例如 example.com。") }
    }
}
