import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessError: Error, LocalizedError {
    case launchFailed(String)
    case failed(command: String, code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            "Failed to launch process: \(message)"
        case .failed(let command, let code, let stderr):
            "`\(command)` exited with code \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Async wrapper around Process for short-lived command invocations.
enum ProcessRunner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Installed before run() so a fast exit can never be missed; the
        // stream buffers the status until it is awaited.
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes off the cooperative pool to avoid deadlocking on
        // outputs larger than the pipe buffer.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outTask = Task.detached { (try? outHandle.readToEnd()) ?? Data() }
        let errTask = Task.detached { (try? errHandle.readToEnd()) ?? Data() }

        var exitCode: Int32 = -1
        for await status in termination {
            exitCode = status
        }

        let stdout = String(data: await outTask.value, encoding: .utf8) ?? ""
        let stderr = String(data: await errTask.value, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
