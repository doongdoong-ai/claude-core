import Foundation
import DoongdoongAI

/// CLI model aliases. An alias always resolves to the newest model of that
/// family, so the app never has to ship a release for a model update.
public struct ClaudeModel: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard Self.allCases.map(\.rawValue).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
    private init(alias: String) { rawValue = alias }
    public static let sonnet = ClaudeModel(alias: "sonnet")
    public static let allCases = [sonnet]
    public var displayName: String { rawValue == "sonnet" ? "Sonnet" : rawValue }

    /// "claude-sonnet-5-5" → "Sonnet 5.5". Unknown shapes are shown unchanged.
    public static func displayName(resolved model: String) -> String {
        let parts = model.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", parts[1].allSatisfy(\.isLetter) else { return model }
        let version = parts[2...].prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        guard !version.isEmpty else { return model }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst() + " " + version.joined(separator: ".")
    }
}

public enum ClaudeEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high, xhigh, max
}

public struct ClaudeConfiguration: Sendable {
    public let executable: URL
    public let model: ClaudeModel
    public let effort: ClaudeEffort
    public let requestTimeout: TimeInterval
    public init(executable: URL, model: ClaudeModel = .sonnet, effort: ClaudeEffort = .medium, requestTimeout: TimeInterval = 300) {
        self.executable = executable; self.model = model; self.effort = effort; self.requestTimeout = requestTimeout
    }
    public var identity: TextProviderIdentity {
        .init(provider: "claude", model: model.rawValue, reasoningEffort: effort.rawValue)
    }
}

public enum ClaudeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
