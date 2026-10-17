import Foundation

/// DeepSeek 对话补全客户端，用于把段摘要写成记忆。
///
/// 只做一件事：发一次非流式请求、取回文本。不重试、不并发——记忆生成是
/// 后台低频任务，出错时交由调用方决定是否跳过该段。
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

        public var description: String {
            switch self {
            case .missingAPIKey:
                return "未找到模型密钥。请在菜单栏的模型设置中填写，或设置 DEEPSEEK_API_KEY 环境变量。"
            case .http(let status, let body):
                return "接口返回 HTTP \(status)：\(body.prefix(300))"
            case .malformedResponse(let detail):
                return "响应格式不符：\(detail)"
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

    public init(apiKey: String,
                baseURL: URL = DeepSeekClient.defaultBaseURL,
                model: String = DeepSeekClient.defaultModel,
                timeout: TimeInterval = 120,
                settings: ModelSettings? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.settings = settings
    }

    /// 从环境变量构造。密钥缺失时抛错，避免静默降级成"生成成功但内容为空"。
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        rootDirectory: URL? = nil
    ) throws -> DeepSeekClient {
        if let rootDirectory, let config = try ModelSettings.load(root: rootDirectory) {
            let key = config.requiresAPIKey
                ? (try ModelAPIKey.load(root: rootDirectory) ?? environment["DEEPSEEK_API_KEY"] ?? "") : ""
            if config.requiresAPIKey, key.isEmpty { throw ClientError.missingAPIKey }
            return DeepSeekClient(apiKey: config.requiresAPIKey ? key : "", baseURL: config.baseURL,
                                  model: config.model, timeout: 180, settings: config)
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

    /// 发一次补全请求。
    ///
    /// 总结默认关闭思考；服务端用量与实际请求正文一起保存。
    public func complete(system: String, user: String,
                         maxTokens: Int = 8000,
                         temperature: Double = 0.3,
                         reasoningEffort: String = "none",
                         recordingAt root: URL? = nil, task: String = "summary",
                         sources: [String] = [], comparisonOf: String? = nil) throws -> Completion {
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
                throw ClientError.transport("已达到今日总结预算（\(pricing.currency) \(cap)）")
            }
            if let cap = settings.monthlyBudget, month >= cap {
                throw ClientError.transport("已达到本月总结预算（\(pricing.currency) \(cap)）")
            }
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "reasoning_effort": settings?.reasoningEffort ?? reasoningEffort,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var record = ModelRequest(id: UUID().uuidString, startedAt: started,
            model: model, endpoint: baseURL.absoluteString, task: task, sources: sources,
            status: "running", system: system, input: user, pricing: pricing, comparisonOf: comparisonOf)
        record.worker = CollectorProcessIdentity.read(pid: getpid())
        // 请求前落盘失败就不外发，避免产生无法查询的付费请求。
        if let root { try record.save(root: root) }

        if let root, let secondary = settings?.comparison {
            let parentID = record.id
            let config = ModelSettings(baseURL: secondary.baseURL, model: secondary.model,
                requiresAPIKey: false, reasoningEffort: secondary.reasoningEffort, pricing: secondary.pricing)
            let client = DeepSeekClient(apiKey: "", baseURL: secondary.baseURL,
                model: secondary.model, timeout: 180, settings: config)
            ModelComparison.pending.enter()
            ModelComparison.queue.async {
                defer { ModelComparison.pending.leave() }
                do {
                    _ = try client.complete(system: system, user: user, maxTokens: maxTokens,
                        temperature: temperature, recordingAt: root, task: task,
                        sources: sources, comparisonOf: parentID)
                } catch {
                    FileHandle.standardError.write("对照模型请求失败：\(error)\n".data(using: .utf8)!)
                }
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ResponseState()

        URLSession.shared.dataTask(with: request) { data, response, error in
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
        }.resume()
        semaphore.wait()

        record.finishedAt = Date()
        record.durationSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
        switch result.load() {
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
