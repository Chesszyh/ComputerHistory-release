import Foundation

public struct ModelCatalog: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Identifiable {
        public struct Effort: Decodable, Sendable {
            public var supported_levels: [String]
            public var default_level: String?
        }
        public var id: String
        public var name: String?
        public var effort: Effort?
    }
    public var data: [Entry]

    public static func fetch(baseURL: URL, apiKey: String, session: URLSession = .shared) async throws -> Self {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ConfigurationInputError.invalid("模型列表读取失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），可手动填写。")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
