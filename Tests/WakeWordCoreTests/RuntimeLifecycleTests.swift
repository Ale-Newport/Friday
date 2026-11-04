import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

/// Lifecycle scenarios found by independent review of the runtime's own fixes. Each is a sequence of ordinary
/// events whose outcome used to be wrong; they pin the corrected behaviour.
@Suite(.timeLimit(.minutes(1)))
struct RuntimeLifecycleTests {
    // MARK: - The chosen microphone is never forgotten

    @Test func anEngineRebuildDoesNotForgetThatTheChosenMicrophoneIsStillMissing() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.input = .device(uid: "usb-1")
        let factory = EngineFactory()
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.supportsLiveSensitivity = false          // like Porcupine: any sensitivity change rebuilds
            return behavior
        }, supportsLiveSensitivity: false)
        let harness = Harness.make(settings: settings, engines: [descriptor], factory: factory)
        harness.capture.failNextStarts(with: [.deviceUnavailable(uid: "usb-1")])
        try await harness.startListening()
        #expect(await harness.runtime.snapshot().notice != nil, "on the fallback microphone, with a notice saying so")

        var changed = await harness.runtime.snapshot().settings
        changed.sensitivity = 0.9
        await harness.runtime.apply(changed)
        try await harness.runtime.waitForSnapshot("rebuilt at 0.9") { $0.engine?.sensitivity == 0.9 }
        let afterRebuild = await harness.runtime.snapshot()
        #expect(afterRebuild.notice != nil, "still on the fallback microphone, but the notice is gone: \(String(describing: afterRebuild.notice))")

        harness.devices.set([FakeDevices.builtIn, FakeDevices.usb])    // the chosen microphone is plugged in again
        try await eventually("a restart onto the chosen microphone is scheduled", timeout: .seconds(1)) { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .milliseconds(300))
        try await eventually("back on the chosen microphone") { harness.capture.selections.last == .device(uid: "usb-1") }
        try await harness.runtime.waitForSnapshot("the notice goes away") { $0.notice == nil && $0.state == .listening }
        await harness.runtime.stop()
    }

    @Test func aMicrophoneNoticeAndAnEngineNoticeDoNotEraseEachOther() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.input = .device(uid: "usb-1")
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            behavior.supportsLiveSensitivity = false
            if build == 2 { behavior.initializeError = .networkUnavailable("licence server unreachable") }
            return behavior
        }, supportsLiveSensitivity: false)
        let harness = Harness.make(settings: settings, engines: [descriptor], factory: factory)
        harness.capture.failNextStarts(with: [.deviceUnavailable(uid: "usb-1")])
        try await harness.startListening()

        var changed = await harness.runtime.snapshot().settings
        changed.sensitivity = 0.9
        await harness.runtime.apply(changed)                  // the rebuild fails: an engine notice joins the microphone one
        let both = try await harness.runtime.waitForSnapshot("both notices") { ($0.notice ?? "").contains("sensitivity") }
        #expect(both.notice?.contains("microphone") == true, "the microphone notice survives: \(String(describing: both.notice))")

        harness.clock.advance(by: .seconds(5))                // the retry succeeds: only the engine notice goes
        let after = try await harness.runtime.waitForSnapshot("re-applied") { $0.engine?.sensitivity == 0.9 }
        #expect(after.notice?.contains("microphone") == true && after.notice?.contains("sensitivity") != true)
        await harness.runtime.stop()
    }

    // MARK: - A transient failure on the chosen microphone is retried, a hopeless one is not hammered

    @Test func aTransientStartFailureOnTheChosenMicrophoneIsRetriedLater() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.input = .device(uid: "usb-1")
        let harness = Harness.make(settings: settings)
        harness.capture.failNextStarts(with: [.engineFailed("the audio configuration changed while the microphone was starting")])
        try await harness.startListening()
        #expect(harness.capture.selections == [.device(uid: "usb-1"), .systemDefault], "listening on the default straight away")

        // Nothing else happens — no device event, no route change — but the chosen microphone gets another go.
        try await eventually("a retry of the chosen microphone is armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .seconds(60))
        try await eventually("back on the chosen microphone") { harness.capture.selections.last == .device(uid: "usb-1") }
        try await harness.runtime.waitForSnapshot("the notice goes away") { $0.notice == nil && $0.state == .listening }
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func aChosenMicrophoneThatNeverWorksIsRetriedAFewTimesThenLeftAlone() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.input = .device(uid: "usb-1")
        let harness = Harness.make(settings: settings)
        harness.capture.failStarts(selecting: .device(uid: "usb-1"), with: .engineFailed("cannot share the I/O unit"))
        try await harness.startListening()
        @Sendable func attempts() -> Int { harness.capture.selections.filter { $0 == .device(uid: "usb-1") }.count }
        #expect(attempts() == 1)

        // Three more tries, spaced out; each leaves Jarvis listening on the default microphone.
        for expected in 2...4 {
            try await eventually("a retry is armed") { harness.clock.sleeperCount == 1 }
            harness.clock.advance(by: .seconds(600))
            try await eventually("attempt \(expected)") { attempts() == expected }
            try await eventually("listening on the default again") {
                harness.capture.isRunning && harness.capture.selections.last == .systemDefault
            }
        }

        // The schedule is used up: nothing is armed, and no amount of waiting makes it try again.
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.clock.sleeperCount == 0, "no timer is left running for a microphone that cannot be used")
        harness.clock.advance(by: .seconds(7_200))
        try await Task.sleep(for: .milliseconds(60))
        #expect(attempts() == 4)
        try await harness.runtime.waitForSnapshot("still listening on the default, and saying so") { $0.state == .listening && $0.notice != nil }

        // …but the world changing (here: the device list) is a reason to try once more.
        harness.devices.set([FakeDevices.builtIn, FakeDevices.usb])
        try await eventually("a restart is scheduled") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .milliseconds(300))
        try await eventually("a fifth attempt") { attempts() == 5 }
        await harness.runtime.stop()
    }

    // MARK: - Connectivity that returns during a failing licence check

    @Test func connectivityReturningDuringALicenceCheckIsStillRetried() async throws {
        let key = CredentialKey(engineID: "alpha", name: "token")
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            if build == 1 {
                behavior.initializeDelay = .milliseconds(300)
                behavior.initializeError = .licenceCheckFailed(key, detail: "activation failed")
            }
            return behavior
        })
        let network = FakeNetwork(online: false)
        let harness = Harness.make(engines: [descriptor], factory: factory, network: network)
        await harness.runtime.start()
        try await eventually("the licence check is under way") { builds.get() == 1 }
        network.set(true)                                      // Wi-Fi comes up while the check is failing
        let snapshot = try await harness.runtime.waitForSnapshot("an automatic retry, not a key problem") {
            if case .error(let failure) = $0.state { failure.recovery == .retryAutomatically && $0.retryAt != nil } else { false }
        }
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.kind == .engine(.networkUnavailable("no internet connection")))

        harness.clock.advance(by: .seconds(5))
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        await harness.runtime.stop()
    }

    @Test func anUnansweredLicenceCheckOnlineCanBeRetriedByHand() async throws {
        let key = CredentialKey(engineID: "alpha", name: "token")
        let (factory, engines, counter) = RuntimeEngineTests.scripted([.licenceCheckFailed(key, detail: "activation failed"), nil])
        let harness = Harness.make(engines: engines, factory: factory, network: FakeNetwork(online: true))
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .manualRetryOnly, "the key may be fine (the licence server could be down): retrying is legitimate")
        #expect(snapshot.retryAt == nil)

        let presentation = StatusPresentation(snapshot)
        #expect(presentation.action == .retry && presentation.actionTitle == "Try Again")
        #expect(presentation.title != "Setup needed")

        await harness.runtime.retry()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(counter.get() == 2)
        await harness.runtime.stop()
    }

    // MARK: - A credential change is never lost

    @Test func aCredentialReloadSupersededBySleepIsNotLost() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            if build == 2 { behavior.initializeDelay = .milliseconds(300) }
            return behavior
        })
        let harness = Harness.make(engines: [descriptor], factory: factory)
        try await harness.startListening()
        let first = try #require(factory.latest("alpha"))

        await harness.runtime.credentialsDidChange()          // the user saved a new key: rebuild (300 ms)
        try await eventually("the replacement is loading") { builds.get() >= 2 }
        harness.system.send(.willSleep)                        // …and the lid closes while it loads
        try await harness.runtime.waitForState("paused") { $0 == .paused(.systemSleep) }
        try await Task.sleep(for: .milliseconds(450))          // the replacement finishes while asleep: discarded
        harness.system.send(.didWake)
        try await eventually("wake timer armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .seconds(2))
        try await harness.runtime.waitForState("listening again") { $0 == .listening }

        #expect(first.isShutDown, "the engine built with the OLD credentials is still the one listening")
        await harness.runtime.stop()
    }

    @Test func aCredentialChangeThatArrivesWhileAnEngineIsLoadingIsNotLost() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            if build == 2 { behavior.initializeDelay = .milliseconds(300) }
            return behavior
        })
        let harness = Harness.make(engines: [descriptor], factory: factory)
        try await harness.startListening()

        await harness.runtime.credentialsDidChange()          // first new key: rebuild starts…
        try await eventually("the first replacement is loading") { builds.get() >= 2 }
        await harness.runtime.credentialsDidChange()          // …and the user corrects it before it finishes
        try await eventually("a third engine, built with the latest key", timeout: .seconds(3)) { builds.get() >= 3 }
        try await harness.runtime.waitForSnapshot("settled") { $0.state == .listening }
        let alive = factory.engines(id: "alpha").filter { !$0.isShutDown }
        #expect(alive.count == 1 && alive.first === factory.latest("alpha"), "only the engine built after the last change is left")
        await harness.runtime.stop()
    }

    // MARK: - Back-off

    @Test func aPersistentMidRunFaultBacksOff() async throws {
        let factory = EngineFactory()
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.failFromFrame = (index: 3, error: .processingFailed("corrupt model"))
            return behavior
        })
        let harness = Harness.make(engines: [descriptor], factory: factory)   // back-off: 5 s, then 15 s
        try await harness.startListening()
        var delays: [Int] = []
        for _ in 0..<3 {
            for _ in 0..<5 { harness.capture.push(seconds: 0.2) }
            let snapshot = try await harness.runtime.waitForSnapshot("fault with a retry armed") {
                if case .error = $0.state { $0.retryAt != nil } else { false }
            }
            delays.append(Int((snapshot.retryAt?.timeIntervalSinceNow ?? 0).rounded()))
            try await eventually("timer armed") { harness.clock.sleeperCount >= 1 }
            harness.clock.advance(by: .seconds(60))
            try await harness.runtime.waitForState("listening again") { $0 == .listening }
        }
        #expect(delays == [5, 15, 15], "retry delays were \(delays) s")
        await harness.runtime.stop()
    }

    @Test func aFaultAfterALongHealthyRunStartsTheBackoffOverAgain() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            if build <= 2 { behavior.failFromFrame = (index: 3, error: .processingFailed("glitch")) }   // two quick faults
            return behavior
        })
        let harness = Harness.make(engines: [descriptor], factory: factory)
        try await harness.startListening()
        var delays: [Int] = []
        func faultAndRecover() async throws {
            for _ in 0..<5 { harness.capture.push(seconds: 0.2) }
            let snapshot = try await harness.runtime.waitForSnapshot("fault with a retry armed") {
                if case .error = $0.state { $0.retryAt != nil } else { false }
            }
            delays.append(Int((snapshot.retryAt?.timeIntervalSinceNow ?? 0).rounded()))
            try await eventually("timer armed") { harness.clock.sleeperCount >= 1 }
            harness.clock.advance(by: .seconds(60))
            try await harness.runtime.waitForState("listening again") { $0 == .listening }
        }
        try await faultAndRecover()          // 5 s
        try await faultAndRecover()          // 15 s: it faulted again right after loading

        // The third engine is healthy — for a long while. Then something unrelated goes wrong.
        harness.clock.advance(by: .seconds(600))
        harness.capture.failNextStarts(with: [.engineFailed("HAL not ready")])
        harness.capture.simulateConfigurationChange()
        try await eventually("restart debounce armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .milliseconds(300))
        let snapshot = try await harness.runtime.waitForSnapshot("an audio failure with a retry armed") {
            if case .error(let failure) = $0.state, case .audio = failure.kind { $0.retryAt != nil } else { false }
        }
        delays.append(Int((snapshot.retryAt?.timeIntervalSinceNow ?? 0).rounded()))
        #expect(delays == [5, 15, 5], "a failure after a long healthy run starts again at the shortest delay: \(delays)")
        await harness.runtime.stop()
    }

    @Test func aSensitivityReapplyThatFailsWhileResumingIsStillRetried() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let build = builds.withLock { value -> Int in value += 1; return value }
            var behavior = MockWakeWordEngine.Behavior()
            behavior.supportsLiveSensitivity = false
            if build == 2 { behavior.initializeError = .networkUnavailable("licence server unreachable") }
            return behavior
        }, supportsLiveSensitivity: false)
        let harness = Harness.make(engines: [descriptor], factory: factory)   // the Mac stays online throughout
        try await harness.startListening()

        harness.system.send(.willSleep)
        try await harness.runtime.waitForState("paused") { $0 == .paused(.systemSleep) }
        var changed = await harness.runtime.snapshot().settings
        changed.sensitivity = 0.9
        await harness.runtime.apply(changed)                  // while paused nothing can be rebuilt yet
        harness.system.send(.didWake)
        try await eventually("wake timer armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .seconds(2))
        try await harness.runtime.waitForSnapshot("listening, new sensitivity pending") { $0.state == .listening && $0.notice != nil }

        // The same failure while *listening* arms a retry; it must here too.
        harness.clock.advance(by: .seconds(10))
        try await harness.runtime.waitForSnapshot("the pending sensitivity gets applied", timeout: .seconds(2)) {
            $0.engine?.sensitivity == 0.9
        }
        await harness.runtime.stop()
    }

    // MARK: - News about a microphone session that has already been replaced

    @Test func aStaleCaptureNotificationDoesNotDisownAMicrophoneThatIsAlreadyRunningAgain() async throws {
        let capture = LateEventCapture()
        let clock = ManualClock()
        let factory = EngineFactory()
        let runtime = WakeWordRuntime(
            settings: RuntimeSettings(engineID: "alpha"),
            dependencies: RuntimeDependencies(
                registry: WakeWordEngineRegistry([factory.descriptor(id: "alpha")]), credentials: InMemoryCredentialStore(),
                capture: capture, devices: FakeDevices(), permission: FakePermission(), systemEvents: FakeSystemEvents(),
                assistant: RecordingAssistant(), clock: clock, timings: Harness.fastTimings
            )
        )
        await runtime.start()
        try await runtime.waitForState("listening") { $0 == .listening }

        capture.holdEvents()
        capture.inner.simulateConfigurationChange()           // the source stops itself; the news is held back…
        var settings = await runtime.snapshot().settings
        settings.input = .device(uid: "usb-1")                 // …and meanwhile the user picks another microphone
        await runtime.apply(settings)
        try await eventually("the microphone was reopened") { capture.isRunning && capture.inner.startCount == 2 }
        try await runtime.waitForSnapshot("the snapshot names it") { $0.capture != nil && $0.state == .listening }

        capture.releaseEvents()                                // only now does the old notification arrive
        try await Task.sleep(for: .milliseconds(150))
        let snapshot = await runtime.snapshot()
        #expect(snapshot.capture != nil && capture.isRunning, "the microphone is open, and the snapshot must say so")
        #expect(clock.sleeperCount == 0, "no needless restart of a healthy microphone is armed")
        #expect(capture.inner.startCount == 2)
        await runtime.stop()
    }

    // MARK: - Faults and engines that are already gone

    @Test func aLateFaultReportAfterTheEngineWasReleasedDoesNotReplaceTheRealError() async throws {
        let beta = CredentialKey(engineID: "beta", name: "key")
        let factory = EngineFactory()
        let entered = Protected(false)
        let gate = DispatchSemaphore(value: 0)
        let alpha = factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.failFromFrame = (index: 0, error: .processingFailed("native failure"))
            return behavior
        })
        let blocking = EngineDescriptor(
            id: "beta", displayName: "Beta", summary: "", capabilities: .init(supportsLiveSensitivity: false, reportsConfidence: false),
            makeEngine: { _ throws(WakeWordError) in
                entered.withLock { $0 = true }
                gate.wait()                                   // holds the runtime's executor, like a slow synchronous factory
                throw .credentialMissing(beta)
            }
        )
        let harness = Harness.make(engines: [alpha, blocking], factory: factory)
        try await harness.startListening()

        var changed = await harness.runtime.snapshot().settings
        changed.engineID = "beta"
        await harness.runtime.apply(changed)
        try await eventually("the factory is running") { entered.get() }
        harness.capture.push(seconds: 0.5)                     // the engine in service faults: the report waits in the mailbox
        try await Task.sleep(for: .milliseconds(100))
        gate.signal()                                          // the switch fails, the old engine is released, then the report is handled

        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(150))
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error state"); return }
        #expect(failure.kind == .engine(.credentialMissing(beta)), "the real problem was replaced by: \(failure.message)")
        #expect(snapshot.retryAt == nil, "nothing to retry automatically — the user has to enter a key")
        await harness.runtime.stop()
    }

    @Test func anEngineThatFailedToInitialiseIsShutDownSoItCannotLeakWhatItAllocated() async throws {
        let (factory, engines, _) = RuntimeEngineTests.scripted([.internalFailure("half-built"), nil])
        let harness = Harness.make(engines: engines, factory: factory)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let failed = try #require(factory.engines(id: "alpha").first)
        #expect(failed.isShutDown, "the engine whose initialize() threw must still be told to release what it holds")
        await harness.runtime.stop()
    }
}
