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
        case sleepDeferred

        public var description: String {
            switch self {
            case .sleepDeferred: return "系统休眠或合盖，总结等待唤醒后继续。"
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
    var generationIdentity: String { requestIdentity(task: "") }
    private var taskSettings: [String: ModelSettings] = [:]
    private var credentialRoot: URL?
    func requestIdentity(task: String) -> String {
        if let config = taskSettings[task] {
            return DeepSeekClient(apiKey: "", baseURL: config.baseURL, model: config.model, settings: config).requestIdentity(task: "")
        }
        return [baseURL.absoluteString, model, settings?.reasoningEffort ?? "", String(settings?.outputTokenBudget ?? ModelSettings.defaultOutputTokenBudget), settings?.requestStyle?.rawValue ?? "standard", settings?.fallback?.baseURL.absoluteString ?? "",
            settings?.fallback?.model ?? "", settings?.fallback?.reasoningEffort ?? "", settings?.fallback?.outputTokenBudget.map(String.init) ?? "", settings?.fallback?.requestStyle?.rawValue ?? "standard"].joined(separator: "|")
    }

    var usesFullInput: Bool { settings?.fullInput == true || settings?.fallback?.fullInput == true || taskSettings.values.contains { $0.fullInput == true || $0.fallback?.fullInput == true } }

    private let timeout: TimeInterval
    private let settings: ModelSettings?
    private let fallbackAPIKey: String
    var powerState: GenerationPowerState = .shared

    public init(apiKey: String,
                baseURL: URL = DeepSeekClient.defaultBaseURL,
                model: String = DeepSeekClient.defaultModel,
                timeout: TimeInterval = ModelSettings.defaultTimeoutSeconds,
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
            let groups = try ModelGroups.load(root: rootDirectory, environment: environment)
            if config.requiresAPIKey, key.isEmpty, config.fallback == nil, groups.tasks?.isEmpty != false { throw ClientError.missingAPIKey }
            var client = DeepSeekClient(apiKey: config.requiresAPIKey ? key : "", baseURL: config.baseURL,
                                  model: config.model, timeout: config.timeoutSeconds ?? ModelSettings.defaultTimeoutSeconds, settings: config,
                                  fallbackAPIKey: environment["COMPUTER_HISTORY_FALLBACK_API_KEY"] ?? "")
            client.credentialRoot = rootDirectory
            for task in groups.tasks?.keys.sorted() ?? [] {
                client.taskSettings[task] = try groups.resolved(for: task)
            }
            return client
        }
        guard let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
            throw ClientError.missingAPIKey
        }
        let model = environment["DEEPSEEK_MODEL"] ?? defaultModel
        let base: URL
        if let address = environment["DEEPSEEK_BASE_URL"] {
            guard let url = URL(string: address) else {
                throw ModelSettings.SettingsError.invalid("DEEPSEEK_BASE_URL 无效，请填写完整的 HTTPS 或本机 HTTP 地址。")
            }
            base = url
        } else { base = defaultBaseURL }
        try ModelTransport.validate(base)
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
    public func complete(system: String, user: String, maxTokens: Int = ModelSettings.defaultOutputTokenBudget,
                         temperature: Double = 0.3, reasoningEffort: String = "", requiresJSONObject: Bool = false,
                         recordingAt root: URL? = nil, task: String = "summary", sources: [String] = []) throws -> Completion {
        try powerState.check()
        if let config = taskSettings[task] {
            let sameGroup = config.credentialGroupID == settings?.credentialGroupID
            let key: String
            if !config.requiresAPIKey { key = "" }
            else if sameGroup { key = apiKey }
            else if let credentialRoot {
                key = try ModelAPIKey.load(root: credentialRoot, groupID: config.credentialGroupID)
                    ?? (config.credentialGroupID == settings?.fallback?.credentialGroupID ? fallbackAPIKey : "")
            } else { key = "" }
            var routed = DeepSeekClient(apiKey: key, baseURL: config.baseURL, model: config.model,
                timeout: config.timeoutSeconds ?? ModelSettings.defaultTimeoutSeconds, settings: config, fallbackAPIKey: fallbackAPIKey)
            routed.powerState = powerState
            return try routed.complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature,
                reasoningEffort: reasoningEffort, requiresJSONObject: requiresJSONObject, recordingAt: root, task: task, sources: sources)
        }
        let id = UUID().uuidString
        guard let powerRevision = powerState.snapshot() else { throw ClientError.sleepDeferred }
        try powerState.check(powerRevision)
        do {
            let response = try completeWithLengthRetry(id: id, system: system, user: user, maxTokens: maxTokens,
                temperature: temperature, reasoningEffort: reasoningEffort, requiresJSONObject: requiresJSONObject, recordingAt: root, task: task, sources: sources)
            guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.finishReason != "length" else {
                throw ClientError.malformedResponse("主模型返回空内容或输出截断")
            }
            if let root { try ModelHealth.record(root: root, error: nil, usedFallback: false) }
            return response
        } catch ClientError.budgetExceeded(let message) {
            throw ClientError.budgetExceeded(message)
        } catch {
            if case ClientError.sleepDeferred = error { throw error }
            try powerState.check(powerRevision)
            guard error is ClientError else { throw error }
            let primaryError = String(describing: error)
            guard let secondary = settings?.fallback else {
                if let root { try ModelHealth.record(root: root, error: primaryError, usedFallback: false) }
                throw error
            }
            let config = ModelSettings(baseURL: secondary.baseURL, model: secondary.model,
                requiresAPIKey: secondary.requiresAPIKey != false, reasoningEffort: secondary.reasoningEffort,
                pricing: secondary.pricing, requestStyle: secondary.requestStyle, timeoutSeconds: secondary.timeoutSeconds, allowInsecureHTTP: secondary.allowInsecureHTTP == true, outputTokenBudget: secondary.outputTokenBudget, fullInput: secondary.fullInput == true)
            do {
                let key: String
                if secondary.requiresAPIKey == false { key = "" }
                else if let root { key = try ModelAPIKey.load(root: root, fallback: true, groupID: secondary.credentialGroupID) ?? fallbackAPIKey }
                else { key = fallbackAPIKey }
                var fallback = DeepSeekClient(apiKey: key, baseURL: secondary.baseURL, model: secondary.model,
                    timeout: secondary.timeoutSeconds ?? ModelSettings.defaultTimeoutSeconds, settings: config)
                fallback.powerState = powerState
                let response = try fallback.completeWithLengthRetry(id: UUID().uuidString, fallbackOf: id,
                    system: system, user: user, maxTokens: maxTokens, temperature: temperature, requiresJSONObject: requiresJSONObject,
                    recordingAt: root, task: task, sources: sources)
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.finishReason != "length" else {
                    throw ClientError.malformedResponse("降级模型返回空内容或输出截断")
                }
                if let root { try ModelHealth.record(root: root, error: nil, usedFallback: true) }
                return response
            } catch {
                if case ClientError.sleepDeferred = error { throw error }
                try powerState.check(powerRevision)
                let message = "主模型：\(primaryError)；降级模型：\(error)"
                if let root { try ModelHealth.record(root: root, error: message, usedFallback: true) }
                throw ClientError.transport(message)
            }
        }
    }

    private func completeWithLengthRetry(id: String, fallbackOf: String? = nil, system: String, user: String,
                                        maxTokens: Int, temperature: Double, reasoningEffort: String = "", requiresJSONObject: Bool = false,
                                        recordingAt root: URL?, task: String, sources: [String]) throws -> Completion {
        let budget = settings?.outputTokenBudget ?? maxTokens
        let response = try completeAttempt(id: id, fallbackOf: fallbackOf, outputTokenBudget: budget,
            system: system, user: user, maxTokens: maxTokens, temperature: temperature,
            reasoningEffort: reasoningEffort, requiresJSONObject: requiresJSONObject, recordingAt: root, task: task, sources: sources)
        guard response.finishReason == "length" else { return response }
        let (larger, overflow) = budget.multipliedReportingOverflow(by: 2)
        guard !overflow else { return response }
        return try completeAttempt(id: UUID().uuidString, fallbackOf: fallbackOf, retryOf: id,
            outputTokenBudget: larger, system: system, user: user, maxTokens: maxTokens,
            temperature: temperature, reasoningEffort: reasoningEffort, requiresJSONObject: requiresJSONObject, recordingAt: root, task: task, sources: sources)
    }

    private func completeAttempt(id: String, fallbackOf: String? = nil, retryOf: String? = nil, outputTokenBudget: Int? = nil, system: String, user: String,
                         maxTokens: Int = ModelSettings.defaultOutputTokenBudget,
                         temperature: Double = 0.3,
                         reasoningEffort: String = "", requiresJSONObject: Bool = false,
                         recordingAt root: URL? = nil, task: String = "summary",
                         sources: [String] = []) throws -> Completion {
        guard let powerRevision = powerState.snapshot() else { throw ClientError.sleepDeferred }
        try powerState.check(powerRevision)
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
        try ModelTransport.validate(baseURL, allowInsecureHTTP: settings?.allowInsecureHTTP == true)
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
            payload["max_completion_tokens"] = outputTokenBudget ?? maxTokens
        } else {
            payload["max_tokens"] = outputTokenBudget ?? maxTokens
            payload["temperature"] = temperature
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var record = ModelRequest(id: id, startedAt: started,
            model: model, endpoint: baseURL.absoluteString, task: task, sources: sources,
            status: "running", system: system, input: user, pricing: pricing, fallbackOf: fallbackOf)
        record.retryOf = retryOf
        record.outputTokenBudget = payload["max_tokens"] as? Int ?? payload["max_completion_tokens"] as? Int
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

        let networkSession = URLSession(configuration: .ephemeral, delegate: ModelTransport(), delegateQueue: nil)
        defer { networkSession.finishTasksAndInvalidate() }
        let networkTask = networkSession.dataTask(with: request) { data, response, error in
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
        if (try? powerState.check(powerRevision)) != nil { networkTask.resume() }
        let deadline = DispatchTime.now() + timeout
        var completionResult: Result<Completion, Error>
        while true {
            do { try powerState.check(powerRevision) }
            catch {
                networkTask.cancel()
                completionResult = .failure(error)
                break
            }
            if semaphore.wait(timeout: min(deadline, .now() + .milliseconds(200))) == .success {
                do { try powerState.check(powerRevision); completionResult = result.load() }
                catch { completionResult = .failure(error) }
                break
            }
            if DispatchTime.now() >= deadline {
                networkTask.cancel()
                completionResult = .failure(ClientError.transport("模型请求超过 \(Int(timeout)) 秒总耗时上限"))
                break
            }
        }

        record.finishedAt = Date()
        record.durationSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
        switch completionResult {
        case .success(let completion):
            record.output = completion.text
            record.usage = completion.usage
            record.finishReason = completion.finishReason
            record.status = completion.finishReason == "length" ? "truncated" : (completion.text.isEmpty ? "empty" : "success")
            record.estimatedCost = completion.usage.flatMap { usage in pricing.map { $0.estimate(usage) } }
            if requiresJSONObject, completion.finishReason != "length",
               (try? JSONSerialization.jsonObject(with: Data(completion.text.utf8))) as? [String: Any] == nil {
                let error = ClientError.malformedResponse("模型输出不是完整 JSON 对象")
                record.status = "invalid"; record.error = String(describing: error)
                if let root { try record.save(root: root) }
                throw error
            }
            if let root { try record.save(root: root) }
            return completion
        case .failure(let error):
            if case ClientError.sleepDeferred = error { record.status = "deferred" }
            else { record.status = "failed" }
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
                reasoningTokens: (details?["reasoning_tokens"] as? Int) ?? (u["reasoning_tokens"] as? Int) ?? 0,
                cachedPromptTokens: (u["prompt_cache_hit_tokens"] as? Int) ?? (promptDetails?["cached_tokens"] as? Int))
        }
        return .success(Completion(text: text, usage: usage,
                                   finishReason: first["finish_reason"] as? String))
    }
}
