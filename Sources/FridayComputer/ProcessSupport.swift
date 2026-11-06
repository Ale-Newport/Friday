import Foundation
import os

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
    /// How long a child gets to honour SIGTERM at the deadline before it is killed outright.
    static let killGracePeriod: TimeInterval = 2
    /// After the child exited, how long to wait for its pipes to reach EOF (a grandchild it left behind may still
    /// hold them open; its output is not ours to wait for).
    static let pipeGracePeriod: TimeInterval = 1

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
                // Both pipes are drained as data arrives, so a chatty stderr cannot block stdout (or vice versa)
                // once a pipe buffer fills up, and nothing waits on a pipe a grandchild keeps open.
                let outCollector = PipeCollector(output.fileHandleForReading)
                let errCollector = PipeCollector(error.fileHandleForReading)
                do {
                    try process.run()
                } catch {
                    outCollector.close()
                    errCollector.close()
                    gate.finish(.failure(ProcessFailure.launchFailed(error.localizedDescription)))
                    return
                }
                let pid = process.processIdentifier
                // At the deadline: SIGTERM, then SIGKILL for a child that ignores it (otherwise the wait below and
                // the continuation would hang). Both work items are cancelled once the child has exited.
                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let killer = DispatchWorkItem { kill(pid, SIGKILL) }
                let terminator = DispatchWorkItem {
                    timedOut.withLock { $0 = true }
                    kill(pid, SIGTERM)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGracePeriod, execute: killer)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0.1), execute: terminator)
                process.waitUntilExit()
                terminator.cancel()
                killer.cancel()
                let deadline = DispatchTime.now() + pipeGracePeriod
                let outData = outCollector.finish(by: deadline)
                let errData = errCollector.finish(by: deadline)
                if timedOut.withLock({ $0 }) {
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

/// Collects everything a pipe produces through its readability handler, without ever blocking a thread on it.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let eof = DispatchSemaphore(value: 0)
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.eof.signal()
            } else {
                self.lock.withLock { self.data.append(chunk) }
            }
        }
    }

    /// Waits for EOF until `deadline`, then stops reading and returns what arrived.
    func finish(by deadline: DispatchTime) -> Data {
        _ = eof.wait(timeout: deadline)
        close()
        return lock.withLock { data }
    }

    func close() {
        handle.readabilityHandler = nil
        try? handle.close()
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
