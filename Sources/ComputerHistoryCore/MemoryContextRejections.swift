import CryptoKit
import Foundation

/// The memory generation lease serializes writers. Pruning a source segment also removes its rejections.
struct MemoryContextRejections: Sendable {
    let file: URL
    let retriesRejectedRequests: Bool

    init(segmentDirectory: URL, retriesRejectedRequests: Bool) {
        file = segmentDirectory.appendingPathComponent("model-context-rejections.json")
        self.retriesRejectedRequests = retriesRejectedRequests
    }

    static func key(endpoint: String, model: String, outputBudget: Int, system: String, input: String) -> String {
        var hash = SHA256()
        for field in [endpoint, model, String(outputBudget), system, input] {
            hash.update(data: Data("\(field.utf8.count):".utf8))
            hash.update(data: Data(field.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func update(key: String, rejectedRequestID: String?) throws {
        var rejections = load()
        guard rejections[key] != rejectedRequestID else { return }
        rejections[key] = rejectedRequestID
        try save(rejections)
    }

    func importLegacyRejections(root: URL, segmentID: String, failedMemory: String?) throws {
        guard !FileManager.default.fileExists(atPath: file.path), let failedMemory,
              let diagnostic = failedMemory.range(of: "\n- 本节未由语言模型归纳："),
              Self.isContextDiagnostic(String(failedMemory[diagnostic.upperBound...].prefix(800))) else { return }
        let ledger = ModelRequest.ledgerDirectory(root: root)
        guard FileManager.default.fileExists(atPath: ledger.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: ledger, includingPropertiesForKeys: nil)
        let source = Data(segmentID.utf8)
        let decoder = EventStreamJSON.makeDecoder(acceptingLegacyNumericDates: true)
        var latest: [String: (started: Date, rejectionID: String?)] = [:]
        for requestFile in files where requestFile.pathExtension == "json" {
            guard let data = try? Data(contentsOf: requestFile, options: .mappedIfSafe),
                  data.range(of: source) != nil,
                  let record = try? decoder.decode(ModelRequest.self, from: data),
                  record.task == "10min", record.sources == [segmentID], let budget = record.outputTokenBudget else { continue }
            let rejected = record.status == "failed" && Self.isLegacyContextError(record.error)
            guard rejected || ["success", "truncated", "empty", "invalid"].contains(record.status) else { continue }
            let key = Self.key(endpoint: record.endpoint, model: record.model, outputBudget: budget,
                              system: record.system, input: record.input)
            guard latest[key].map({ $0.started > record.startedAt }) != true else { continue }
            latest[key] = (record.startedAt, rejected ? record.retryOf ?? record.id : nil)
        }
        try save(latest.compactMapValues(\.rejectionID))
    }

    static func isContextLimit(_ error: Error) -> Bool {
        guard case DeepSeekClient.ClientError.http(let status, let body) = error,
              [400, 413, 422].contains(status) else { return false }
        return isContextDiagnostic(body)
    }

    private static func isLegacyContextError(_ message: String?) -> Bool {
        guard let message, let separator = message.firstIndex(of: "："),
              ["接口返回 HTTP 400", "接口返回 HTTP 413", "接口返回 HTTP 422"].contains(String(message[..<separator])) else { return false }
        return isContextDiagnostic(String(message[message.index(after: separator)...]))
    }

    private static func isContextDiagnostic(_ body: String) -> Bool {
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let error = json?["error"] as? [String: Any] ?? json
        for field in ["code", "type"] {
            if let code = error?[field] as? String,
               ["context_length_exceeded", "context_too_large"].contains(code.lowercased()) { return true }
        }
        let message = (error?["message"] as? String ?? body).lowercased()
        // Historical ledger errors may end mid-JSON because diagnostics were truncated.
        return message.range(of: #"this model's maximum context length is [0-9,]+ tokens"#, options: .regularExpression) != nil
            || message.contains("exceeds the context window of this model")
            || message.range(of: #""(?:code|type)"\s*:\s*"(?:context_length_exceeded|context_too_large)""#, options: .regularExpression) != nil
    }

    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ rejections: [String: String]) throws {
        try JSONEncoder().encode(rejections).write(to: file, options: .atomic)
    }
}
