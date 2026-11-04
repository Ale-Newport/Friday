import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

/// An engine whose loading goes on, whatever happens to the task that waits for it, until the test lets it finish (as native model
/// loading does).
final class StubbornEngine: WakeWordEngine, @unchecked Sendable {
    final class Gate: @unchecked Sendable {
        private let state = Protected<(open: Bool, waiting: CheckedContinuation<Void, Never>?)>((false, nil))
        func wait() async {
            await withCheckedContinuation { continuation in
                let opened = state.withLock { state -> Bool in
                    if state.open { return true }
                    state.waiting = continuation
                    return false
                }
                if opened { continuation.resume() }
            }
        }
        func open() {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.open = true
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume()
        }
    }

    let identifier = "alpha"
    let audioRequirements = AudioRequirements(sampleRate: 16_000, frameLength: 512)
    private let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func initialize() async throws(WakeWordError) { await gate.wait() }
    func processAudio(_ frame: AudioFrame) throws(WakeWordError) -> DetectionResult? { nil }
    func updateSensitivity(_ value: Float) throws(WakeWordError) {}
    func shutdown() {}
}

@Suite(.timeLimit(.minutes(1)))
struct RuntimeEngineTests {
    static let token = CredentialKey(engineID: "alpha", name: "token")

    /// A factory whose engines fail initialisation according to a script, one entry per attempt
    /// (`nil` = succeed; the last entry repeats).
    static func scripted(_ attempts: [WakeWordError?], live: Bool = true) -> (EngineFactory, [EngineDescriptor], Protected<Int>) {
        let factory = EngineFactory()
        let counter = Protected(0)
        let descriptor = factory.descriptor(id: "alpha", behavior: {
            let attempt = counter.withLock { value -> Int in defer { value += 1 }; return value }
            var behavior = MockWakeWordEngine.Behavior()
            behavior.initializeError = attempts[min(attempt, attempts.count - 1)]
            behavior.supportsLiveSensitivity = live
            return behavior
        }, credentials: [CredentialRequirement(key: token, title: "Token", explanation: "")], supportsLiveSensitivity: live)
        return (factory, [descriptor], counter)
    }

    // MARK: - Initialisation failures

