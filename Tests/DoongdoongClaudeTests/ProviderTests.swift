import XCTest
import DoongdoongAI
@testable import DoongdoongClaude

final class ProviderTests: XCTestCase {
    private static let success = #"{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"{\"ok\":true}","structured_output":{"ok":true},"modelUsage":{"claude-sonnet-5-5":{"outputTokens":5}}}"#

    private func fixture(status: String = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#,
                         output: String = ProviderTests.success, exit: Int = 0, delay: Bool = false) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-claude")
        let statusJSON = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        let outputJSON = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        let code = """
        #!/usr/bin/python3
        import sys,os,json,time
        if sys.argv[1:] == ['auth','status','--json']:
            print(\(statusJSON)); sys.exit(0 if json.loads(\(statusJSON))['loggedIn'] else 1)
        for key in ['ANTHROPIC_API_KEY','ANTHROPIC_BASE_URL','CLAUDE_CODE_USE_BEDROCK','CLAUDECODE']:
            assert not os.environ.get(key), key
        args=sys.argv[1:]
        assert args[0] == '-p'
        assert args[args.index('--model')+1] == 'sonnet'
        assert args[args.index('--effort')+1] == 'high'
        assert args[args.index('--tools')+1] == ''
        assert args[args.index('--setting-sources')+1] == ''
        assert '--no-session-persistence' in args and '--strict-mcp-config' in args
        json.loads(args[args.index('--json-schema')+1])
        assert args[args.index('--system-prompt')+1] == 'Review only.'
        assert 'original input' in sys.stdin.read()
        \(delay ? "time.sleep(60)" : "pass")
        print(\(outputJSON)); sys.exit(\(exit))
        """
        try Data(code.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (root, script)
    }

    @MainActor private func provider(_ script: URL, root: URL) -> ClaudeTextProvider {
        ClaudeTextProvider(configuration: .init(executable: script, effort: .high, requestTimeout: 30), temporaryRoot: root)
    }
    private let request = StructuredTextRequest(instructions: "Review only.", input: Data(#"{"text":"original input"}"#.utf8),
                                                schema: Data(#"{"type":"object"}"#.utf8))

    @MainActor func testGeneratesStructuredOutputWithIsolatedArgumentsAndEnvironment() async throws {
        setenv("ANTHROPIC_API_KEY", "must-not-leak", 1); defer { unsetenv("ANTHROPIC_API_KEY") }
        let (root, script) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try await provider(script, root: root).run(request)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: result.structured) as? [String: Bool], ["ok": true])
        XCTAssertEqual(result.resolvedModel, "claude-sonnet-5-5")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("doongdoong-claude-") }
        XCTAssertEqual(leftovers, [], "Temporary workspaces must be removed")
    }

