import Foundation

/// DeepSeek 对话补全客户端，用于把段摘要写成记忆。
///
/// 只做一件事：发一次非流式请求、取回文本。不重试、不并发——记忆生成是
/// 后台低频任务，出错时交由调用方决定是否跳过该段。
public struct DeepSeekClient: Sendable {

    public struct Usage: Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int
        /// 其中用于推理的 token。推理与正文共享 `max_tokens` 预算，
        /// 预算被推理吃光时正文为空且 `finishReason` 为 `length`。
        public var reasoningTokens: Int
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
                return "未找到 DEEPSEEK_API_KEY。请先 export 该环境变量。"
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

    public init(apiKey: String,
                baseURL: URL = DeepSeekClient.defaultBaseURL,
                model: String = DeepSeekClient.defaultModel,
                timeout: TimeInterval = 120) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    /// 从环境变量构造。密钥缺失时抛错，避免静默降级成"生成成功但内容为空"。
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DeepSeekClient {
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
    /// `reasoningEffort` 取 `low` 以减少推理开销：记忆生成只需归纳事实，
    /// 不需要长链推理。`temperature` 设低以求稳定——同一段重跑应得到相近结果。
    public func complete(system: String, user: String,
                         maxTokens: Int = 8000,
                         temperature: Double = 0.3,
                         reasoningEffort: String = "low") throws -> Completion {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "reasoning_effort": reasoningEffort,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

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

        switch result.load() {
        case .success(let completion): return completion
        case .failure(let error): throw error
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
        if let u = root["usage"] as? [String: Any] {
            let details = u["completion_tokens_details"] as? [String: Any]
            usage = Usage(
                promptTokens: (u["prompt_tokens"] as? Int) ?? 0,
                completionTokens: (u["completion_tokens"] as? Int) ?? 0,
                totalTokens: (u["total_tokens"] as? Int) ?? 0,
                reasoningTokens: (details?["reasoning_tokens"] as? Int) ?? 0)
        }
        return .success(Completion(text: text, usage: usage,
                                   finishReason: first["finish_reason"] as? String))
    }
}