    @Test func aMissingCredentialIsAnErrorTheUserCanFixAndNothingIsCaptured() async throws {
        let (factory, engines, _) = Self.scripted([.credentialMissing(Self.token)])
        let harness = Harness.make(engines: engines, factory: factory)
        let log = await EventLog(harness.runtime)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }

        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected error"); return }
        #expect(failure.recovery == .needsUserAction(.provideCredential(Self.token)))
        #expect(failure.kind == .engine(.credentialMissing(Self.token)))
        #expect(snapshot.retryAt == nil, "retrying cannot help until the user supplies the key")
        #expect(harness.clock.sleeperCount == 0)
        #expect(harness.capture.startCount == 0)
        try await eventually("the failure logged") { log.events.contains { if case .engineFailed = $0 { true } else { false } } }
        await harness.runtime.stop()
    }

    @Test func savingTheCredentialRebuildsTheEngineAndRecovers() async throws {
        let (factory, engines, counter) = Self.scripted([.credentialMissing(Self.token), nil])
        let harness = Harness.make(engines: engines, factory: factory)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }

        await harness.runtime.credentialsDidChange()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(counter.get() == 2)
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func changedEngineFilesRebuildTheEngineWithoutTouchingTheMicrophone() async throws {
        let factory = EngineFactory()
        let harness = Harness.make(engines: [factory.descriptor(id: "alpha")], factory: factory)
        try await harness.startListening()
        let first = try #require(factory.latest("alpha"))
        let opened = harness.capture.startCount

        await harness.runtime.engineFilesDidChange()           // a voice profile was installed
        try await eventually("a second engine is built and the first released") { factory.engines(id: "alpha").count == 2 && first.isShutDown }
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(factory.latest("alpha") !== first)
        #expect(harness.capture.startCount == opened, "the microphone is not reopened")
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func aProfileThatCannotBeLoadedIsReportedLikeAnyOtherFailureToLoad() async throws {
        let (factory, engines, counter) = Self.scripted([nil, .invalidConfiguration("the profile is not usable"), nil])
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()

        await harness.runtime.engineFilesDidChange()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        #expect(counter.get() == 2)
        await harness.runtime.engineFilesDidChange()           // the person removes the profile
        try await harness.runtime.waitForState("listening again") { $0 == .listening }
        #expect(counter.get() == 3)
        await harness.runtime.stop()
    }

    // MARK: - Reloading the engine and hearing how it went

    @Test func reloadingTheEngineAnswersOnlyOnceTheNewOneIsInPlace() async throws {
        let factory = EngineFactory()
        let harness = Harness.make(engines: [factory.descriptor(id: "alpha")], factory: factory)
        try await harness.startListening()
        let first = try #require(factory.latest("alpha"))

        let outcome = await harness.runtime.reloadEngine()
        #expect(outcome == .loaded)
        #expect(factory.engines(id: "alpha").count == 2 && first.isShutDown, "the answer means: a new engine is the one listening")
        #expect(await harness.runtime.snapshot().state == .listening)
        await harness.runtime.stop()
    }

    @Test func reloadingTheEngineSaysWhyItCouldNotBeBuilt_andALaterReloadRecovers() async throws {
        let (factory, engines, counter) = Self.scripted([nil, .invalidConfiguration("the profile is not usable"), nil])
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()

        let failed = await harness.runtime.reloadEngine()
        guard case .failed(let reason) = failed else { Issue.record("expected a failure, got \(failed)"); return }
        #expect(reason.contains("the profile is not usable"), "\(reason)")
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }

        #expect(await harness.runtime.reloadEngine() == .loaded)
        #expect(counter.get() == 3)
        try await harness.runtime.waitForState("listening again") { $0 == .listening }
        await harness.runtime.stop()
    }

    @Test func reloadingWhileNothingIsListeningSaysSo_andTheEngineIsBuiltFromTheFilesWhenListeningResumes() async throws {
        let factory = EngineFactory()
        let harness = Harness.make(engines: [factory.descriptor(id: "alpha")], factory: factory)
        try await harness.startListening()
        var settings = await harness.runtime.snapshot().settings
        settings.isEnabled = false
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }

        #expect(await harness.runtime.reloadEngine() == .notListening, "nothing is rebuilt while paused, and the caller is not left waiting")
        #expect(factory.engines(id: "alpha").count == 1)

        settings.isEnabled = true
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(factory.engines(id: "alpha").count == 2, "resuming builds the engine from the files as they are now")
        await harness.runtime.stop()
    }

    @Test func aReloadThatIsGivenUpOnReleasesItsCallerAndStillCompletesTheRebuild() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let engines = [factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            // The first engine loads at once; the one built for the reload takes a while.
            if builds.withLock({ value -> Int in defer { value += 1 }; return value }) >= 1 { behavior.initializeDelay = .milliseconds(400) }
            return behavior
        })]
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()

        let waiting = Task { await harness.runtime.reloadEngine() }
        try await eventually("the rebuild to be under way") { builds.get() == 2 }
        waiting.cancel()
        let started = ContinuousClock.now
        let outcome = await waiting.value
        #expect(outcome == .notListening)
        #expect(ContinuousClock.now - started < .milliseconds(300), "giving up does not wait for the engine to finish loading")

        try await eventually("the rebuild to complete anyway") { factory.engines(id: "alpha").count == 2 && factory.latest("alpha")?.isShutDown == false }
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        await harness.runtime.stop()
    }

    @Test func stoppingTheRuntimeAnswersAReloadThatIsStillWaiting() async throws {
        let factory = EngineFactory()
        let builds = Protected(0)
        let engines = [factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            if builds.withLock({ value -> Int in defer { value += 1 }; return value }) >= 1 { behavior.initializeDelay = .seconds(5) }
            return behavior
        })]
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()

        let waiting = Task { await harness.runtime.reloadEngine() }
        try await eventually("the rebuild to be under way") { builds.get() == 2 }
        let started = ContinuousClock.now
        await harness.runtime.stop()
        #expect(await waiting.value == .notListening, "a stopped runtime builds nothing, and nobody waits for it")
        #expect(ContinuousClock.now - started < .seconds(2), "…and it is told at once, not when the engine that was loading is done")
        #expect(await harness.runtime.reloadEngine() == .notListening)
    }

    @Test func stoppingTheRuntimeAnswersAReloadEvenWhenTheEngineLoadingIgnoresCancellation() async throws {
        let gate = StubbornEngine.Gate()
        let builds = Protected(0)
        let descriptor = EngineDescriptor(
            id: "alpha", displayName: "Alpha", summary: "", capabilities: .init(supportsLiveSensitivity: true, reportsConfidence: false),
            makeEngine: { environment in
                let build = builds.withLock { value -> Int in value += 1; return value }
                return build == 1 ? MockWakeWordEngine(sensitivity: environment.sensitivity, identifier: "alpha") : StubbornEngine(gate: gate)
            }
        )
        let harness = Harness.make(engines: [descriptor])
        try await harness.startListening()

        let waiting = Task { await harness.runtime.reloadEngine() }
        try await eventually("the rebuild to be under way") { builds.get() == 2 }
        await harness.runtime.stop()
        // The engine is still "loading" and will not notice that it was cancelled: the answer must come from stopping, not from it finishing.
        let answer = await withTaskGroup(of: EngineReload?.self) { group in
            group.addTask { await waiting.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                gate.open()                                    // (so that nothing is left waiting if the answer never came)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        gate.open()
        #expect(answer == .notListening, "\(String(describing: answer))")
    }

    @Test func twoReloadsAtOnceBothHearTheOutcome() async throws {
        let factory = EngineFactory()
        let harness = Harness.make(engines: [factory.descriptor(id: "alpha")], factory: factory)
        try await harness.startListening()
        async let one = harness.runtime.reloadEngine()
        async let two = harness.runtime.reloadEngine()
        let (a, b) = await (one, two)
        #expect(a == .loaded && b == .loaded)
        await harness.runtime.stop()
    }

    @Test func theAudioTapSeesWhatTheMicrophoneDeliversAndIsReleasedWhenTheRuntimeStops() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let capture = VoiceCapture()
        harness.runtime.setAudioTap { samples, rate in capture.append(samples, sampleRate: rate) }
        harness.capture.push(seconds: 1)
        #expect(abs(capture.seconds - 1) < 0.05, "\(capture.seconds)")

        await harness.runtime.stop()
        let before = capture.sampleCount
        harness.capture.push(seconds: 1)
        #expect(capture.sampleCount == before, "a stopped runtime lets go of the tap")
    }

    @Test func transientFailuresRetryAutomaticallyWithGrowingBackoff() async throws {
        let (factory, engines, counter) = Self.scripted([.networkUnavailable("offline"), .networkUnavailable("offline"), nil])
        let harness = Harness.make(engines: engines, factory: factory)
        await harness.runtime.start()

        let first = try await harness.runtime.waitForSnapshot("first failure") { if case .error = $0.state { $0.retryAt != nil } else { false } }
        #expect(first.retryAt != nil)
        try await eventually("first backoff armed") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .seconds(4))
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.get() == 1, "must not retry before the 5 s backoff has elapsed")

        harness.clock.advance(by: .seconds(1))
        try await eventually("second attempt failed") { counter.get() == 2 }
        try await eventually("second backoff armed") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .seconds(14))
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.get() == 2, "the second delay is 15 s")

        harness.clock.advance(by: .seconds(1))
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(counter.get() == 3)
        #expect(await harness.runtime.snapshot().retryAt == nil)
        await harness.runtime.stop()
    }

    @Test func aLicenceCheckThatFailsWhileOfflineIsAConnectivityProblemNotABadKey() async throws {
        // The engine cannot tell "offline" from "rejected": it reports that the licence check did not complete.
        let (factory, engines, counter) = Self.scripted([.licenceCheckFailed(Self.token, detail: "activation failed"), nil])
        let network = FakeNetwork(online: false)
        let harness = Harness.make(engines: engines, factory: factory, network: network)
        await harness.runtime.start()

        let snapshot = try await harness.runtime.waitForSnapshot("an offline failure with a retry scheduled") {
            if case .error = $0.state { $0.retryAt != nil } else { false }
        }
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .retryAutomatically, "offline: say \"no internet\", not \"your key is wrong\"")
        #expect(failure.kind == .engine(.networkUnavailable("no internet connection")))

        // The moment connectivity returns, Jarvis retries — it does not wait for the back-off timer.
        network.set(true)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(counter.get() == 2)
        #expect(harness.clock.sleeperCount == 0, "no retry timer is left armed")
        await harness.runtime.stop()
    }

    @Test func anUnansweredLicenceCheckWhileOnlineIsNotRetriedOnATimerButCanBeRetriedByHand() async throws {
        let (factory, engines, counter) = Self.scripted([.licenceCheckFailed(Self.token, detail: "activation failed"), nil])
        let harness = Harness.make(engines: engines, factory: factory, network: FakeNetwork(online: true))
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .manualRetryOnly, "online, nothing says it is the network — and nothing says the key is bad either")
        #expect(failure.kind == .engine(.licenceCheckFailed(Self.token, detail: "activation failed")))
        #expect(snapshot.retryAt == nil && harness.clock.sleeperCount == 0, "no timer: it would only repeat the same question")
        #expect(failure.message.contains("internet connection"), "the message says what to check: \(failure.message)")

        await harness.runtime.retry()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(counter.get() == 2)
        await harness.runtime.stop()
    }

    @Test func aMalformedKeyIsNeverBlamedOnTheNetwork() async throws {
        // Rejected locally — the key's own shape is wrong — so being offline explains nothing.
        let (factory, engines, counter) = Self.scripted([.credentialRejected(Self.token, detail: "AccessKey is invalid")])
        let harness = Harness.make(engines: engines, factory: factory, network: FakeNetwork(online: false))
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .needsUserAction(.provideCredential(Self.token)))
        #expect(failure.kind == .engine(.credentialRejected(Self.token, detail: "AccessKey is invalid")))
        #expect(snapshot.retryAt == nil)
        #expect(harness.clock.sleeperCount == 0)

        harness.network.set(true)   // coming online must not trigger a pointless retry either
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.get() == 1)
        await harness.runtime.stop()
    }

    @Test func anInternalFailureWhileOfflineIsStillAManualRetry() async throws {
        let (factory, engines, counter) = Self.scripted([.internalFailure("boom"), nil])
        let harness = Harness.make(engines: engines, factory: factory, network: FakeNetwork(online: false))
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .manualRetryOnly)
        #expect(snapshot.retryAt == nil)
        #expect(harness.clock.sleeperCount == 0)
        harness.network.set(true)
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.get() == 1, "connectivity has nothing to do with a crash inside the engine")
        await harness.runtime.stop()
    }

    @Test func anUnreadableKeychainWaitsForTheUserAndThenRecovers() async throws {
        let (factory, engines, counter) = Self.scripted([.credentialUnreadable(Self.token, detail: "locked"), nil])
        let harness = Harness.make(engines: engines, factory: factory)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .manualRetryOnly, "a timer would re-prompt someone who just declined")
        #expect(failure.message.contains("Keychain"))
        #expect(snapshot.retryAt == nil)
        #expect(harness.clock.sleeperCount == 0)

        await harness.runtime.retry()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(counter.get() == 2)
        await harness.runtime.stop()
    }

    @Test func aNetworkFlapDoesNotResetTheBackoffOfAnAudioFailure() async throws {
        let harness = Harness.make(network: FakeNetwork(online: true))
        harness.capture.failNextStarts(with: Array(repeating: .engineFailed("the audio unit is busy"), count: 5))
        await harness.runtime.start()
        let failed = try await harness.runtime.waitForSnapshot("an audio failure with a retry scheduled") {
            if case .error(let failure) = $0.state, case .audio = failure.kind { $0.retryAt != nil } else { false }
        }
        #expect(failed.retryAt != nil)
        let attempts = harness.capture.startCount

        harness.network.set(false)
        harness.network.set(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.capture.startCount == attempts, "connectivity is unrelated to this failure; its own back-off stands")
        #expect(harness.clock.sleeperCount == 1)
        await harness.runtime.stop()
    }

    @Test func aRejectedKeyWhileOnlineStaysAUserProblemWithNoRetryLoop() async throws {
        let (factory, engines, _) = Self.scripted([.credentialRejected(Self.token, detail: "invalid")])
        let harness = Harness.make(engines: engines, factory: factory, network: FakeNetwork(online: true))
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .needsUserAction(.provideCredential(Self.token)))
        #expect(snapshot.retryAt == nil)
        #expect(harness.clock.sleeperCount == 0)
        await harness.runtime.stop()
    }

    @Test func comingOnlineDoesNotDisturbAHealthyListener() async throws {
        let harness = Harness.make(network: FakeNetwork(online: true))
        try await harness.startListening()
        harness.network.set(false)
        harness.network.set(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.runtime.snapshot().state == .listening)
        #expect(harness.factory.engines(id: "alpha").count == 1, "no needless engine rebuild")
        await harness.runtime.stop()
    }

    @Test func aPermanentFailureWaitsForAManualRetry() async throws {
        let (factory, engines, _) = Self.scripted([.internalFailure("boom"), nil])
        let harness = Harness.make(engines: engines, factory: factory)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        #expect(harness.clock.sleeperCount == 0)

        await harness.runtime.retry()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        await harness.runtime.stop()
    }

    @Test func anUnknownEngineIdentifierIsReportedNotCrashedOn() async throws {
        let harness = Harness.make(settings: RuntimeSettings(engineID: "nonexistent"))
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        #expect(harness.capture.startCount == 0)
        await harness.runtime.stop()
    }

    @Test func anEngineThatFaultsMidRunIsReleasedAndRetried() async throws {
        let factory = EngineFactory()
        let engines = [factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.failFromFrame = (index: 3, error: .processingFailed("corrupt state"))
            return behavior
        })]
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()
        let engine = try #require(factory.latest("alpha"))

        for _ in 0..<5 { harness.capture.push(seconds: 0.2) }
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        #expect(snapshot.retryAt != nil)
        #expect(engine.isShutDown, "a faulted engine must be released, not left half-alive")
        #expect(!harness.capture.isRunning)

        harness.clock.advance(by: .seconds(5))
        try await eventually("a fresh engine was built") { factory.engines(id: "alpha").count == 2 }
        await harness.runtime.stop()
    }

    @Test func aRejectedReplacementCredentialIsReportedNotHiddenByTheOldEngine() async throws {
        // The first key works; the user then saves a different one that the provider rejects.
        let (factory, engines, _) = Self.scripted([nil, .credentialRejected(Self.token, detail: "invalid key")])
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()
        let first = try #require(factory.latest("alpha"))

        await harness.runtime.credentialsDidChange()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error"); return }
        #expect(failure.recovery == .needsUserAction(.provideCredential(Self.token)))
        #expect(first.isShutDown, "the engine built with the old key is released, not left running behind the error")
        #expect(snapshot.notice == nil || snapshot.notice?.contains("sensitivity") != true)
        await harness.runtime.stop()
    }

    // MARK: - Switching engines

    @Test func switchingEnginesSwapsInTheNewOneAndShutsDownTheOldWithoutTouchingTheMicrophone() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let alpha = try #require(harness.factory.latest("alpha"))

        var settings = await harness.runtime.snapshot().settings
        settings.engineID = "beta"
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForSnapshot("beta active") { $0.engine?.id == "beta" && $0.state == .listening }

        let beta = try #require(harness.factory.latest("beta"))
        #expect(alpha.isShutDown)
        #expect(beta.callLog.initializeCalls == 1)
        #expect(harness.capture.startCount == 1, "changing the engine must not reopen the microphone")
        #expect(harness.capture.isRunning)

        // Audio now flows to the new engine only.
        let alphaFrames = alpha.callLog.processCalls
        try await harness.feedFrames(10, engine: beta)
        #expect(beta.callLog.processCalls >= 10)
        #expect(alpha.callLog.processCalls == alphaFrames)
        await harness.runtime.stop()
    }

    @Test func detectionKeepsWorkingAfterAnEngineSwitch() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        var settings = await harness.runtime.snapshot().settings
        settings.engineID = "beta"
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForSnapshot("beta active") { $0.engine?.id == "beta" }

        try await harness.activate(on: "beta")
        try await eventually("assistant called") { harness.assistant.calls.count == 1 }
        #expect(harness.assistant.calls.first?.event.engineID == "beta")
        await harness.runtime.stop()
    }

    @Test func switchingToAnEngineThatCannotStartEndsInErrorAndReleasesTheOldOne() async throws {
        let factory = EngineFactory()
        let engines = [
            factory.descriptor(id: "alpha"),
            factory.descriptor(id: "beta", behavior: {
                var behavior = MockWakeWordEngine.Behavior()
                behavior.initializeError = .credentialMissing(CredentialKey(engineID: "beta", name: "key"))
                return behavior
            }),
        ]
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()
        let alpha = try #require(factory.latest("alpha"))

        var settings = await harness.runtime.snapshot().settings
        settings.engineID = "beta"
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }

        #expect(alpha.isShutDown, "the UI must not claim a different engine than the one that is running")
        #expect(!harness.capture.isRunning)

        // Choosing a working engine again recovers without further ado.
        settings.engineID = "alpha"
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(factory.engines(id: "alpha").count == 2)
        await harness.runtime.stop()
    }

    // MARK: - Sensitivity

    @Test func sensitivityIsAppliedInPlaceWhenTheEngineSupportsIt() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let alpha = try #require(harness.factory.latest("alpha"))

        var settings = await harness.runtime.snapshot().settings
        settings.sensitivity = 0.8
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForSnapshot("sensitivity applied") { $0.engine?.sensitivity == 0.8 }

        #expect(alpha.callLog.sensitivityUpdates == [0.8])
        #expect(harness.factory.engines(id: "alpha").count == 1, "no rebuild needed")
        await harness.runtime.stop()
    }

    @Test func sensitivityRebuildsTheEngineWhenItCannotBeChangedInPlace() async throws {
        let (factory, engines, counter) = Self.scripted([nil], live: false)
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()
        let first = try #require(factory.latest("alpha"))

        var settings = await harness.runtime.snapshot().settings
        settings.sensitivity = 0.9
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForSnapshot("rebuilt at 0.9") { $0.engine?.sensitivity == 0.9 }

        let second = try #require(factory.latest("alpha"))
        #expect(counter.get() == 2)
        #expect(first !== second && first.isShutDown)
        #expect(second.currentSensitivity == 0.9)
        #expect(harness.capture.startCount == 1, "the microphone stays open while the engine is rebuilt")
        await harness.runtime.stop()
    }

    @Test func aFailedRebuildKeepsListeningWithTheCurrentEngineAndSaysSo() async throws {
        let (factory, engines, _) = Self.scripted([nil, .networkUnavailable("offline")], live: false)
        let harness = Harness.make(engines: engines, factory: factory)
        try await harness.startListening()
        let first = try #require(factory.latest("alpha"))

        var settings = await harness.runtime.snapshot().settings
        settings.sensitivity = 0.9
        await harness.runtime.apply(settings)
        let snapshot = try await harness.runtime.waitForSnapshot("notice") { $0.notice != nil }

        #expect(snapshot.state == .listening)
        #expect(snapshot.engine?.sensitivity == 0.5, "still running with the previous value")
        #expect(!first.isShutDown)
        #expect(snapshot.notice?.contains("sensitivity") == true)
        await harness.runtime.stop()
    }

    // MARK: - Enabling and disabling

    @Test func disablingReleasesEverythingAndEnablingBringsItBack() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let first = try #require(harness.factory.latest("alpha"))

        var settings = await harness.runtime.snapshot().settings
        settings.isEnabled = false
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        #expect(!harness.capture.isRunning, "no audio is captured while disabled")
        #expect(first.isShutDown, "models and native handles are released")
        #expect(await harness.runtime.pipelineStatistics().hasEngine == false)
        let snapshot = await harness.runtime.snapshot()
        #expect(snapshot.engine == nil && snapshot.capture == nil)

        settings.isEnabled = true
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(harness.factory.engines(id: "alpha").count == 2)
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func togglingQuicklyNeverLeavesAnEngineOrMicrophoneRunningWhileDisabled() async throws {
        let factory = EngineFactory()
        let engines = [factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.initializeDelay = .milliseconds(60)
            return behavior
        })]
        let harness = Harness.make(engines: engines, factory: factory)
        await harness.runtime.start()

        var settings = await harness.runtime.snapshot().settings
        for _ in 0..<3 {
            settings.isEnabled = false
            await harness.runtime.apply(settings)
            settings.isEnabled = true
            await harness.runtime.apply(settings)
        }
        settings.isEnabled = false
        await harness.runtime.apply(settings)

        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        try await Task.sleep(for: .milliseconds(250))   // let any in-flight initialisation finish
        #expect(!harness.capture.isRunning)
        let allReleased = factory.engines().allSatisfy { $0.isShutDown }
        #expect(allReleased, "every engine ever built has been released")
        await harness.runtime.stop()
    }
}
