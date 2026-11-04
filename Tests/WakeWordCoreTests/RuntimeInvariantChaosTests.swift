import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

/// Randomised lifecycle abuse with *invariants checked while it runs*, not only at the end — written by an independent
/// reviewer to reach states `RuntimeChaosTests` cannot: engine initialisation that fails in every way an engine can
/// (offline, unanswered licence check, rejected key, internal fault, missing files), a locked or absent Keychain,
/// network flaps, capture start failures, microphone races, interruptions, verifiers that take time or ignore
/// cancellation. While it runs: a paused or failed runtime never has the microphone open; a disabled or
/// engine-failed one has no engine loaded; a promised automatic retry is really armed; a listening one is never
/// deaf (gated) or engine-less; what the snapshot says matches the pipeline and the microphone. At the end, with the
/// world put right, it must settle on what was asked for (engine, sensitivity, chosen microphone, latest
/// credentials) and a triggered detection must really reach the assistant.
///
/// Reproducible: a failure names its seed and the operations that led to it. A deeper run:
///     CHAOS_FIRST=1 CHAOS_COUNT=300 CHAOS_OPS=40 swift test --filter RuntimeInvariantChaosTests
///
/// A credential source that can be unlocked, locked (unreadable) or empty.
final class ScriptedCredentials: CredentialReading, @unchecked Sendable {
    enum Mode: Sendable { case ok, locked, absent }
    private let mode = Protected(Mode.ok)
    func set(_ value: Mode) { mode.withLock { $0 = value } }
    func secret(for key: CredentialKey) -> String? { mode.get() == .ok ? "good-key-value" : nil }
    func accessProblem(for key: CredentialKey) -> String? { mode.get() == .locked ? "the Keychain is locked" : nil }
}

final class ChaosEngines: @unchecked Sendable {
    private let instances = Protected<[MockWakeWordEngine]>([])
    private let failedInit = Protected<Set<ObjectIdentifier>>([])
    var all: [MockWakeWordEngine] { instances.get() }
    var alive: [MockWakeWordEngine] {
        let dead = failedInit.get()
        return instances.get().filter { !$0.isShutDown && !dead.contains(ObjectIdentifier($0)) }
    }
    func latest(_ id: String) -> MockWakeWordEngine? { instances.get().last { $0.identifier == id } }

    static let key = CredentialKey(engineID: "chaos", name: "token")

    func descriptor(id: String, behavior: @escaping @Sendable () -> MockWakeWordEngine.Behavior) -> EngineDescriptor {
        EngineDescriptor(
            id: id, displayName: id, summary: "chaos engine",
            credentials: [CredentialRequirement(key: Self.key, title: "t", explanation: "")],
            capabilities: .init(supportsLiveSensitivity: false, reportsConfidence: false),
            makeEngine: { [weak self] environment throws(WakeWordError) in
                _ = try environment.credentials.requireSecret(for: Self.key)
                let planned = behavior()
                let engine = MockWakeWordEngine(behavior: planned, sensitivity: environment.sensitivity, identifier: id)
                self?.instances.withLock { $0.append(engine) }
                if planned.initializeError != nil { self?.failedInit.withLock { $0.insert(ObjectIdentifier(engine)) } }
                return engine
            }
        )
    }
}

final class ToggleVerifier: DetectionVerifier, @unchecked Sendable {
    private let accepts = Protected(false)
    let clock: ManualClock
    let delay: Duration
    init(clock: ManualClock, delay: Duration) { self.clock = clock; self.delay = delay }
    var requiredPreRoll: Double { 0 }
    func setAccepts(_ value: Bool) { accepts.withLock { $0 = value } }
    func verify(_ context: VerificationContext) async -> VerificationDecision {
        if delay > .zero { try? await clock.sleep(for: delay) }
        return accepts.get() ? .accept : .reject(reason: "no")
    }
}

