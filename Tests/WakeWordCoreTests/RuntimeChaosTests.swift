import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

struct ChaosRandom {
    var s: UInt64
    init(seed: UInt64) {
        var z = seed &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        s = z ^ (z >> 31)
    }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { pick(100) < percent }
}

/// Randomised lifecycle abuse: sleep/wake, permission flips, device and route changes, engine faults, settings
/// changes, assistant sessions and clock jumps, in a random order and with random timing. Whatever happened,
/// once every external condition is put back to normal the runtime must be *healthy*: listening, with the
/// microphone open, exactly one live engine, an ungated detector that really delivers a detection to the
/// assistant — and when disabled or stopped, nothing left running.
///
/// Reproducible: a failure names its seed and the operations that led to it. Defaults keep the suite quick; for a
/// deeper run:  `CHAOS_FIRST=1 CHAOS_COUNT=300 CHAOS_OPS=30 swift test --filter RuntimeChaosTests`
@Suite(.timeLimit(.minutes(30)))
struct RuntimeChaosTests {
    static func runOne(seed: UInt64, ops: Int, verbose: Bool = false) async throws -> String? {
        var rng = ChaosRandom(seed: seed)
        let factory = EngineFactory()
        let behaviorRng = Protected(ChaosRandom(seed: seed &+ 99))
        let chaos = Protected(true)
        let behavior: @Sendable () -> MockWakeWordEngine.Behavior = {
            var b = MockWakeWordEngine.Behavior()
            b.supportsLiveSensitivity = false
            b.initializeDelay = .milliseconds(10)
            behaviorRng.withLock { r in
                if chaos.get(), r.chance(15) { b.failFromFrame = (index: 20, error: .processingFailed("fuzz")) }
            }
            return b
        }
        let descriptors = [factory.descriptor(id: "alpha", behavior: behavior), factory.descriptor(id: "beta", behavior: behavior)]
        var settings = RuntimeSettings(engineID: "alpha")
        settings.sessionAudioPolicy = rng.chance(50) ? .releaseMicrophone : .gateDetector
        settings.maxSessionDuration = 30
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(settings: settings, engines: descriptors, factory: factory, assistant: assistant)
        let log = await EventLog(harness.runtime)
        var trace: [String] = []
        func note(_ s: String) { trace.append(s) }

        do { try await harness.startListening() } catch { return "never reached initial listening" }

        var current = await harness.runtime.snapshot().settings
        var released = false
        for step in 0..<ops {
            let op = rng.pick(26)
            switch op {
            case 0: note("willSleep"); harness.system.send(.willSleep)
            case 1: note("didWake"); harness.system.send(.didWake)
            case 2: note("sessionResign"); harness.system.send(.userSessionDidResignActive)
            case 3: note("sessionActive"); harness.system.send(.userSessionDidBecomeActive)
            case 4: current.isEnabled.toggle(); note("enabled=\(current.isEnabled)"); await harness.runtime.apply(current)
            case 5: current.sensitivity = Float(rng.pick(9) + 1) / 10; note("sens=\(current.sensitivity)"); await harness.runtime.apply(current)
            case 6: current.input = (current.input == .systemDefault) ? .device(uid: "usb-1") : .systemDefault; note("input=\(current.input)"); await harness.runtime.apply(current)
            case 7: current.sessionAudioPolicy = (current.sessionAudioPolicy == .gateDetector) ? .releaseMicrophone : .gateDetector; note("policy=\(current.sessionAudioPolicy)"); await harness.runtime.apply(current)
            case 8: current.engineID = (current.engineID == "alpha") ? "beta" : "alpha"; note("engine=\(current.engineID)"); await harness.runtime.apply(current)
            case 9: note("credentialsDidChange"); await harness.runtime.credentialsDidChange()
            case 10: note("retry"); await harness.runtime.retry()
            case 11: note("perm denied"); harness.permission.set(.denied); harness.system.send(.applicationDidBecomeActive)
            case 12: note("perm authorized"); harness.permission.set(.authorized); harness.system.send(.applicationDidBecomeActive)
            case 13: note("configChange"); harness.capture.simulateConfigurationChange()
            case 14: note("devices none"); harness.devices.set([], emitting: .deviceListChanged)
            case 15: note("devices builtIn"); harness.devices.set([FakeDevices.builtIn], emitting: .deviceListChanged)
            case 16, 17:
                note("detect")
                if let engine = factory.latest(current.engineID) { engine.trigger() }
                harness.capture.push(seconds: 0.2)
            case 18: note("simulate"); await harness.runtime.simulateWakeWord()
            case 19: note("clock +0.4"); harness.clock.advance(by: .milliseconds(400))
            case 20: note("clock +1.5"); harness.clock.advance(by: .milliseconds(1500))
            case 21: note("clock +6"); harness.clock.advance(by: .seconds(6))
            case 22: if !released && rng.chance(40) { note("assistant release"); assistant.release(); released = true }
            case 23: note("defaultInputChanged"); harness.devices.set([FakeDevices.builtIn], emitting: .defaultInputChanged)
            case 24: note("feed 0.6s"); harness.capture.push(seconds: 0.6)
            default: note("feed 1.5s"); harness.capture.push(seconds: 1.5)
            }
            if verbose { print("step \(step): \(trace.last ?? "")") }
            try await Task.sleep(for: .milliseconds(rng.pick(14)))
        }

        // ---- Quiesce: put every external condition back to normal, then expect a healthy runtime. ----
        note("QUIESCE")
        chaos.withLock { $0 = false }
        harness.permission.set(.authorized)
        harness.devices.set([FakeDevices.builtIn], emitting: .deviceListChanged)
        harness.system.send(.userSessionDidBecomeActive)
        harness.system.send(.didWake)
        harness.system.send(.applicationDidBecomeActive)
        assistant.release()
        assistant.behavior = .immediate
        current.isEnabled = true
        current.input = .systemDefault
        await harness.runtime.apply(current)
        await harness.runtime.credentialsDidChange()   // rebuild the engine without scripted faults
        for _ in 0..<12 {
            harness.clock.advance(by: .seconds(31))
            try await Task.sleep(for: .milliseconds(25))
            await harness.runtime.retry()
        }
        let reached: Bool
        do { try await harness.runtime.waitForState("listening", timeout: .seconds(4)) { $0 == .listening }; reached = true } catch { reached = false }
        let snap = await harness.runtime.snapshot()
        func dump() -> String {
            "final=\(snap.state.label) notice=\(snap.notice ?? "-") mic=\(snap.microphone) captureRunning=\(harness.capture.isRunning) trace=\(trace.joined(separator: " | "))"
        }
        if !reached { return "NOT LISTENING after quiesce: \(dump())" }
        if !harness.capture.isRunning { return "listening but capture not running: \(dump())" }
        if snap.capture == nil { return "listening but snapshot.capture nil: \(dump())" }
        let alive = factory.engines().filter { !$0.isShutDown }
        if alive.count != 1 { return "live engines = \(alive.count) (expected 1): \(dump())" }
        let stats = await harness.runtime.pipelineStatistics()
        if stats.isGated { return "listening but pipeline gated: \(dump())" }
        if !stats.hasEngine { return "listening but pipeline has no engine: \(dump())" }

        // Functional check: the detector is really live.
        let engine = try #require(alive.first)
        let callsBefore = assistant.calls.count
        var frames = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while assistant.calls.count == callsBefore, ContinuousClock.now < deadline {
            if frames % 8 == 0 { engine.trigger() }   // spaced wider than the debounce window
            harness.capture.push(seconds: 0.2)
            frames += 1
            try await Task.sleep(for: .milliseconds(3))
            // the very first detections may be inside a holdoff/cooldown window: nudge time
            if frames % 10 == 0 { harness.clock.advance(by: .seconds(1)) }
        }
        if assistant.calls.count == callsBefore {
            let st = await harness.runtime.pipelineStatistics()
            let supp = log.suppressions.suffix(5).map { "\($0)" }.joined(separator: ",")
            let detail = "engine.processCalls=\(engine.callLog.processCalls) engine.id=\(engine.identifier) stats: ingested=\(st.chunksIngested) discarded=\(st.chunksDiscarded) frames=\(st.framesProcessed) errors=\(st.engineErrors) accepted=\(st.detectionsAccepted) suppressed=\(st.detectionsSuppressed) gated=\(st.isGated) lastSuppressions=[\(supp)] ignored=\(log.ignored) states=\(log.states.suffix(6).map(\.label))"
            return "listening but a triggered detection never reached the assistant (deaf?): \(detail) :: \(dump())"
        }
        try await harness.runtime.waitForState("listening again", timeout: .seconds(3)) { $0 == .listening }

        // Disable: everything must be released.
        current.isEnabled = false
        await harness.runtime.apply(current)
        try await Task.sleep(for: .milliseconds(150))
        let off = await harness.runtime.snapshot()
        if off.state != .paused(.userDisabled) { return "disable did not pause: \(off.state.label) \(dump())" }
        if harness.capture.isRunning { return "disabled but capture running: \(dump())" }
        let aliveOff = factory.engines().filter { !$0.isShutDown }
        if !aliveOff.isEmpty { return "disabled but \(aliveOff.count) engine(s) alive: \(dump())" }

        await harness.runtime.stop()
        if harness.capture.isRunning { return "after stop capture running: \(dump())" }
        let aliveStopped = factory.engines().filter { !$0.isShutDown }
        if !aliveStopped.isEmpty { return "after stop \(aliveStopped.count) engine(s) alive: \(dump())" }
        _ = log
        return nil
    }

    @Test func theRuntimeRecoversFromAnyOrderOfAbuse() async throws {
        let first = UInt64(ProcessInfo.processInfo.environment["CHAOS_FIRST"] ?? "1") ?? 1
        let count = UInt64(ProcessInfo.processInfo.environment["CHAOS_COUNT"] ?? "12") ?? 60
        let ops = Int(ProcessInfo.processInfo.environment["CHAOS_OPS"] ?? "22") ?? 22
        var failures: [String] = []
        for seed in first..<(first + count) {
            if let message = try await Self.runOne(seed: seed, ops: ops) {
                failures.append("seed \(seed): \(message)")
                print("CHAOS FAILURE seed \(seed): \(message)")
            }
        }
        print("CHAOS done: \(count) seeds from \(first), \(ops) operations each, \(failures.count) failures")
        #expect(failures.isEmpty)
    }
}
