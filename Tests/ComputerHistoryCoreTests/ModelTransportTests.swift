import XCTest
@testable import ComputerHistoryCore

final class ModelTransportTests: XCTestCase {
    func testLocalHTTPAndRemoteHTTPS() throws {
        for address in ["http://localhost:11434/v1", "http://127.0.0.1:8000", "http://[::1]:8000", "https://model.example/v1"] {
            try ModelTransport.validate(URL(string: address)!)
        }
        for address in ["http://192.168.1.20/v1", "http://model.example", "http://localhost.example", "https://user:password@model.example", "file:///tmp/model"] {
            XCTAssertThrowsError(try ModelTransport.validate(URL(string: address)!))
        }
        try ModelTransport.validate(URL(string: "http://192.168.1.20")!, allowInsecureHTTP: true)
    }

    func testLegacyConfigurationAndGroupDraftPreserveConsent() throws {
        let old = Data(#"{"baseURL":"http://model.example","model":"synthetic","requiresAPIKey":false}"#.utf8)
        var settings = try JSONDecoder().decode(ModelSettings.self, from: old)
        XCTAssertThrowsError(try settings.validate())
        settings.allowInsecureHTTP = true
        var draft = ModelSettingsDraft(settings, environment: [:])
        try draft.value().validate()
        let group = ModelGroup(name: "Synthetic", settings: try draft.value())
        let decoded = try JSONDecoder().decode(ModelGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(decoded.settings.allowInsecureHTTP, true)
        draft.allowInsecureHTTP = false
        XCTAssertThrowsError(try draft.value())
    }

    func testFallbackAndInactiveGroupsAlsoValidateTransport() throws {
        var settings = ModelSettings(baseURL: URL(string: "https://model.example")!, model: "synthetic",
            fallback: FallbackModelSettings(baseURL: URL(string: "http://192.168.1.20")!, model: "fallback"))
        XCTAssertThrowsError(try settings.validate())
        settings.fallback?.allowInsecureHTTP = true
        try settings.validate()
        let draft = ModelSettingsDraft(settings, environment: [:])
        XCTAssertEqual(try draft.value().fallback?.allowInsecureHTTP, true)
        let groups = ModelGroups(groups: [ModelGroup(id: "primary", name: "Primary", settings: settings),
            ModelGroup(id: "unused", name: "Unused", settings: ModelSettings(baseURL: URL(string: "http://model.example")!, model: "unused"))], primaryGroupID: "primary")
        XCTAssertThrowsError(try groups.resolved())
    }

    func testEnvironmentAndDirectClientRejectBeforeRequest() throws {
        XCTAssertThrowsError(try DeepSeekClient.fromEnvironment([
            "DEEPSEEK_API_KEY": "synthetic", "DEEPSEEK_BASE_URL": "http://model.example"]))
        let client = DeepSeekClient(apiKey: "synthetic", baseURL: URL(string: "http://model.example")!)
        XCTAssertThrowsError(try client.complete(system: "synthetic", user: "synthetic"))
    }

    func testCatalogRejectsBeforeRequest() async {
        do {
            _ = try await ModelCatalog.fetch(baseURL: URL(string: "http://model.example")!, apiKey: "synthetic")
            XCTFail("Remote HTTP catalog must be rejected")
        } catch { XCTAssertTrue(String(describing: error).contains("HTTPS")) }
    }
}
