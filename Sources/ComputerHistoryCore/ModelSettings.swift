import Foundation

public struct ModelPricing: Codable, Sendable, Equatable {
    public var currency: String
    public var inputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var outputPerMillion: Double

    public init(currency: String = "CNY", inputPerMillion: Double,
                cachedInputPerMillion: Double, outputPerMillion: Double) {
        self.currency = currency; self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion; self.outputPerMillion = outputPerMillion
    }

    public func estimate(_ usage: DeepSeekClient.Usage) -> Double {
        let cached = min(usage.promptTokens, usage.cachedPromptTokens ?? 0)
        return (Double(usage.promptTokens - cached) * inputPerMillion
                + Double(cached) * cachedInputPerMillion
                + Double(usage.completionTokens) * outputPerMillion) / 1_000_000
    }
}

public struct ModelSettings: Codable, Sendable {
    public var baseURL: URL
    public var model: String
    public var requiresAPIKey: Bool
    public var reasoningEffort: String
    public var pricing: ModelPricing?
    public var dailyBudget: Double?
    public var monthlyBudget: Double?
    public var comparison: ComparisonModelSettings?

    public init(baseURL: URL, model: String, requiresAPIKey: Bool = true,
                reasoningEffort: String = "none", pricing: ModelPricing? = nil,
                dailyBudget: Double? = nil, monthlyBudget: Double? = nil,
                comparison: ComparisonModelSettings? = nil) {
        self.baseURL = baseURL; self.model = model; self.requiresAPIKey = requiresAPIKey
        self.reasoningEffort = reasoningEffort; self.pricing = pricing
        self.dailyBudget = dailyBudget; self.monthlyBudget = monthlyBudget
        self.comparison = comparison
    }

    public static func load(root: URL) throws -> ModelSettings? {
        let url = root.appendingPathComponent("model.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate()
            return value
        } catch {
            throw SettingsError.invalid("model.json 无效：\(error.localizedDescription)。请检查模型地址、必填字段和非负单价。")
        }
    }

    public func save(root: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: root.appendingPathComponent("model.json"), options: .atomic)
    }

    private func validate() throws {
        guard ["http", "https"].contains(baseURL.scheme), baseURL.host != nil,
              !model.isEmpty, !reasoningEffort.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        for number in [pricing?.inputPerMillion, pricing?.cachedInputPerMillion,
                       pricing?.outputPerMillion, dailyBudget, monthlyBudget,
                       comparison?.pricing.inputPerMillion, comparison?.pricing.cachedInputPerMillion,
                       comparison?.pricing.outputPerMillion].compactMap({ $0 }) {
            guard number.isFinite, number >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        if let secondary = comparison {
            guard ["http", "https"].contains(secondary.baseURL.scheme), secondary.baseURL.host != nil,
                  !secondary.model.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    public enum SettingsError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String { switch self { case .invalid(let message): return message } }
    }
}

public struct ComparisonModelSettings: Codable, Sendable {
    public var baseURL: URL
    public var model: String
    public var reasoningEffort: String
    public var pricing: ModelPricing
}
