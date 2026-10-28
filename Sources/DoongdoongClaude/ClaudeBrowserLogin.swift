import Foundation
import DoongdoongAI

/// User-initiated subscription sign-in. The CLI opens the browser, hosts the
/// callback and stores tokens; the host app only learns that it finished.
@MainActor public enum ClaudeBrowserLogin {
    public static func signIn(executable: URL, timeout: TimeInterval = 180) async throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProviderConnectionIssue(.installationRequired, stage: .installation, retry: .afterUserAction)
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-claude-login-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let status: Int32
        do {
            // `--claudeai` pins the subscription flow; Console login would mean API billing.
            status = try await ClaudeProcessRunner().run(executable: executable, arguments: ["auth", "login", "--claudeai"],
                directory: workspace, output: workspace.appendingPathComponent("login.out"),
                log: workspace.appendingPathComponent("login.log"), timeout: timeout)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ClaudeConnection.classify(error, stage: .login)
        }
        guard status == 0 else { throw ProviderConnectionIssue(.loginRequired, stage: .login, retry: .afterUserAction) }
    }
}
