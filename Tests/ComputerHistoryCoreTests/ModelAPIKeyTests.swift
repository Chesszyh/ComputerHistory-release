import Security
import XCTest
@testable import ComputerHistoryCore

final class ModelAPIKeyTests: XCTestCase {
    func testBackgroundDisablesLoginKeychainInteraction() throws {
        var original: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        defer { _ = SecKeychainSetUserInteractionAllowed(original.boolValue) }
        try ModelAPIKey.configureInteraction(allow: false)
        var allowed: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertFalse(allowed.boolValue)
        try ModelAPIKey.configureInteraction(allow: true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertTrue(allowed.boolValue)
    }

    func testInteractionErrorNamesExplicitAuthorization() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            let error = ModelAPIKey.KeyError(status: status)
            XCTAssertTrue(error.description.contains("model-key --authorize"))
            XCTAssertTrue(error.description.contains("后台任务不会弹出"))
        }
    }
}
