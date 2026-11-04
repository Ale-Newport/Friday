import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

/// Scenarios found by an independent review of the runtime. Each is a sequence of ordinary events whose
/// outcome used to be wrong; they pin the corrected behaviour.
@Suite(.timeLimit(.minutes(1)))
struct RuntimeRegressionTests {
    // MARK: - An engine fault that races a pause

    @Test func anEngineFaultThatArrivesDuringAPauseDoesNotLeaveTheDetectorDeaf() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            if build == 1 { behavior.failFromFrame = (index: 0, error: .processingFailed("native failure")) }
            return behavior
        })
        let capture = RacingCapture()
        let clock = ManualClock()
        let system = FakeSystemEvents()
        let assistant = RecordingAssistant()
        let runtime = WakeWordRuntime(
            settings: RuntimeSettings(engineID: "alpha"),
            dependencies: RuntimeDependencies(
                registry: WakeWordEngineRegistry([descriptor]), credentials: InMemoryCredentialStore(), capture: capture,
                devices: FakeDevices(), permission: FakePermission(), systemEvents: system, assistant: assistant,
                clock: clock, timings: Harness.fastTimings
            )
        )
        await runtime.start()
        try await runtime.waitForState("listening") { $0 == .listening }

        // In-flight audio reaches the failing engine while the pause is closing the microphone, so the
        // pipeline faults *after* the runtime has already moved to `paused`.
        capture.arm { capture.inner.push(seconds: 0.5) }
        system.send(.willSleep)
        try await runtime.waitForState("paused") { $0 == .paused(.systemSleep) }
        try await Task.sleep(for: .milliseconds(100))

        system.send(.didWake)
        try await eventually("wake timer armed") { clock.sleeperCount >= 1 }
        clock.advance(by: .seconds(2))
        try await runtime.waitForState("listening again") { $0 == .listening }

        // The detector must really be alive: a detection reaches the assistant.
        let engine = try #require(factory.latest("alpha"))
        engine.trigger()
        capture.inner.push(seconds: 1.0)
        try await eventually("a detection to reach the assistant") { assistant.calls.count == 1 }
        #expect(factory.engines(id: "alpha").count == 2, "the faulted engine was replaced, not kept")
        await runtime.stop()
    }

    // MARK: - A failure while a replacement engine loads

    @Test func anEngineFaultWhileAReplacementLoadsDoesNotOpenTheMicrophone() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(
            id: "alpha",
            behavior: {
                let build = builds.withLock { value -> Int in value += 1; return value }
                var behavior = MockWakeWordEngine.Behavior()
                behavior.supportsLiveSensitivity = false
                if build == 1 {
                    behavior.failFromFrame = (index: 20, error: .processingFailed("boom"))
                } else {
                    behavior.initializeDelay = .milliseconds(400)
                }
                return behavior
            },
            supportsLiveSensitivity: false
        )
        let harness = Harness.make(engines: [descriptor], factory: factory)
        try await harness.startListening()

        // A sensitivity change starts a replacement engine loading in the background (400 ms)…
        var changed = await harness.runtime.snapshot().settings
        changed.sensitivity = 0.9
        await harness.runtime.apply(changed)
        try await eventually("replacement loading") { builds.get() >= 2 }

        // …and meanwhile the engine in service faults.
        harness.capture.push(seconds: 3.0)
        try await harness.runtime.waitForState("error", timeout: .seconds(3)) { if case .error = $0 { true } else { false } }

        // When the replacement finishes it must be discarded: an error state never holds an open microphone.
        try await Task.sleep(for: .milliseconds(700))
        let later = await harness.runtime.snapshot()
        guard case .error = later.state else { Issue.record("expected to stay in the error state, got \(later.state.label)"); return }
        #expect(!harness.capture.isRunning, "the microphone must stay closed while in an error state")
        #expect(later.engine == nil && later.capture == nil)
        let leaked = factory.engines(id: "alpha").filter { !$0.isShutDown }
        #expect(leaked.isEmpty, "every engine built is released")

        // The automatic retry then recovers.
        harness.clock.advance(by: .seconds(5))
        try await harness.runtime.waitForState("recovery", timeout: .seconds(4)) { $0 == .listening }
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }

    // MARK: - Verifier time-out is a hard limit

    @Test func aVerifierThatIgnoresCancellationStillTimesOutOnTime() async throws {
        let clock = ManualClock()
        let harness = Harness.make(verifiers: [UncancellableVerifier(seconds: 1.5)], clock: clock)
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        try await harness.triggerDetection()
        try await eventually("verifier and its timeout armed") { clock.sleeperCount >= 1 }

        clock.advance(by: .seconds(3))   // the 2 s time-out has elapsed
        // The verifier will not answer for another 1.5 s of real time, but the decision must not wait for it.
        try await eventually("a timed-out rejection", timeout: .milliseconds(700)) {
            log.events.contains { if case .verificationRejected(_, let reason) = $0 { reason.contains("timed out") } else { false } }
        }
        try await harness.runtime.waitForState("back to listening", timeout: .seconds(1)) { $0 == .listening }
        #expect(harness.assistant.calls.isEmpty)
        await harness.runtime.stop()
    }

    // MARK: - An explicit microphone that will not start

    @Test func anExplicitMicrophoneThatCannotBeOpenedFallsBackToTheDefaultWithANotice() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.input = .device(uid: "usb-1")
        let harness = Harness.make(settings: settings)
        // Some input-only devices cannot share the engine's I/O unit and fail to start with a Core Audio status.
        harness.capture.failNextStarts(with: [.engineFailed("could not select the input device (OSStatus -10875)")])
        try await harness.startListening()

        #expect(harness.capture.selections == [.device(uid: "usb-1"), .systemDefault])
        let snapshot = await harness.runtime.snapshot()
        #expect(snapshot.notice?.contains("couldn’t be used") == true)
        await harness.runtime.stop()
    }

    // MARK: - Publishing and back-off hygiene

    @Test func losingTheMicrophonePublishesImmediatelyNotAfterTheDebounce() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        harness.capture.simulateConfigurationChange()
        // No clock advance: the debounce has not elapsed, yet the UI must stop claiming a device.
        try await harness.runtime.waitForSnapshot("capture cleared", timeout: .seconds(1)) { $0.capture == nil }
        await harness.runtime.stop()
    }

    @Test func aRetriedSensitivityReapplyDoesNotKeepAnUnrelatedLaterFailureWaitingLonger() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            behavior.supportsLiveSensitivity = false
            if build == 2 { behavior.initializeError = .networkUnavailable("offline") }   // the first re-apply fails
            return behavior
        }, supportsLiveSensitivity: false)
        let harness = Harness.make(engines: [descriptor], factory: factory)
        try await harness.startListening()

        var changed = await harness.runtime.snapshot().settings
        changed.sensitivity = 0.9
        await harness.runtime.apply(changed)
        try await harness.runtime.waitForSnapshot("a pending re-apply") { $0.notice != nil }
        try await eventually("retry timer armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .seconds(5))
        try await harness.runtime.waitForSnapshot("re-applied") { $0.engine?.sensitivity == 0.9 && $0.notice == nil }

        // The detector then runs for a good while. An unrelated transient failure after that must start from the
        // *shortest* back-off again (5 s), not from where the earlier retry had got to.
        harness.clock.advance(by: .seconds(300))
        harness.capture.failNextStarts(with: [.engineFailed("HAL not ready")])
        harness.capture.simulateConfigurationChange()
        try await eventually("restart debounce armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .milliseconds(300))
        let failed = try await harness.runtime.waitForSnapshot("error with a retry scheduled") { if case .error = $0.state { $0.retryAt != nil } else { false } }
        #expect(Int((failed.retryAt?.timeIntervalSinceNow ?? 0).rounded()) == 5)
        try await eventually("retry timer armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .seconds(5))
        try await harness.runtime.waitForState("recovered after the first back-off step", timeout: .seconds(3)) { $0 == .listening }
        await harness.runtime.stop()
    }
}
