import Foundation
import DoongdoongAI

/// Login check and a synthetic probe are one cancellable operation.
/// The caller owns UI and first-run persistence; Claude owns failure semantics.
@MainActor public final class ClaudeConnection: ProviderConnectionChecking {
    public static let installationCommand = "brew install --cask claude-code"
    /// Canonical model the alias resolved to during the last successful probe.
    public private(set) var resolvedModel: String?
    private let configuration: ClaudeConfiguration
    private let checkAccount: @MainActor (ClaudeConfiguration) async throws -> Void
    private let generate: @MainActor (ClaudeConfiguration, StructuredTextRequest) async throws -> ClaudeResult

    public convenience init(executable: URL, model: ClaudeModel = .sonnet, effort: ClaudeEffort = .medium, timeout: TimeInterval = 90) {
        self.init(configuration: .init(executable: executable, model: model, effort: effort, requestTimeout: timeout),
                  checkAccount: { try await ClaudeTextProvider(configuration: $0).checkConnection() },
                  generate: { try await ClaudeTextProvider(configuration: $0).run($1) })
    }

    init(configuration: ClaudeConfiguration,
         checkAccount: @escaping @MainActor (ClaudeConfiguration) async throws -> Void,
         generate: @escaping @MainActor (ClaudeConfiguration, StructuredTextRequest) async throws -> ClaudeResult) {
        self.configuration = configuration; self.checkAccount = checkAccount; self.generate = generate
    }

    /// Display name of the resolved model, e.g. "Sonnet 5.5".
    public var resolvedModelName: String? { resolvedModel.map(ClaudeModel.displayName(resolved:)) }

    public func verifyConnection() async throws -> TextProviderIdentity {
        try Task.checkCancellation()
        resolvedModel = nil
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else {
            throw ProviderConnectionIssue(.installationRequired, stage: .installation, retry: .afterUserAction)
        }
        var stage: ProviderConnectionIssue.Stage = .account
        do {
            return try await claudeDeadline(configuration.requestTimeout) { [self] in
                try await checkAccount(configuration)
                try Task.checkCancellation()
                stage = .probe
                let result = try await generate(configuration, Self.probe)
                try Task.checkCancellation()
                guard let object = try? JSONSerialization.jsonObject(with: result.structured) as? [String: Any],
                      object.count == 1, let ok = object["ok"] as? NSNumber,
                      CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue else {
                    throw ProviderConnectionIssue(.invalidResponse, stage: .probe, retry: .manual)
                }
                resolvedModel = result.resolvedModel
                return configuration.identity
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Self.classify(error, stage: stage)
        }
    }

    static let probe = StructuredTextRequest(instructions: "Return exactly {\"ok\":true}. This is a connection check.",
        input: Data("{}".utf8),
        schema: Data(#"{"type":"object","properties":{"ok":{"type":"boolean","const":true}},"required":["ok"],"additionalProperties":false}"#.utf8),
        maximumResponseBytes: 128)

    static func classify(_ error: Error, stage: ProviderConnectionIssue.Stage) -> ProviderConnectionIssue {
        if let issue = error as? ProviderConnectionIssue {
            return .init(issue.kind, stage: stage, retry: issue.retry, retryAfter: issue.retryAfter)
        }
        if case ClaudeProcessError.timedOut = error { return .init(.timedOut, stage: stage, retry: .manual) }
        if case ClaudeProcessError.outputTooLarge = error { return .init(.invalidResponse, stage: stage, retry: .manual) }
        return .init(.unknown, stage: stage)
    }
}

@MainActor func claudeDeadline<T: Sendable>(_ seconds: TimeInterval,
    operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    guard seconds.isFinite, (0...300).contains(seconds), seconds > 0 else {
        throw ProviderConnectionIssue(.configuration, stage: .probe, retry: .afterUserAction)
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ClaudeProcessError.timedOut
        }
        return try await group.next()!
    }
}
