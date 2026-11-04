import Foundation

/// A `DispatchQueue`-backed serial executor so an actor's Accessibility and CGEvent calls run on one dedicated
/// thread instead of the cooperative pool (a slow app can stall an AX call for its messaging timeout).
final class SerialQueueExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}

/// Output of a finished child process.
struct ProcessResult: Sendable, Equatable {
    var status: Int32
    var standardOutput: String
    var standardError: String
}

enum ProcessFailure: Error, Sendable, Equatable {
    case launchFailed(String)
    case timedOut
}

/// Runs a fixed executable with an argument vector (never a shell) with a hard timeout.
enum ProcessSupport {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingGate<ProcessResult>(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments.map { $0.replacingOccurrences(of: "\u{0000}", with: "") }
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()]
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                let error = Pipe()
                process.standardOutput = output
                process.standardError = error
                do {
                    try process.run()
                } catch {
                    gate.finish(.failure(ProcessFailure.launchFailed(error.localizedDescription)))
                    return
                }
                let pid = process.processIdentifier
                let timer = DispatchWorkItem { kill(pid, SIGTERM) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0.1), execute: timer)
                let outData = output.fileHandleForReading.readDataToEndOfFile()
                let errData = error.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let timedOut = timer.isCancelled == false && process.terminationReason == .uncaughtSignal
                timer.cancel()
                if timedOut {
                    gate.finish(.failure(ProcessFailure.timedOut))
                } else {
                    gate.finish(
                        .success(
                            ProcessResult(
                                status: process.terminationStatus, standardOutput: String(decoding: outData, as: UTF8.self),
                                standardError: String(decoding: errData, as: UTF8.self))))
                }
            }
        }
    }

    /// Runs a fixed AppleScript through `/usr/bin/osascript`; data travels as `argv` items after `--`, never as script
    /// text. Returns the script's text result (trailing newline removed).
    static func runAppleScript(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        var vector: [String] = []
        for line in script.split(separator: "\n", omittingEmptySubsequences: true) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            vector.append("-e")
            vector.append(String(line))
        }
        vector.append("--")
        vector.append(contentsOf: arguments)
        var result = try await run(executable: "/usr/bin/osascript", arguments: vector, timeout: timeout)
        if result.standardOutput.hasSuffix("\n") { result.standardOutput.removeLast() }
        return result
    }

    /// The error number at the end of an osascript message (`… (-1743)`), when present.
    static func appleScriptErrorCode(_ stderr: String) -> Int? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"\((-?\d+)\)\s*$"#, options: .regularExpression) else { return nil }
        return Int(trimmed[range].dropFirst().dropLast().trimmingCharacters(in: .whitespaces))
    }
}

/// Resumes a throwing continuation at most once.
final class ThrowingGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func finish(_ result: Result<T, any Error>) {
        let pending: CheckedContinuation<T, any Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
