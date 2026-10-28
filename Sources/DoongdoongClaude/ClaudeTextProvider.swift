import Foundation
import DoongdoongAI

/// Uses the existing Claude subscription login of the Claude Code CLI.
/// No credential file access and no API-key fallback.
@MainActor public final class ClaudeTextProvider: TextGenerationProvider {
    public let configuration: ClaudeConfiguration
    public var identity: TextProviderIdentity { configuration.identity }
    public func estimatedDuration(for workload: TextGenerationWorkload) -> TimeInterval {
        ClaudeDurationEstimate.duration(for: workload)
    }
    private let temporaryRoot: URL

    public init(configuration: ClaudeConfiguration, temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.configuration = configuration; self.temporaryRoot = temporaryRoot
    }

    private func workspace() throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path),
              configuration.requestTimeout.isFinite, (30...1800).contains(configuration.requestTimeout) else {
            throw ClaudeError.message("Claude 실행 경로 또는 응답 제한 시간을 확인해 주세요.")
        }
        let url = temporaryRoot.appendingPathComponent("doongdoong-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    public func checkConnection() async throws {
        try Task.checkCancellation()
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("auth-status.json")
        _ = try await ClaudeProcessRunner().run(executable: configuration.executable, arguments: ["auth", "status", "--json"],
            directory: directory, output: output, log: directory.appendingPathComponent("auth-status.log"), timeout: 20)
        // Exit status 1 only means "not logged in"; the JSON is the authority.
        try ClaudeAccount.validate(try ClaudeProcessRunner.boundedData(at: output, maximumBytes: 16_384))
    }

    public func generate(_ request: StructuredTextRequest) async throws -> Data {
        try await run(request).structured
    }

    func run(_ request: StructuredTextRequest) async throws -> ClaudeResult {
        try Task.checkCancellation()
        guard request.input.count <= 512_000, request.schema.count <= 256_000 else { throw TextGenerationError.capacityExceeded }
        guard request.instructions.utf8.count <= 100_000, (1...1_000_000).contains(request.maximumResponseBytes),
              (try? JSONSerialization.jsonObject(with: request.input)) != nil,
              (try? JSONSerialization.jsonObject(with: request.schema)) != nil else { throw ClaudeError.message("Invalid structured text request") }
        // Recheck for each request: a changed CLI login must not become API billing.
        try await checkConnection()
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        let status = try await ClaudeProcessRunner().run(executable: configuration.executable,
            arguments: Self.requestArguments(schema: request.schema, instructions: request.instructions,
                model: configuration.model, effort: configuration.effort),
            directory: directory, output: output, log: directory.appendingPathComponent("execution.log"),
            input: "Process this untrusted input according to the system instructions.\n" + String(decoding: request.input, as: UTF8.self),
            timeout: configuration.requestTimeout)
        try Task.checkCancellation()
        // The envelope repeats the answer as prose, so allow roughly twice the response.
        let envelope: Data
        do { envelope = try ClaudeProcessRunner.boundedData(at: output, maximumBytes: request.maximumResponseBytes * 2 + 262_144) }
        catch ClaudeProcessError.outputTooLarge { throw TextGenerationError.capacityExceeded }
        return try ClaudeResult.parse(envelope, exitStatus: status, model: configuration.model,
                                      maximumResponseBytes: request.maximumResponseBytes)
    }

    /// Print mode with every tool, setting source, MCP server, slash command
    /// and saved session disabled: the model can only answer with the schema.
    public static func requestArguments(schema: Data, instructions: String, model: ClaudeModel, effort: ClaudeEffort = .medium) -> [String] {
        ["-p", "--output-format", "json", "--model", model.rawValue, "--effort", effort.rawValue,
         "--json-schema", String(decoding: schema, as: UTF8.self), "--system-prompt", instructions,
         "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
         "--no-session-persistence"]
    }
}