    @MainActor func testOnlySubscriptionLoginIsAccepted() async throws {
        let cases: [(String, ProviderConnectionIssue.Kind)] = [
            (#"{"loggedIn":false,"authMethod":"none"}"#, .loginRequired),
            (#"{"loggedIn":true,"authMethod":"console","apiProvider":"firstParty"}"#, .unsupportedAuthentication),
            (#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#, .unsupportedAuthentication),
            ("not json", .invalidResponse)
        ]
        for (status, kind) in cases {
            let (root, script) = try fixture(status: status); defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await provider(script, root: root).generate(request); XCTFail("\(status) must not generate") }
            catch let issue as ProviderConnectionIssue { XCTAssertEqual(issue.kind, kind, status) }
        }
    }

    @MainActor func testStructuredFailuresAreClassifiedByStatus() async throws {
        func envelope(_ status: Int?, _ result: String = "error") -> String {
            #"{"type":"result","subtype":"success","is_error":true,"api_error_status":\#(status.map(String.init) ?? "null"),"result":"\#(result)"}"#
        }
        let cases: [(String, ProviderConnectionIssue.Kind)] = [
            (envelope(401), .loginRequired), (envelope(404), .configuration), (envelope(429), .usageLimited),
            (envelope(529), .serviceUnavailable), (envelope(500), .serviceUnavailable), (envelope(400), .invalidResponse),
            (envelope(nil, "Not logged in"), .unknown),
            (#"{"type":"result","subtype":"error_max_turns","is_error":true}"#, .invalidResponse),
            (#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#, .invalidResponse)
        ]
        for (output, kind) in cases {
            let (root, script) = try fixture(output: output, exit: output.contains(#""is_error":false"#) ? 0 : 1); defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await provider(script, root: root).generate(request); XCTFail("\(output) must fail") }
            catch let issue as ProviderConnectionIssue { XCTAssertEqual(issue.kind, kind, output) }
        }
    }

    @MainActor func testContextLimitRequestsSmallerInput() async throws {
        for output in [#"{"type":"result","is_error":true,"api_error_status":400,"result":"Prompt is too long"}"#,
                       #"{"type":"result","is_error":true,"api_error_status":413,"result":"x"}"#] {
            let (root, script) = try fixture(output: output, exit: 1); defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await provider(script, root: root).generate(request); XCTFail() }
            catch { XCTAssertEqual(error as? TextGenerationError, .capacityExceeded) }
        }
        let tooLarge = StructuredTextRequest(instructions: "Review only.", input: Data(#"{"text":"original input"}"#.utf8),
                                             schema: Data(#"{"type":"object"}"#.utf8), maximumResponseBytes: 4)
        let (root, script) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await provider(script, root: root).generate(tooLarge); XCTFail() }
        catch { XCTAssertEqual(error as? TextGenerationError, .capacityExceeded) }
    }

    @MainActor func testCancellationStopsTheProcess() async throws {
        let (root, script) = try fixture(delay: true); defer { try? FileManager.default.removeItem(at: root) }
        let provider = provider(script, root: root)
        let task = Task { try await provider.generate(request) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    @MainActor func testConnectionProbeReportsResolvedModel() async throws {
        let configuration = ClaudeConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"), effort: .high, requestTimeout: 30)
        var probes = 0
        let connection = ClaudeConnection(configuration: configuration, checkAccount: { _ in }, generate: { _, request in
            probes += 1
            XCTAssertEqual(request.maximumResponseBytes, 128)
            return ClaudeResult(structured: Data(#"{"ok":true}"#.utf8), resolvedModel: "claude-sonnet-5-5")
        })
        let identity = try await connection.verifyConnection()
        XCTAssertEqual(identity, .init(provider: "claude", model: "sonnet", reasoningEffort: "high"))
        XCTAssertEqual(connection.resolvedModelName, "Sonnet 5.5")
        XCTAssertEqual(probes, 1)

        let rejected = ClaudeConnection(configuration: configuration, checkAccount: { _ in
            throw ProviderConnectionIssue(.loginRequired, stage: .probe, retry: .afterUserAction)
        }, generate: { _, _ in XCTFail("No probe without login"); throw CancellationError() })
        do { _ = try await rejected.verifyConnection(); XCTFail() }
        catch let issue as ProviderConnectionIssue { XCTAssertEqual(issue.kind, .loginRequired); XCTAssertEqual(issue.stage, .account) }

        let missing = ClaudeConnection(executable: URL(fileURLWithPath: "/missing/claude"))
        do { _ = try await missing.verifyConnection(); XCTFail() }
        catch let issue as ProviderConnectionIssue { XCTAssertEqual(issue.kind, .installationRequired) }
    }

    func testModelNamesAndDurationEstimates() {
        XCTAssertEqual(ClaudeModel.displayName(resolved: "claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(ClaudeModel.displayName(resolved: "claude-opus-4-1-20250805"), "Opus 4.1")
        XCTAssertEqual(ClaudeModel.displayName(resolved: "custom"), "custom")
        XCTAssertNil(ClaudeModel(rawValue: "sonnet; rm"))
        for task in TextGenerationWorkload.Task.allCases {
            for count in [-1, 0, 1, 13_801, Int.max] {
                let seconds = ClaudeDurationEstimate.duration(for: .init(task: task, characterCount: count))
                XCTAssertTrue(seconds.isFinite && seconds > 0 && seconds <= 3600)
            }
        }
    }
}
