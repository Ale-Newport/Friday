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

public struct SidecarLaunchConfiguration: Sendable {
    public enum Launch: Sendable {
        /// A packaged PyInstaller build: `<folder>/jarvis-backend` (release builds, inside the app bundle).
        case packaged(folder: URL)
        /// A development checkout: `<venv>/bin/python -m jarvis.server` with `cwd` at the Sidecar directory.
        case development(sidecarDirectory: URL)
    }

    public var launch: Launch
    public var dataDirectory: URL
    public var downloadsDirectory: URL
    public var readyTimeout: Duration

    public init(launch: Launch, dataDirectory: URL, downloadsDirectory: URL, readyTimeout: Duration = .seconds(120)) {
        self.launch = launch
        self.dataDirectory = dataDirectory
        self.downloadsDirectory = downloadsDirectory
        self.readyTimeout = readyTimeout
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
    private var stderrTail: [String] = []
    private(set) public var state: State = .stopped
    private var observers: [UUID: @Sendable (State) -> Void] = [:]

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

    private func set(_ newState: State) {
        state = newState
        for handler in observers.values { handler(newState) }
    }

    /// Starts the sidecar and waits for its ready line. Idempotent while running.
    @discardableResult
    public func start() async throws -> SidecarEndpoint {
        if let endpoint { return endpoint }
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
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.recordStderr(text) }
        }
        process.terminationHandler = { [weak self] finished in
            Task { await self?.processDidExit(status: finished.terminationStatus) }
        }
        do {
            try process.run()
        } catch {
            set(.failed(error.localizedDescription))
            throw SidecarError.launchFailed(error.localizedDescription)
        }
        self.process = process
        Self.logger.info("sidecar started pid=\(process.processIdentifier, privacy: .public)")

        let deadline = ContinuousClock.now + configuration.readyTimeout
        while ContinuousClock.now < deadline {
            if let ready = readyBox.readyLine() {
                guard let port = ready["port"] as? Int, port > 0 else {
                    throw SidecarError.invalidResponse("ready line without a port")
                }
                let endpoint = SidecarEndpoint(
                    baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token,
                    pid: process.processIdentifier, version: ready["version"] as? String ?? "?")
                set(.running(endpoint))
                return endpoint
            }
            if !process.isRunning {
                let tail = stderrTail.suffix(8).joined(separator: "\n")
                set(.failed(tail))
                throw SidecarError.exited(process.terminationStatus, tail)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        set(.failed("ready timeout"))
        throw SidecarError.readyTimeout
    }

    private func recordStderr(_ text: String) {
        for line in text.split(separator: "\n") where !line.isEmpty {
            stderrTail.append(String(line))
            if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
        }
    }

    public func recentLog(lines: Int = 40) -> [String] { Array(stderrTail.suffix(lines)) }

    private func processDidExit(status: Int32) {
        Self.logger.info("sidecar exited status=\(status, privacy: .public)")
        process = nil
        if case .running = state { set(.failed("exited with status \(status)")) } else if case .starting = state { set(.failed("exited with status \(status)")) }
        else if status == 0 { set(.stopped) }
    }

    /// Graceful shutdown: HTTP shutdown, then SIGTERM, then SIGKILL.
    public func stop() async {
        guard let process else { set(.stopped); return }
        if let endpoint {
            var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("api/shutdown"))
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning {
            process.terminate()
            let killDeadline = ContinuousClock.now + .seconds(3)
            while process.isRunning, ContinuousClock.now < killDeadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        self.process = nil
        set(.stopped)
    }

    /// Synchronous best-effort termination for app quit paths that cannot await.
    public nonisolated func terminateImmediately() {
        Task { await self.stop() }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
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