@Suite(.timeLimit(.minutes(60)))
struct RuntimeInvariantChaosTests {
    static func runOne(seed: UInt64, ops: Int) async throws -> String? {
        var rng = ChaosRandom(seed: seed)
        let engines = ChaosEngines()
        let behaviorRng = Protected(ChaosRandom(seed: seed &+ 99))
        let chaos = Protected(true)
        let key = ChaosEngines.key
        let behavior: @Sendable () -> MockWakeWordEngine.Behavior = {
            var b = MockWakeWordEngine.Behavior()
            b.supportsLiveSensitivity = false
            behaviorRng.withLock { r in
                b.initializeDelay = .milliseconds(r.pick(40))
                guard chaos.get() else { return }
                if r.chance(15) { b.failFromFrame = (index: 5 + r.pick(20), error: .processingFailed("fuzz")) }
                switch r.pick(100) {
                case 0..<8: b.initializeError = .networkUnavailable("offline")
                case 8..<16: b.initializeError = .licenceCheckFailed(key, detail: "activation failed")
                case 16..<20: b.initializeError = .credentialRejected(key, detail: "invalid")
                case 20..<24: b.initializeError = .internalFailure("boom")
                case 24..<27: b.initializeError = .engineUnavailable("files")
                default: break
                }
            }
            return b
        }
        let descriptors = [engines.descriptor(id: "alpha", behavior: behavior), engines.descriptor(id: "beta", behavior: behavior)]
        var settings = RuntimeSettings(engineID: "alpha")
        settings.sessionAudioPolicy = rng.chance(50) ? .releaseMicrophone : .gateDetector
        settings.maxSessionDuration = 30
        let assistant = RecordingAssistant(.holdUntilReleased)
        let clock = ManualClock()
        let credentials = ScriptedCredentials()
        let network = FakeNetwork(online: true)
        let permission = FakePermission()
        let capture = RacingCapture()
        let devices = FakeDevices()
        let system = FakeSystemEvents()
        var verifiers: [any DetectionVerifier] = []
        var toggle: ToggleVerifier?
        switch rng.pick(4) {
        case 0: let v = ToggleVerifier(clock: clock, delay: .milliseconds(900)); v.setAccepts(true); toggle = v; verifiers = [v]
        case 1: let v = ToggleVerifier(clock: clock, delay: .milliseconds(300)); toggle = v; verifiers = [v]
        case 2: verifiers = [UncancellableVerifier(seconds: 0.03)]
        default: break
        }
        let runtime = WakeWordRuntime(
            settings: settings,
            dependencies: RuntimeDependencies(
                registry: WakeWordEngineRegistry(descriptors), credentials: credentials, capture: capture, devices: devices,
                permission: permission, systemEvents: system, network: network, assistant: assistant, verifiers: verifiers,
                clock: clock, timings: Harness.fastTimings
            )
        )
        let log = await EventLog(runtime)
        var trace: [String] = []
        func note(_ s: String) { trace.append(s) }

        // Let the first engine build succeed so the run starts from "listening".
        chaos.withLock { $0 = false }
        await runtime.start()
        do { try await runtime.waitForState("listening") { $0 == .listening } } catch { return "never reached initial listening" }
        chaos.withLock { $0 = true }

        func dump(_ snap: RuntimeSnapshot) -> String {
            "state=\(snap.state.label) notice=\(snap.notice ?? "-") retryAt=\(snap.retryAt != nil) captureRunning=\(capture.isRunning) alive=\(engines.alive.count) verifiers=\(verifiers.count) trace=\(trace.joined(separator: " | "))"
        }

        /// Samples invariants at a quiet moment; a violation must persist (no revision change tolerated) to count.
        func invariantViolation() async -> String? {
            for attempt in 0..<2 {
                let before = await runtime.snapshot()
                let running = capture.isRunning
                let alive = engines.alive.count
                let pipelineStats = await runtime.pipelineStatistics()
                let hasEngine = pipelineStats.hasEngine
                let after = await runtime.snapshot()
                guard before.revision == after.revision else { return nil }   // moving: not a stable sample
                var problem: String?
                switch before.state {
                case .paused:
                    if running { problem = "paused but the microphone is open" }
                    if case .paused(.userDisabled) = before.state, alive > 0 || hasEngine { problem = "disabled but an engine is loaded (alive=\(alive) pipeline=\(hasEngine))" }
                case .error(let failure):
                    if running { problem = "error but the microphone is open" }
                    if failure.isEngineFailure, alive > 0 || hasEngine { problem = "engine failure but an engine is still loaded (alive=\(alive) pipeline=\(hasEngine))" }
                    if failure.recovery == .retryAutomatically, before.retryAt == nil { problem = "automatic retry promised but none armed" }
                case .listening:
                    if pipelineStats.isGated { problem = "listening, but the detector is gated (deaf)" }
                    if !hasEngine { problem = "listening, but the pipeline has no engine" }
                    if before.capture != nil, !running { problem = "listening and the snapshot names a microphone, but it is not running" }
                default: break
                }
                if (before.engine != nil) != hasEngine { problem = "the snapshot says engine=\(before.engine?.id ?? "none") but the pipeline hasEngine=\(hasEngine)" }
                if (before.capture != nil) != running { problem = "the snapshot says capture=\(before.capture?.deviceName ?? "none") but the microphone running=\(running)" }
                if alive > 2 { problem = "\(alive) live engines" }
                guard let problem else { return nil }
                if attempt == 1 { return "\(problem): \(dump(after))" }
                try? await Task.sleep(for: .milliseconds(120))   // let an in-flight load or discard finish, then look again
            }
            return nil
        }

        var current = await runtime.snapshot().settings
        var released = false
        var credentialMark = 0   // engines that existed when the user last saved a credential: a later rebuild must replace them
        for step in 0..<ops {
            let op = rng.pick(42)
            switch op {
            case 0: note("willSleep"); system.send(.willSleep)
            case 1: note("didWake"); system.send(.didWake)
            case 2: note("sessionResign"); system.send(.userSessionDidResignActive)
            case 3: note("sessionActive"); system.send(.userSessionDidBecomeActive)
            case 4: current.isEnabled.toggle(); note("enabled=\(current.isEnabled)"); await runtime.apply(current)
            case 5: current.sensitivity = Float(rng.pick(9) + 1) / 10; note("sens=\(current.sensitivity)"); await runtime.apply(current)
            case 6: current.input = (current.input == .systemDefault) ? .device(uid: "usb-1") : .systemDefault; note("input=\(current.input)"); await runtime.apply(current)
            case 7: current.sessionAudioPolicy = (current.sessionAudioPolicy == .gateDetector) ? .releaseMicrophone : .gateDetector; note("policy=\(current.sessionAudioPolicy)"); await runtime.apply(current)
            case 8: current.engineID = (current.engineID == "alpha") ? "beta" : "alpha"; note("engine=\(current.engineID)"); await runtime.apply(current)
            case 9: note("credentialsDidChange"); credentialMark = engines.all.count; await runtime.credentialsDidChange()
            case 10: note("retry"); await runtime.retry()
            case 11: note("perm denied"); permission.set(.denied); system.send(.applicationDidBecomeActive)
            case 12: note("perm authorized"); permission.set(.authorized); system.send(.applicationDidBecomeActive)
            case 13: note("configChange"); capture.inner.simulateConfigurationChange()
            case 14: note("devices none"); devices.set([], emitting: .deviceListChanged)
            case 15: note("devices builtIn"); devices.set([FakeDevices.builtIn], emitting: .deviceListChanged)
            case 16, 17:
                note("detect")
                if let engine = engines.latest(current.engineID) { engine.trigger() }
                capture.inner.push(seconds: 0.2)
            case 18: note("simulate"); await runtime.simulateWakeWord()
            case 19: note("clock +0.4"); clock.advance(by: .milliseconds(400))
            case 20: note("clock +1.5"); clock.advance(by: .milliseconds(1500))
            case 21: note("clock +6"); clock.advance(by: .seconds(6))
            case 22: if !released && rng.chance(40) { note("assistant release"); assistant.release(); released = true }
            case 23: note("defaultInputChanged"); devices.set([FakeDevices.builtIn], emitting: .defaultInputChanged)
            case 24: note("feed 0.6s"); capture.inner.push(seconds: 0.6)
            case 25: note("feed 1.5s"); capture.inner.push(seconds: 1.5)
            case 26: note("net offline"); network.set(false)
            case 27: note("net online"); network.set(true)
            case 28: note("creds locked"); credentials.set(.locked)
            case 29: note("creds ok"); credentials.set(.ok)
            case 30: note("creds absent"); credentials.set(.absent)
            case 31:
                let errors: [AudioCaptureError] = [.engineFailed("hal"), .noInputDevice, .deviceUnavailable(uid: "usb-1")]
                let pick = errors[rng.pick(errors.count)]
                note("capture fails next start with \(pick)")
                capture.inner.failNextStarts(with: [pick])
            case 32: note("arm race"); capture.arm { capture.inner.push(seconds: 0.5) }
            case 33: note("interruption"); capture.inner.simulateInterruption()
            case 34: note("clock +40"); clock.advance(by: .seconds(40))
            case 35: note("mic may have changed"); await runtime.microphonePermissionMayHaveChanged()
            case 36: note("perm notDetermined"); permission.set(.notDetermined); system.send(.applicationDidBecomeActive)
            case 37: note("creds ok + changed"); credentials.set(.ok); credentialMark = engines.all.count; await runtime.credentialsDidChange()
            case 38: note("clock +0.9"); clock.advance(by: .milliseconds(900))
            case 39: note("devices builtIn+usb"); devices.set([FakeDevices.builtIn, FakeDevices.usb], emitting: .deviceListChanged)
            case 40:
                // Whatever else is going on, a request to rebuild the engine from its files is always answered, and in bounded time.
                note("reloadEngine")
                let answer = await withTaskGroup(of: EngineReload?.self) { group in
                    group.addTask { await runtime.reloadEngine() }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(8))
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                if answer == nil { return "reloadEngine was not answered within 8 s after step \(step)" }
            default: note("feed 0.2s"); capture.inner.push(seconds: 0.2)
            }
            try await Task.sleep(for: .milliseconds(rng.pick(14)))
            if step % 2 == 1, let violation = await invariantViolation() {
                return "INVARIANT after step \(step) (\(trace.last ?? "")): \(violation)"
            }
        }

        // ---- Quiesce: restore the world, using only what the app does by itself, then see where it stands. ----
        note("QUIESCE")
        chaos.withLock { $0 = false }
        toggle?.setAccepts(true)
        capture.inner.failNextStarts(with: [])
        credentials.set(.ok)
        permission.set(.authorized)
        devices.set([FakeDevices.builtIn], emitting: .deviceListChanged)
        system.send(.userSessionDidBecomeActive)
        system.send(.didWake)
        system.send(.applicationDidBecomeActive)
        network.set(false)
        network.set(true)
        assistant.release()
        assistant.behavior = .immediate
        current.isEnabled = true
        let keepChosenMicrophone = current.input == .device(uid: "usb-1") && rng.chance(60)
        if keepChosenMicrophone {
            devices.set([FakeDevices.builtIn, FakeDevices.usb], emitting: .deviceListChanged)   // the chosen microphone is (back) in the list
        } else {
            current.input = .systemDefault
        }
        await runtime.apply(current)
        for _ in 0..<6 {
            clock.advance(by: .seconds(31))
            try await Task.sleep(for: .milliseconds(30))
        }
        var snap = await runtime.snapshot()
        var autoNote = ""
        if case .error(let failure) = snap.state {
            // Only a user action can fix these; the UI offers one, so use it — but note which kind it was.
            autoNote = "needed manual help: \(failure.recovery)"
            if failure.recovery == .retryAutomatically {
                return "automatic recovery did not happen although the world is healthy: \(dump(snap))"
            }
            await runtime.retry()
        }
        // Wait (advancing time) for the app to settle on its own, then check *what* it settled on.
        var settled = false
        for _ in 0..<40 {
            snap = await runtime.snapshot()
            if snap.state == .listening, snap.notice == nil || snap.notice?.hasPrefix("The selected microphone") == true { settled = true; break }
            clock.advance(by: .seconds(31))
            try await Task.sleep(for: .milliseconds(30))
            if case .error = snap.state { await runtime.retry() }
        }
        if settled {
            try await Task.sleep(for: .milliseconds(80))
            snap = await runtime.snapshot()
            if snap.state == .listening {
                if snap.engine?.id != current.engineID { return "settled on engine \(snap.engine?.id ?? "-") but \(current.engineID) was asked for: \(dump(snap))" }
                if snap.engine?.sensitivity != current.sensitivity { return "settled with sensitivity \(snap.engine?.sensitivity ?? -1) but \(current.sensitivity) was asked for (notice=\(snap.notice ?? "-")): \(dump(snap))" }
                if keepChosenMicrophone {
                    // A switch back to the chosen microphone waits out a 300 ms debounce on the manual clock.
                    for _ in 0..<6 where capture.inner.selections.last != .device(uid: "usb-1") {
                        clock.advance(by: .milliseconds(400))
                        try await Task.sleep(for: .milliseconds(40))
                    }
                    snap = await runtime.snapshot()
                }
                if keepChosenMicrophone, capture.inner.selections.last != .device(uid: "usb-1") {
                    return "the chosen microphone is available again but capture runs on \(String(describing: capture.inner.selections.last)) (notice=\(snap.notice ?? "-")): \(dump(snap))"
                }
                if let live = engines.alive.first, let index = engines.all.firstIndex(where: { $0 === live }), index < credentialMark {
                    return "the engine in service (#\(index)) predates the last credential change (#\(credentialMark)): a reload was lost: \(dump(snap))"
                }
            }
        }
        await runtime.credentialsDidChange()   // a fresh engine, without any scripted fault left over from the chaos phase
        for _ in 0..<8 {
            clock.advance(by: .seconds(31))
            try await Task.sleep(for: .milliseconds(30))
            await runtime.retry()
        }
        let reached: Bool
        do { try await runtime.waitForState("listening", timeout: .seconds(4)) { $0 == .listening }; reached = true } catch { reached = false }
        snap = await runtime.snapshot()
        if !reached { return "NOT LISTENING after quiesce (\(autoNote)): \(dump(snap))" }
        if !capture.isRunning { return "listening but capture not running: \(dump(snap))" }
        if snap.capture == nil { return "listening but snapshot.capture nil: \(dump(snap))" }
        let alive = engines.alive
        if alive.count != 1 { return "live engines = \(alive.count) (expected 1): \(dump(snap))" }
        let stats = await runtime.pipelineStatistics()
        if stats.isGated { return "listening but pipeline gated: \(dump(snap))" }
        if !stats.hasEngine { return "listening but pipeline has no engine: \(dump(snap))" }

        // Functional check: the detector is really live.
        let engine = try #require(alive.first)
        let callsBefore = assistant.calls.count
        var frames = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while assistant.calls.count == callsBefore, ContinuousClock.now < deadline {
            let now = await runtime.snapshot()
            if case .verifying = now.state {
                // A verifier is working: give it real time, and (if it waits on the manual clock) one nudge.
                try await Task.sleep(for: .milliseconds(60))
                if case .verifying = await runtime.snapshot().state, toggle != nil { clock.advance(by: .milliseconds(1000)) }
                continue
            }
            if frames % 8 == 0 { engine.trigger() }
            capture.inner.push(seconds: 0.2)
            frames += 1
            try await Task.sleep(for: .milliseconds(3))
        }
        if assistant.calls.count == callsBefore {
            let st = await runtime.pipelineStatistics()
            let rejections = log.events.compactMap { event -> String? in if case .verificationRejected(_, let reason) = event { reason } else { nil } }.suffix(4)
            let detail = "verifier=\(verifiers.map { String(describing: type(of: $0)) }) rejections=\(rejections) processCalls=\(engine.callLog.processCalls) stats: ingested=\(st.chunksIngested) discarded=\(st.chunksDiscarded) frames=\(st.framesProcessed) errors=\(st.engineErrors) accepted=\(st.detectionsAccepted) gated=\(st.isGated) states=\(log.states.suffix(6).map(\.label))"
            return "listening but a triggered detection never reached the assistant (deaf?): \(detail) :: \(dump(snap))"
        }
        try await runtime.waitForState("listening again", timeout: .seconds(3)) { $0 == .listening }

        current.isEnabled = false
        await runtime.apply(current)
        try await Task.sleep(for: .milliseconds(200))
        let off = await runtime.snapshot()
        if off.state != .paused(.userDisabled) { return "disable did not pause: \(dump(off))" }
        if capture.isRunning { return "disabled but capture running: \(dump(off))" }
        if !engines.alive.isEmpty { return "disabled but \(engines.alive.count) engine(s) alive: \(dump(off))" }

        await runtime.stop()
        if capture.isRunning { return "after stop capture running: \(dump(off))" }
        if !engines.alive.isEmpty { return "after stop \(engines.alive.count) engine(s) alive: \(dump(off))" }
        _ = log
        return nil
    }

    @Test func theRuntimeStaysConsistentUnderAnyOrderOfAbuse() async throws {
        let first = UInt64(ProcessInfo.processInfo.environment["CHAOS_FIRST"] ?? "1") ?? 1
        let count = UInt64(ProcessInfo.processInfo.environment["CHAOS_COUNT"] ?? "12") ?? 20
        let ops = Int(ProcessInfo.processInfo.environment["CHAOS_OPS"] ?? "30") ?? 30
        var failures: [String] = []
        for seed in first..<(first + count) {
            if let message = try await Self.runOne(seed: seed, ops: ops) {
                failures.append("seed \(seed): \(message)")
                print("CHAOS (invariants) FAILURE seed \(seed): \(message)")
            }
        }
        print("CHAOS (invariants) done: \(count) seeds from \(first), \(ops) operations each, \(failures.count) failures")
        #expect(failures.isEmpty)
    }
}
