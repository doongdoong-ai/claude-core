import XCTest
import DoongdoongAI
@testable import DoongdoongClaude

/// Uses the real CLI and subscription quota. Run with CLAUDE_CORE_LIVE=/path/to/claude.
final class LiveTests: XCTestCase {
    @MainActor func testRealConnectionAndStructuredGeneration() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_CORE_LIVE"] else { throw XCTSkip("Set CLAUDE_CORE_LIVE") }
        let executable = URL(fileURLWithPath: path)
        let connection = ClaudeConnection(executable: executable)
        let identity = try await connection.verifyConnection()
        XCTAssertEqual(identity.provider, "claude")
        XCTAssertNotNil(connection.resolvedModelName)
        let schema = #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"],"additionalProperties":false}"#
        let data = try await ClaudeTextProvider(configuration: .init(executable: executable)).generate(.init(
            instructions: "Write a short Korean title for the supplied lecture text.",
            input: Data(#"{"text":"오늘은 미분의 정의와 도함수의 기하학적 의미를 다룹니다."}"#.utf8), schema: Data(schema.utf8)))
        let title = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: String])?["title"])
        XCTAssertFalse(title.isEmpty)
        print("live:", connection.resolvedModelName ?? "-", title)
    }
}
