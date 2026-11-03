import XCTest
@testable import ComputerHistoryCore

final class ModelGroupsTests: XCTestCase {
    func testTaskRoutesPreserveIndependentSettingsAndRejectInvalidAssignments() throws {
        let url = URL(string: "http://127.0.0.1:1234/v1")!
        let primary = ModelGroup(id: "primary", name: "Primary", settings: .init(baseURL: url, model: "primary", requiresAPIKey: false, reasoningEffort: "medium"))
        let writer = ModelGroup(id: "writer", name: "Writer", settings: .init(baseURL: url, model: "writer", requiresAPIKey: false))
        var groups = ModelGroups(groups: [primary, writer], primaryGroupID: "primary", fallbackGroupID: "writer",
            tasks: ["narrative": .init(groupID: "writer", reasoningEffort: "none", outputTokenBudget: 2048)])
        XCTAssertEqual(try groups.resolved().model, "primary")
        let routed = try groups.resolved(for: "narrative")
        XCTAssertEqual(routed.model, "writer")
        XCTAssertEqual(routed.credentialGroupID, "writer")
        XCTAssertEqual(routed.reasoningEffort, "none")
        XCTAssertEqual(routed.outputTokenBudget, 2048)
        XCTAssertNil(routed.fallback)
        let root = try root()
        try groups.save(root: root)
        XCTAssertEqual(try ModelGroups.load(root: root).tasks, groups.tasks)
        groups.tasks?["narrative"]?.groupID = "missing"
        XCTAssertThrowsError(try groups.resolved())
        groups.tasks = ["unknown": .init()]
        XCTAssertThrowsError(try groups.resolved())
        groups.tasks = ["daily": .init(outputTokenBudget: 0)]
        XCTAssertThrowsError(try groups.resolved())
    }

    func testTopLevelReasoningUsageIsRecorded() throws {
        let data = Data(#"{"choices":[{"message":{"content":"Synthetic"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":25,"reasoning_tokens":20,"prompt_tokens_details":{"cached_tokens":64}}}"#.utf8)
        let completion = try DeepSeekClient.parse(data).get()
        XCTAssertEqual(completion.usage?.reasoningTokens, 20)
        XCTAssertEqual(completion.usage?.cachedPromptTokens, 64)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testLegacyMigrationKeepsCredentialsAndIndependentEndpointOptions() throws {
        let root = try root()
        let old = ModelSettings(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, model: "primary",
            requiresAPIKey: false, reasoningEffort: "high", pricing: .init(inputPerMillion: 1, cachedInputPerMillion: 0, outputPerMillion: 2),
            dailyBudget: 5, fallback: .init(baseURL: URL(string: "http://127.0.0.1:1235/v1")!, model: "secondary",
                requiresAPIKey: true, requestStyle: .reasoning, timeoutSeconds: 12), requestStyle: .standard, timeoutSeconds: 30)
        try old.save(root: root)
        let bytes = try Data(contentsOf: root.appendingPathComponent("model.json"))
        var groups = try ModelGroups.load(root: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("model.json")), bytes, "Reading must not migrate files")
        XCTAssertEqual(groups.groups.count, 2)
        try groups.save(root: root)
        let saved = try XCTUnwrap(ModelSettings.load(root: root))
        XCTAssertEqual(saved.credentialGroupID, "legacy-primary")
        XCTAssertEqual(saved.fallback?.credentialGroupID, "legacy-fallback")
        XCTAssertEqual(saved.dailyBudget, 5)
        XCTAssertEqual(saved.timeoutSeconds, 30)
        XCTAssertEqual(saved.fallback?.timeoutSeconds, 12)
        XCTAssertEqual(saved.fallback?.requestStyle, .reasoning)
        groups.primaryGroupID = "legacy-fallback"
        groups.fallbackGroupID = "legacy-primary"
        groups.dailyBudget = nil
        try groups.save(root: root)
        let swapped = try XCTUnwrap(ModelSettings.load(root: root))
        XCTAssertEqual(swapped.model, "secondary")
        XCTAssertEqual(swapped.requestStyle, .reasoning)
        XCTAssertTrue(swapped.requiresAPIKey)
        XCTAssertEqual(swapped.credentialGroupID, "legacy-fallback")
        XCTAssertEqual(swapped.fallback?.model, "primary")
        XCTAssertEqual(swapped.fallback?.credentialGroupID, "legacy-primary")
        XCTAssertEqual(try ModelGroups.load(root: root).groups.map(\.model), ["primary", "secondary"])
    }

    func testInvalidSelectionsAndInactiveGroupPreventOverwrite() throws {
        let root = try root()
        let group = ModelGroup(id: "one", name: "One", settings: .init(baseURL: URL(string: "http://localhost/v1")!, model: "one", requiresAPIKey: false))
        var groups = ModelGroups(groups: [group], primaryGroupID: group.id)
        try groups.save(root: root)
        let url = root.appendingPathComponent("model.json")
        let before = try Data(contentsOf: url)
        groups.fallbackGroupID = group.id
        XCTAssertThrowsError(try groups.save(root: root))
        groups.fallbackGroupID = "missing"
        XCTAssertThrowsError(try groups.save(root: root))
        groups.fallbackGroupID = nil
        groups.groups.append(group)
        XCTAssertThrowsError(try groups.save(root: root))
        groups.groups[1].id = "two"
        groups.groups[1].model = ""
        XCTAssertThrowsError(try groups.save(root: root))
        XCTAssertEqual(try Data(contentsOf: url), before)
        try Data(#"{"groups":[],"primaryGroupID":"missing"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try ModelSettings.load(root: root))
        XCTAssertThrowsError(try ModelGroups.load(root: root))
    }
}
