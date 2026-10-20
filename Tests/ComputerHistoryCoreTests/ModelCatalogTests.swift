import XCTest
@testable import ComputerHistoryCore

private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.host == "failure.invalid" ? 404 : 200
        let body: String
        if url.host == "basic.invalid" {
            body = #"{"data":[{"id":"plain-model","object":"model"}]}"#
        } else {
            body = #"{"data":[{"id":"provider-model","name":"Provider name","effort":{"supported_levels":["low","high","max"],"default_level":"high"}}]}"#
        }
        guard request.httpMethod == "GET", url.path == "/v1/models", request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModelCatalogTests: XCTestCase {
    func testFetchesProviderModelAndEffortMetadataWithoutGeneration() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let result = try await ModelCatalog.fetch(baseURL: URL(string: "https://provider.invalid/v1")!, apiKey: "synthetic", session: session)
        XCTAssertEqual(result.data.first?.id, "provider-model")
        XCTAssertEqual(result.data.first?.effort?.supported_levels, ["low", "high", "max"])
        XCTAssertEqual(result.data.first?.effort?.default_level, "high")
        let plain = try await ModelCatalog.fetch(baseURL: URL(string: "https://basic.invalid/v1")!, apiKey: "synthetic", session: session)
        XCTAssertNil(plain.data.first?.effort)
        do {
            _ = try await ModelCatalog.fetch(baseURL: URL(string: "https://failure.invalid/v1")!, apiKey: "synthetic", session: session)
            XCTFail("HTTP failures must not be mistaken for an empty supported-model list")
        } catch { XCTAssertTrue(String(describing: error).contains("404")) }
    }

    func testBlankEffortUsesServiceDefaultAndCustomValuesRemainIntact() throws {
        var draft = ModelSettingsDraft(environment: [:])
        XCTAssertNil(try draft.value().reasoningEffort)
        draft.reasoningEffort = "  vendor-specific-level  "
        XCTAssertEqual(try draft.value().reasoningEffort, "vendor-specific-level")
        draft.reasoningEffort = "  "
        XCTAssertNil(try draft.value().reasoningEffort)
        let decoded = try JSONDecoder().decode(ModelGroup.self, from: Data(#"{"id":"one","name":"One","baseURL":"https://example.invalid/v1","model":"synthetic","requiresAPIKey":false}"#.utf8))
        XCTAssertNil(decoded.reasoningEffort)
    }
}
