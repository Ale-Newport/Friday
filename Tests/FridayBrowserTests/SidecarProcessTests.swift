import Foundation
import Testing
import FridaySidecar

/// The sidecar launcher against a shell script that speaks the ready-line protocol: crashes are noticed and the
/// process comes back with back-off; an explicit stop never restarts.
@Suite(.serialized) struct SidecarProcessTests {
    /// A fake sidecar: prints the ready line, then exits with status 3 on the first `crashes` runs and sleeps afterwards.
    static func fakeSidecar(crashes: Int, in directory: URL) throws -> (script: URL, counter: URL) {
        let script = directory.appendingPathComponent("fake-sidecar.sh")
        let counter = directory.appendingPathComponent("runs.txt")
        let source = """
        #!/bin/sh
        counter="$1"; crashes="$2"
        n=$(cat "$counter" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$counter"
        printf '{"event":"ready","port":1,"version":"test","pid":%d}\\n' $$
        if [ "$n" -le "$crashes" ]; then sleep 0.15; echo "boom run $n" >&2; exit 3; fi
        trap 'exit 0' TERM
        sleep 30 &
        wait $!
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, counter)
    }

    static func configuration(script: URL, counter: URL, crashes: Int, directory: URL, delays: [Duration]) -> SidecarLaunchConfiguration {
        SidecarLaunchConfiguration(
            launch: .command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path, counter.path, String(crashes)], currentDirectory: directory),
            dataDirectory: directory.appendingPathComponent("data"), downloadsDirectory: directory.appendingPathComponent("downloads"),
            readyTimeout: .seconds(10), restartDelays: delays, healthyAfter: .seconds(60))
    }

    static func runs(_ counter: URL) -> Int { Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "0") ?? 0 }

    static func waitUntil(_ timeout: Duration = .seconds(8), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    @Test func aCrashRestartsTheSidecarAndCallsTheRestartHook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("friday-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (script, counter) = try Self.fakeSidecar(crashes: 1, in: directory)
        let process = SidecarProcess(configuration: Self.configuration(script: script, counter: counter, crashes: 1, directory: directory, delays: [.milliseconds(100), .milliseconds(200)]))
        let restarted = Recorder<SidecarEndpoint>()
        let states = Recorder<SidecarProcess.State>()
        await process.setRestartHandler { endpoint in restarted.append(endpoint) }
        _ = await process.observe { state in states.append(state) }
        let first = try await process.start()
        #expect(first.version == "test" && first.pid > 0)
        #expect(await Self.waitUntil { restarted.values.count == 1 })
        let second = try #require(restarted.values.first)
        #expect(second.pid != first.pid)
        let current = await process.endpoint
        #expect(current == second)
        let exits = await process.unexpectedExits
        #expect(exits == 1 && Self.runs(counter) == 2)
        let failures = states.values.compactMap { state -> String? in if case .failed(let reason) = state { return reason } else { return nil } }
        #expect(failures.count == 1 && failures[0].contains("exited with status 3") && failures[0].contains("boom run 1"))
        await process.stop()
        var state = await process.state
        #expect(state == .stopped)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(Self.runs(counter) == 2)   // stopping never restarts
        state = await process.state
        #expect(state == .stopped)
    }

    @Test func restartsAreBoundedAndAnExplicitStopCancelsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("friday-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (script, counter) = try Self.fakeSidecar(crashes: 99, in: directory)
        let process = SidecarProcess(configuration: Self.configuration(script: script, counter: counter, crashes: 99, directory: directory, delays: [.milliseconds(50), .milliseconds(50)]))
        _ = try await process.start()
        // The initial run and two restarts crash; then it gives up and stays failed.
        #expect(await Self.waitUntil { await process.unexpectedExits == 3 })
        try? await Task.sleep(for: .milliseconds(300))
        let attempts = await process.restartAttempts
        #expect(Self.runs(counter) == 3 && attempts == 2)
        let state = await process.state
        if case .failed = state {} else { Issue.record("expected failed, got \(state)") }
        let endpoint = await process.endpoint
        #expect(endpoint == nil)

        // A fresh start resets the budget; stopping while a restart is pending cancels it.
        let again = SidecarProcess(configuration: Self.configuration(script: script, counter: counter, crashes: 99, directory: directory, delays: [.milliseconds(300)]))
        _ = try await again.start()
        #expect(await Self.waitUntil { await again.unexpectedExits == 1 })
        await again.stop()
        try? await Task.sleep(for: .milliseconds(500))
        let stopped = await again.state
        #expect(Self.runs(counter) == 4 && stopped == .stopped)
    }

    @Test func autoRestartCanBeTurnedOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("friday-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (script, counter) = try Self.fakeSidecar(crashes: 99, in: directory)
        let process = SidecarProcess(configuration: Self.configuration(script: script, counter: counter, crashes: 99, directory: directory, delays: [.milliseconds(50)]))
        await process.setAutoRestart(false)
        _ = try await process.start()
        #expect(await Self.waitUntil { await process.unexpectedExits == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(Self.runs(counter) == 1)
        let state = await process.state
        if case .failed = state {} else { Issue.record("expected failed") }
    }
}

final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    var values: [Value] { lock.withLock { _values } }
    func append(_ value: Value) { lock.withLock { _values.append(value) } }
}
