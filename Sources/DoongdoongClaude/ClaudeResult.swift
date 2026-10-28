import Foundation
import DoongdoongAI

/// The CLI's `--output-format json` envelope. Only `structured_output` is
/// returned to callers; the prose `result` never becomes app data.
struct ClaudeResult: Equatable {
    let structured: Data
    /// Canonical model the alias resolved to, e.g. "claude-sonnet-5-5".
    let resolvedModel: String?

    static func parse(_ data: Data, exitStatus: Int32, model: ClaudeModel, maximumResponseBytes: Int) throws -> ClaudeResult {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["type"] as? String == "result" else {
            if exitStatus != 0 { throw ClaudeProcessError.exited(exitStatus) }
            throw ProviderConnectionIssue(.invalidResponse, stage: .probe, retry: .manual)
        }
        if exitStatus != 0 || envelope["is_error"] as? Bool != false { throw failure(in: envelope) }
        guard let output = envelope["structured_output"], output is [String: Any] || output is [Any],
              let structured = try? JSONSerialization.data(withJSONObject: output) else {
            throw ProviderConnectionIssue(.invalidResponse, stage: .probe, retry: .manual)
        }
        guard structured.count <= maximumResponseBytes else { throw TextGenerationError.capacityExceeded }
        let family = "claude-" + model.rawValue + "-"
        let resolved = (envelope["modelUsage"] as? [String: Any])?.keys.sorted().first { $0.hasPrefix(family) }
        return .init(structured: structured, resolvedModel: resolved)
    }

    /// Classifies by HTTP status only. The prose is consulted solely to tell a
    /// context-length rejection apart from other 400s, so it can only ever
    /// trigger a smaller retry, never an auth, billing or configuration diagnosis.
    static func failure(in envelope: [String: Any]) -> Error {
        let status = envelope["api_error_status"] as? Int
        switch status {
        case 401, 403: return ProviderConnectionIssue(.loginRequired, stage: .probe, retry: .afterUserAction)
        case 404: return ProviderConnectionIssue(.configuration, stage: .probe, retry: .afterUserAction)
        case 413: return TextGenerationError.capacityExceeded
        case 400:
            let message = (envelope["result"] as? String ?? "").lowercased()
            if ["prompt is too long", "context window", "context length", "max_tokens"].contains(where: message.contains) {
                return TextGenerationError.capacityExceeded
            }
            return ProviderConnectionIssue(.invalidResponse, stage: .probe, retry: .manual)
        case 408: return ProviderConnectionIssue(.timedOut, stage: .probe, retry: .manual)
        case 429: return ProviderConnectionIssue(.usageLimited, stage: .probe, retry: .later)
        case let code? where (500...599).contains(code):
            return ProviderConnectionIssue(.serviceUnavailable, stage: .probe, retry: .later)
        default:
            if let subtype = envelope["subtype"] as? String, subtype.hasPrefix("error_max") {
                return ProviderConnectionIssue(.invalidResponse, stage: .probe, retry: .manual)
            }
            return ProviderConnectionIssue(.unknown, stage: .probe)
        }
    }
}

/// `claude auth status --json`. Only a Claude subscription login is accepted;
/// Console (API billing) and third-party clouds are rejected.
enum ClaudeAccount {
    static func validate(_ data: Data) throws {
        guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = status["loggedIn"] as? Bool else {
            throw ProviderConnectionIssue(.invalidResponse, stage: .account, retry: .manual)
        }
        guard loggedIn else { throw ProviderConnectionIssue(.loginRequired, stage: .account, retry: .afterUserAction) }
        guard status["authMethod"] as? String == "claude.ai", (status["apiProvider"] as? String ?? "firstParty") == "firstParty" else {
            throw ProviderConnectionIssue(.unsupportedAuthentication, stage: .account, retry: .afterUserAction)
        }
    }
}
