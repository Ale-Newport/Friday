import Foundation
import FridayCore
import os

// MARK: - The Python sidecar (browser automation + Laya decisions)
//
// Friday keeps the working browser agent from the Jarvis project as a separate Python process: it owns MLX (Laya)
// and the Chrome DevTools connection. This type replaces the Tauri shell's launcher: it spawns the process as a
// DIRECT child (the sidecar's watchdog exits when its parent dies), passes a random bearer token and the data
// directory through the environment, waits for the single JSON "ready" line on stdout, and shuts it down
// gracefully (POST /api/shutdown → SIGTERM → SIGKILL) when Friday quits.
//
// When the child dies on its own (a crash, an OOM kill) the process is restarted with a bounded exponential
// back-off; the app re-injects its clients and re-applies the LLM session through the `onRestart` hook.

public struct SidecarLaunchConfiguration: Sendable {
    public enum Launch: Sendable {
        /// A packaged PyInstaller build: `<folder>/jarvis-backend` (release builds, inside the app bundle).
        case packaged(folder: URL)
        /// A development checkout: `<venv>/bin/python -m jarvis.server` with `cwd` at the Sidecar directory.
        case development(sidecarDirectory: URL)
        /// Any executable that speaks the sidecar protocol (tests use a shell script that prints the ready line).
        case command(executable: URL, arguments: [String], currentDirectory: URL?)
    }

    public var launch: Launch
    public var dataDirectory: URL
    public var downloadsDirectory: URL
    public var readyTimeout: Duration
    /// Delays before each automatic restart after an unexpected exit; the count bounds the attempts. The counter
    /// resets once an instance has stayed up for `healthyAfter`.
    public var restartDelays: [Duration]
    public var healthyAfter: Duration

    public init(launch: Launch, dataDirectory: URL, downloadsDirectory: URL, readyTimeout: Duration = .seconds(120),
                restartDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(30)], healthyAfter: Duration = .seconds(120)) {
        self.launch = launch
        self.dataDirectory = dataDirectory
        self.downloadsDirectory = downloadsDirectory
        self.readyTimeout = readyTimeout
        self.restartDelays = restartDelays
        self.healthyAfter = healthyAfter
    }

    /// Finds the sidecar: the packaged copy inside the app bundle first, then the development checkout next to the
    /// package (used by `swift test` and when running from Xcode without packaging).
    public static func locate(bundle: Bundle = .main, repositoryRoot: URL? = nil) -> Launch? {
        if let resources = bundle.resourceURL {
            let packaged = resources.appendingPathComponent("backend")
            if FileManager.default.isExecutableFile(atPath: packaged.appendingPathComponent("jarvis-backend").path) {
                return .packaged(folder: packaged)
            }
        }
        var candidates: [URL] = []
        if let repositoryRoot { candidates.append(repositoryRoot.appendingPathComponent("Sidecar")) }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sidecar"))
        for directory in candidates {
            let python = directory.appendingPathComponent(".venv/bin/python")
            if FileManager.default.isExecutableFile(atPath: python.path) { return .development(sidecarDirectory: directory) }
        }
        return nil
    }
}

public enum SidecarError: Error, Sendable, Equatable, LocalizedError {
    case notInstalled
    case launchFailed(String)
    case readyTimeout
    case exited(Int32, String)
    case notRunning
    case http(status: Int, code: String?, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "The browser sidecar is not installed (no packaged backend and no Sidecar/.venv)."
        case .launchFailed(let m): return "Could not start the sidecar: \(m)"
        case .readyTimeout: return "The sidecar did not become ready in time."
        case .exited(let code, let tail): return "The sidecar exited with status \(code). \(tail)"
        case .notRunning: return "The sidecar is not running."
        case .http(let status, let code, let message): return "Sidecar HTTP \(status)\(code.map { " (\($0))" } ?? ""): \(message)"
        case .invalidResponse(let m): return "Unexpected sidecar response: \(m)"
        }
    }
}

public struct SidecarEndpoint: Sendable, Hashable {
    public var baseURL: URL
    public var token: String
    public var pid: Int32
    public var version: String
    public init(baseURL: URL, token: String, pid: Int32, version: String) {
        self.baseURL = baseURL
        self.token = token
        self.pid = pid
        self.version = version
    }
}

