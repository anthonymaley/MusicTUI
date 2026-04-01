import XCTest
@testable import music

final class AppleScriptBackendTests: XCTestCase {
    func testRunReturnsStringResult() async throws {
        let backend = AppleScriptBackend()
        let result = try await backend.run("return 2 + 2")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "4")
    }

    func testRunThrowsOnInvalidScript() async {
        let backend = AppleScriptBackend()
        do {
            _ = try await backend.run("this is not valid applescript !@#$")
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }

    func testRunMusicCommandReturnsResult() async throws {
        let backend = AppleScriptBackend()
        let result = try await backend.runMusic("get name of application \"Music\"")
        XCTAssertFalse(result.isEmpty)
    }
}
