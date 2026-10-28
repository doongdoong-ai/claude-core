import Foundation

/// File-backed output avoids pipe deadlocks. A non-zero exit is reported after
/// stdout is complete, because the CLI writes its structured error there.
final class ClaudeProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var active = false
    init() {}

    /// Subscription login only: anything that could route requests to API
    /// billing, another cloud, or a different model mapping is removed.
    static let removedEnvironment = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
        "OPENAI_API_KEY", "CODEX_API_KEY"]

    func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        if let current, current.isRunning {
            let pid = current.processIdentifier
            // Terminate the group so a launcher wrapper cannot leave workers behind.
            let ownsGroup = getpgid(pid) == pid
            if ownsGroup { kill(-pid, SIGTERM) } else { current.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if ownsGroup {
                    if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
                } else if current.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// Returns the exit status; only launch failures, cancellation and timeouts throw.
    func run(executable: URL, arguments: [String], directory: URL, output: URL, log: URL, input: String? = nil,
             timeout: Double) async throws -> Int32 {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw ClaudeError.message("올바른 처리 제한 시간이 필요합니다.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let task = Process()
                    do {
                        self.lock.lock()
                        let alreadyCancelled = self.cancelled, alreadyActive = self.active
                        if !alreadyCancelled && !alreadyActive { self.active = true }
                        self.lock.unlock()
                        if alreadyCancelled { throw CancellationError() }
                        if alreadyActive { throw ClaudeError.message("이미 실행 중인 작업이 있습니다.") }
                        defer { self.lock.lock(); self.process = nil; self.active = false; self.lock.unlock() }
                        guard FileManager.default.createFile(atPath: log.path, contents: nil),
                              FileManager.default.createFile(atPath: output.path, contents: nil) else {
                            throw ClaudeError.message("처리 로그를 저장하지 못했습니다. 저장 공간과 폴더 권한을 확인해 주세요.")
                        }
                        let logHandle = try FileHandle(forWritingTo: log), outputHandle = try FileHandle(forWritingTo: output)
                        var inputHandle: FileHandle?
                        var inputURL: URL?
                        defer {
                            try? logHandle.close(); try? outputHandle.close(); try? inputHandle?.close()
                            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
                        }
                        if let input {
                            let path = directory.appendingPathComponent(".stdin-\(UUID().uuidString)")
                            try Data(input.utf8).write(to: path, options: .atomic)
                            inputURL = path; inputHandle = try FileHandle(forReadingFrom: path)
                        }
                        task.executableURL = executable; task.arguments = arguments; task.currentDirectoryURL = directory
                        var env = ProcessInfo.processInfo.environment
                        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                        for key in Self.removedEnvironment { env.removeValue(forKey: key) }
                        task.environment = env
                        task.standardOutput = outputHandle; task.standardError = logHandle
                        task.standardInput = inputHandle ?? FileHandle.nullDevice
                        self.lock.lock()
                        if self.cancelled { self.lock.unlock(); throw CancellationError() }
                        do { try task.run(); self.process = task; self.lock.unlock() }
                        catch { self.lock.unlock(); throw error }
                        let deadline = ProcessInfo.processInfo.systemUptime + timeout
                        var timedOut = false
                        while task.isRunning {
                            if ProcessInfo.processInfo.systemUptime > deadline { timedOut = true; self.cancel(); break }
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                        task.waitUntilExit()
                        if timedOut { throw ClaudeProcessError.timedOut }
                        self.lock.lock(); let wasCancelled = self.cancelled; self.lock.unlock()
                        if wasCancelled { throw CancellationError() }
                        continuation.resume(returning: task.terminationStatus)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard try handle.seekToEnd() <= UInt64(maximumBytes) else { throw ClaudeProcessError.outputTooLarge }
        try handle.seek(toOffset: 0)
        return try handle.read(upToCount: maximumBytes) ?? Data()
    }
}

/// Typed local process failures, independent of the CLI's untrusted stderr.
enum ClaudeProcessError: LocalizedError {
    case timedOut, exited(Int32), outputTooLarge
    var errorDescription: String? {
        switch self {
        case .timedOut: return "처리 시간이 초과되었습니다. 다시 시도해 주세요."
        case .exited: return "Claude 실행이 중단되었습니다. 다시 연결해 주세요."
        case .outputTooLarge: return "Claude 응답이 너무 큽니다."
        }
    }
}