public actor SidecarProcess {
    public enum State: Sendable, Equatable { case stopped, starting, running(SidecarEndpoint), failed(String) }

    static let logger = Logger(subsystem: "com.alejandro.friday", category: "sidecar")

    public let configuration: SidecarLaunchConfiguration
    private var process: Process?
    private let pidBox = PidBox()
    private var stderrTail: [String] = []
    private(set) public var state: State = .stopped
    private var observers: [UUID: @Sendable (State) -> Void] = [:]

    // Automatic restart after a crash.
    private var restartHandler: (@Sendable (SidecarEndpoint) async -> Void)?
    private var restartTask: Task<Void, Never>?
    private var crashCount = 0
    private var runningSince: ContinuousClock.Instant?
    private var stopRequested = false
    /// Exits that were not asked for (crashes), for diagnostics.
    private(set) public var unexpectedExits = 0
    private(set) public var autoRestart = true

    public init(configuration: SidecarLaunchConfiguration) {
        self.configuration = configuration
    }

    public var endpoint: SidecarEndpoint? {
        if case .running(let endpoint) = state { return endpoint }
        return nil
    }

    public func observe(_ handler: @escaping @Sendable (State) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Called after the sidecar came back by itself (not after `start()`): the app re-injects its clients, re-applies
    /// the LLM session and reloads Laya through it.
    public func setRestartHandler(_ handler: (@Sendable (SidecarEndpoint) async -> Void)?) { restartHandler = handler }

    public func setAutoRestart(_ enabled: Bool) {
        autoRestart = enabled
        if !enabled { restartTask?.cancel(); restartTask = nil }
    }

    private func set(_ newState: State) {
        state = newState
        for handler in observers.values { handler(newState) }
    }

    /// Starts the sidecar and waits for its ready line. Idempotent while running.
    @discardableResult
    public func start() async throws -> SidecarEndpoint {
        if let endpoint { return endpoint }
        stopRequested = false
        pidBox.clearStopRequested()
        restartTask?.cancel()
        restartTask = nil
        set(.starting)
        let token = Self.randomToken()
        try FileManager.default.createDirectory(at: configuration.dataDirectory, withIntermediateDirectories: true)

        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        environment["FRIDAY_TOKEN"] = token
        environment["JARVIS_TOKEN"] = token
        environment["FRIDAY_DATA_DIR"] = configuration.dataDirectory.path
        environment["JARVIS_DATA_DIR"] = configuration.dataDirectory.path
        environment["FRIDAY_DOWNLOADS_DIR"] = configuration.downloadsDirectory.path
        environment["JARVIS_DOWNLOADS_DIR"] = configuration.downloadsDirectory.path
        environment["FRIDAY_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["JARVIS_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        switch configuration.launch {
        case .packaged(let folder):
            process.executableURL = folder.appendingPathComponent("jarvis-backend")
            process.currentDirectoryURL = folder
        case .development(let directory):
            process.executableURL = directory.appendingPathComponent(".venv/bin/python")
            process.arguments = ["-m", "jarvis.server"]
            process.currentDirectoryURL = directory
        case .command(let executable, let arguments, let currentDirectory):
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
        }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let readyBox = ReadyBox()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            readyBox.append(data)
        }
        let stderrBox = LineBox()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            stderrBox.append(text)
            Task { await self?.recordStderr(text) }
        }
        process.terminationHandler = { [weak self] finished in
            // Whatever is still buffered in the pipe belongs to this instance's diagnostics (read before the handler
            // is torn down, so the exit reason is complete).
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = stderr.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { stderrBox.append(String(decoding: rest, as: UTF8.self)) }
            let status = finished.terminationStatus
            let tail = stderrBox.tail(8)
            Task { await self?.processDidExit(finished, status: status, lastLines: tail) }
        }
        do {
            try process.run()
        } catch {
            set(.failed(error.localizedDescription))
            throw SidecarError.launchFailed(error.localizedDescription)
        }
        self.process = process
        pidBox.set(process.processIdentifier)
        Self.logger.info("sidecar started pid=\(process.processIdentifier, privacy: .public)")

        let deadline = ContinuousClock.now + configuration.readyTimeout
        while ContinuousClock.now < deadline {
            if let ready = readyBox.readyLine() {
                guard let port = ready["port"] as? Int, port > 0 else {
                    forget(process)
                    process.terminate()
                    set(.failed("ready line without a port"))
                    throw SidecarError.invalidResponse("ready line without a port")
                }
                let endpoint = SidecarEndpoint(
                    baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token,
                    pid: process.processIdentifier, version: ready["version"] as? String ?? "?")
                runningSince = .now
                set(.running(endpoint))
                return endpoint
            }
            if !process.isRunning {
                forget(process)
                let tail = (stderrBox.tail(8) + stderrTail.suffix(8)).joined(separator: "\n")
                set(.failed(tail))
                throw SidecarError.exited(process.terminationStatus, tail)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Timed out: the instance is abandoned before it is killed, so its exit handler cannot touch a newer one.
        forget(process)
        process.terminate()
        set(.failed("ready timeout"))
        throw SidecarError.readyTimeout
    }

    /// Drops the handle to an instance this actor no longer owns (its exit handler is then ignored).
    private func forget(_ instance: Process) {
        if process === instance {
            process = nil
            pidBox.set(nil)
        }
    }

    private func recordStderr(_ text: String) {
        for line in text.split(separator: "\n") where !line.isEmpty {
            stderrTail.append(String(line))
            if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
        }
    }

    public func recentLog(lines: Int = 40) -> [String] { Array(stderrTail.suffix(lines)) }

    private func processDidExit(_ finished: Process, status: Int32, lastLines: [String]) {
        guard finished === process else {
            Self.logger.info("ignoring the exit of a sidecar instance that was already replaced (status=\(status, privacy: .public))")
            return
        }
        Self.logger.info("sidecar exited status=\(status, privacy: .public)")
        process = nil
        pidBox.set(nil)
        if pidBox.stopRequested || stopRequested {
            set(.stopped)  // the app asked for it (quit path): not a crash, no restart
            return
        }
        let wasRunning: Bool
        if case .running = state { wasRunning = true } else { wasRunning = false }
        if wasRunning || { if case .starting = state { return true } else { return false } }() {
            unexpectedExits += 1
            let reason = "exited with status \(status)" + (lastLines.isEmpty ? "" : ": " + lastLines.suffix(3).joined(separator: " | "))
            set(.failed(reason))
            if wasRunning { scheduleRestartIfNeeded() }
        } else if status == 0 {
            set(.stopped)
        }
    }

    // MARK: Automatic restart

    private func scheduleRestartIfNeeded() {
        guard autoRestart, !stopRequested, restartTask == nil else { return }
        if let since = runningSince, ContinuousClock.now - since >= configuration.healthyAfter { crashCount = 0 }
        runningSince = nil
        guard crashCount < configuration.restartDelays.count else {
            Self.logger.error("sidecar crashed \(self.crashCount, privacy: .public) times in a row; not restarting again")
            return
        }
        let delay = configuration.restartDelays[crashCount]
        crashCount += 1
        Self.logger.warning("sidecar restart \(self.crashCount, privacy: .public)/\(self.configuration.restartDelays.count, privacy: .public) in \(delay, privacy: .public)")
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.performRestart()
        }
    }

    private func performRestart() async {
        restartTask = nil
        guard !stopRequested, process == nil, endpoint == nil else { return }
        do {
            let endpoint = try await start()
            Self.logger.info("sidecar restarted pid=\(endpoint.pid, privacy: .public)")
            if let restartHandler { await restartHandler(endpoint) }
        } catch {
            Self.logger.error("sidecar restart failed: \(error.localizedDescription, privacy: .public)")
            scheduleRestartIfNeeded()
        }
    }

    /// Number of automatic restarts attempted since the last healthy run (diagnostics).
    public var restartAttempts: Int { crashCount }

    /// Graceful shutdown: HTTP shutdown, then SIGTERM, then SIGKILL. Cancels any pending automatic restart.
    public func stop() async {
        stopRequested = true
        restartTask?.cancel()
        restartTask = nil
        guard let process else { set(.stopped); return }
        if let endpoint {
            var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("api/shutdown"))
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        set(.stopped)  // from here on the exit handler treats the exit as requested
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning {
            process.terminate()
            let killDeadline = ContinuousClock.now + .seconds(3)
            while process.isRunning, ContinuousClock.now < killDeadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        forget(process)
        set(.stopped)
    }

    /// Synchronous best-effort termination for app quit paths that cannot await: SIGTERM right now (the sidecar's own
    /// parent watchdog is the second line of defence), then the graceful path if the app is still around.
    public nonisolated func terminateImmediately() {
        pidBox.markStopRequested()
        if let pid = pidBox.get() { kill(pid, SIGTERM) }
        Task { await self.stop() }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The child's pid, readable from synchronous (nonisolated) quit paths.
final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    private var _stopRequested = false
    var stopRequested: Bool { lock.withLock { _stopRequested } }
    func set(_ pid: Int32?) { lock.withLock { self.pid = pid } }
    func get() -> Int32? { lock.withLock { pid } }
    func markStopRequested() { lock.withLock { _stopRequested = true } }
    func clearStopRequested() { lock.withLock { _stopRequested = false } }
}

/// The last lines of a stream, kept by the pipe handlers (which run off the actor).
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ text: String) {
        lock.withLock {
            for line in text.split(separator: "\n") where !line.isEmpty { lines.append(String(line)) }
            if lines.count > 50 { lines.removeFirst(lines.count - 50) }
        }
    }
    func tail(_ count: Int) -> [String] { lock.withLock { Array(lines.suffix(count)) } }
}

/// Accumulates stdout until the first complete JSON line with `"event": "ready"`.
final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var ready: [String: Any]?

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard ready == nil else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], json["event"] as? String == "ready" {
                ready = json
                return
            }
        }
        if buffer.count > 65_536 { buffer.removeAll() }
    }

    func readyLine() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }
}
