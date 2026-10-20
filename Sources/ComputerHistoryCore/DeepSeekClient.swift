import Foundation

/// OpenAI 兼容的非流式对话客户端；主请求失败后，仅为本次请求尝试降级模型。
public struct DeepSeekClient: Sendable {

    public struct Usage: Codable, Sendable, Equatable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int
        /// 其中用于推理的 token。推理与正文共享 `max_tokens` 预算，
        /// 预算被推理吃光时正文为空且 `finishReason` 为 `length`。
        public var reasoningTokens: Int
        public var cachedPromptTokens: Int? = nil
    }

    public struct Completion: Sendable {
        public var text: String
        public var usage: Usage?
        public var finishReason: String?

        /// 因预算耗尽而没产出正文。
        public var truncatedByBudget: Bool {
            text.isEmpty && finishReason == "length"
        }
    }

    public enum ClientError: Error, CustomStringConvertible {
        case missingAPIKey
        case http(status: Int, body: String)
        case malformedResponse(String)
        case transport(String)
        case budgetExceeded(String)

        public var description: String {
            switch self {
            case .missingAPIKey:
                return "未找到模型密钥。请在菜单栏的模型设置中填写，或设置 DEEPSEEK_API_KEY 环境变量。"
            case .http(let status, let body):
                return "接口返回 HTTP \(status)：\(body.prefix(300))"
            case .malformedResponse(let detail):
                return "响应格式不符：\(detail)"
            case .budgetExceeded(let detail): return detail
            case .transport(let detail):
                return "请求失败：\(detail)"
            }
        }
    }

    public static let defaultBaseURL = URL(string: "https://api.deepseek.com")!
    public static let defaultModel = "deepseek-flash"

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let timeout: TimeInterval
    private let settings: ModelSettings?
    private let fallbackAPIKey: String

    public init(apiKey: String,
                baseURL: URL = DeepSeekClient.defaultBaseURL,
                model: String = DeepSeekClient.defaultModel,
                timeout: TimeInterval = 120,
                settings: ModelSettings? = nil, fallbackAPIKey: String = "") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.settings = settings; self.fallbackAPIKey = fallbackAPIKey
    }

    /// 从环境变量构造。密钥缺失时抛错，避免静默降级成"生成成功但内容为空"。
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        rootDirectory: URL? = nil
    ) throws -> DeepSeekClient {
        if let rootDirectory, let config = try ModelSettings.load(root: rootDirectory) {
            let key = config.requiresAPIKey
                ? (try ModelAPIKey.load(root: rootDirectory, groupID: config.credentialGroupID) ?? environment["DEEPSEEK_API_KEY"] ?? "") : ""
            if config.requiresAPIKey, key.isEmpty, config.fallback == nil { throw ClientError.missingAPIKey }
            return DeepSeekClient(apiKey: config.requiresAPIKey ? key : "", baseURL: config.baseURL,
                                  model: config.model, timeout: config.timeoutSeconds ?? 60, settings: config,
                                  fallbackAPIKey: environment["COMPUTER_HISTORY_FALLBACK_API_KEY"] ?? "")
        }
        guard let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
            throw ClientError.missingAPIKey
        }
        let model = environment["DEEPSEEK_MODEL"] ?? defaultModel
        let base = environment["DEEPSEEK_BASE_URL"].flatMap(URL.init(string:)) ?? defaultBaseURL
        return DeepSeekClient(apiKey: key, baseURL: base, model: model)
    }

    // 回调线程与等待线程通过锁交接结果，避免可变捕获跨越 Sendable 边界。
    private final class ResponseState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Completion, Error> = .failure(ClientError.transport("请求未完成"))

        func store(_ result: Result<Completion, Error>) {
            lock.lock()
            defer { lock.unlock() }
            value = result
        }

        func load() -> Result<Completion, Error> {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// 执行一次逻辑总结请求；每次实际模型尝试分别记录输入、输出和用量。
    public func complete(system: String, user: String, maxTokens: Int = 8000,
                         temperature: Double = 0.3, reasoningEffort: String = "",
                         recordingAt root: URL? = nil, task: String = "summary", sources: [String] = []) throws -> Completion {
        let id = UUID().uuidString
        do {
            let response = try completeAttempt(id: id, system: system, user: user, maxTokens: maxTokens,
                temperature: temperature, reasoningEffort: reasoningEffort, recordingAt: root, task: task, sources: sources)
            guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.finishReason != "length" else {
                throw ClientError.malformedResponse("主模型返回空内容或输出截断")
            }
            if let root { try ModelHealth.record(root: root, error: nil, usedFallback: false) }
            return response
        } catch ClientError.budgetExceeded(let message) {
            throw ClientError.budgetExceeded(message)
        } catch {
            guard error is ClientError else { throw error }
            let primaryError = String(describing: error)
            guard let secondary = settings?.fallback else {
                if let root { try ModelHealth.record(root: root, error: primaryError, usedFallback: false) }
                throw error
            }
            let config = ModelSettings(baseURL: secondary.baseURL, model: secondary.model,
                requiresAPIKey: secondary.requiresAPIKey != false, reasoningEffort: secondary.reasoningEffort,
                pricing: secondary.pricing, requestStyle: secondary.requestStyle, timeoutSeconds: secondary.timeoutSeconds)
            do {
                let key: String
                if secondary.requiresAPIKey == false { key = "" }
                else if let root { key = try ModelAPIKey.load(root: root, fallback: true, groupID: secondary.credentialGroupID) ?? fallbackAPIKey }
                else { key = fallbackAPIKey }
                let fallback = DeepSeekClient(apiKey: key, baseURL: secondary.baseURL, model: secondary.model,
                    timeout: secondary.timeoutSeconds ?? 45, settings: config)
                let response = try fallback.completeAttempt(id: UUID().uuidString, fallbackOf: id,
                    system: system, user: user, maxTokens: maxTokens, temperature: temperature,
                    recordingAt: root, task: task, sources: sources)
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.finishReason != "length" else {
                    throw ClientError.malformedResponse("降级模型返回空内容或输出截断")
                }
                if let root { try ModelHealth.record(root: root, error: nil, usedFallback: true) }
                return response
            } catch {
                let message = "主模型：\(primaryError)；降级模型：\(error)"
                if let root { try ModelHealth.record(root: root, error: message, usedFallback: true) }
                throw ClientError.transport(message)
            }
        }
    }

    private func completeAttempt(id: String, fallbackOf: String? = nil, system: String, user: String,
                         maxTokens: Int = 8000,
                         temperature: Double = 0.3,
                         reasoningEffort: String = "",
                         recordingAt root: URL? = nil, task: String = "summary",
                         sources: [String] = []) throws -> Completion {
        let started = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let pricing = settings?.pricing
        if let root, let settings, let pricing,
           settings.dailyBudget != nil || settings.monthlyBudget != nil {
            let dir = root.appendingPathComponent("requests")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let previous = files.compactMap { try? ModelRequest.load(url: $0) }
                .filter { $0.pricing?.currency == pricing.currency }
            let cal = Calendar.current
            let today = previous.filter { cal.isDate($0.startedAt, inSameDayAs: started) }.compactMap(\.estimatedCost).reduce(0, +)
            let month = previous.filter { cal.isDate($0.startedAt, equalTo: started, toGranularity: .month) }.compactMap(\.estimatedCost).reduce(0, +)
            if let cap = settings.dailyBudget, today >= cap {
                throw ClientError.budgetExceeded("已达到今日总结预算（\(pricing.currency) \(cap)）")
            }
            if let cap = settings.monthlyBudget, month >= cap {
                throw ClientError.budgetExceeded("已达到本月总结预算（\(pricing.currency) \(cap)）")
            }
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if !apiKey.isEmpty && settings?.requiresAPIKey != false { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let effort = settings?.reasoningEffort ?? reasoningEffort
        var payload: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
        ]
        if !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload["reasoning_effort"] = effort.trimmingCharacters(in: .whitespacesAndNewlines) }
        if settings?.requestStyle == .reasoning {
            payload["max_completion_tokens"] = max(12000, maxTokens + 8000)
        } else {
            payload["max_tokens"] = maxTokens
            payload["temperature"] = temperature
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var record = ModelRequest(id: id, startedAt: started,
            model: model, endpoint: baseURL.absoluteString, task: task, sources: sources,
            status: "running", system: system, input: user, pricing: pricing, fallbackOf: fallbackOf)
        record.worker = CollectorProcessIdentity.read(pid: getpid())
        // 请求前落盘失败就不外发，避免产生无法查询的付费请求。
        if let root { try record.save(root: root) }

        if settings?.requiresAPIKey == true && apiKey.isEmpty {
            record.status = "failed"; record.error = String(describing: ClientError.missingAPIKey); record.finishedAt = Date()
            if let root { try record.save(root: root) }
            throw ClientError.missingAPIKey
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ResponseState()

        let networkTask = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result.store(.failure(ClientError.transport(error.localizedDescription)))
                return
            }
            guard let data, let http = response as? HTTPURLResponse else {
                result.store(.failure(ClientError.transport("无响应")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                result.store(.failure(ClientError.http(
                    status: http.statusCode,
                    body: String(decoding: data, as: UTF8.self))))
                return
            }
            result.store(Self.parse(data))
        }
        networkTask.resume()
        let completionResult: Result<Completion, Error>
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            networkTask.cancel()
            completionResult = .failure(ClientError.transport("模型请求超过 \(Int(timeout)) 秒总耗时上限"))
        } else { completionResult = result.load() }

        record.finishedAt = Date()
        record.durationSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
        switch completionResult {
        case .success(let completion):
            record.output = completion.text
            record.usage = completion.usage
            record.finishReason = completion.finishReason
            record.status = completion.finishReason == "length" ? "truncated" : (completion.text.isEmpty ? "empty" : "success")
            record.estimatedCost = completion.usage.flatMap { usage in pricing.map { $0.estimate(usage) } }
            if let root { try record.save(root: root) }
            return completion
        case .failure(let error):
            record.status = "failed"
            record.error = String(describing: error)
            if let root { try record.save(root: root) }
            throw error
        }
    }

    static func parse(_ data: Data) -> Result<Completion, Error> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(ClientError.malformedResponse("不是 JSON 对象")) }
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else { return .failure(ClientError.malformedResponse("缺少 choices[0].message")) }
        let text = (message["content"] as? String) ?? ""

        var usage: Usage?
        if let u = root["usage"] as? [String: Any],
           let prompt = u["prompt_tokens"] as? Int,
           let completion = u["completion_tokens"] as? Int {
            let details = u["completion_tokens_details"] as? [String: Any]
            let promptDetails = u["prompt_tokens_details"] as? [String: Any]
            usage = Usage(
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: (u["total_tokens"] as? Int) ?? prompt + completion,
                reasoningTokens: (details?["reasoning_tokens"] as? Int) ?? 0,
                cachedPromptTokens: (u["prompt_cache_hit_tokens"] as? Int) ?? (promptDetails?["cached_tokens"] as? Int))
        }
        return .success(Completion(text: text, usage: usage,
                                   finishReason: first["finish_reason"] as? String))
    }
}
