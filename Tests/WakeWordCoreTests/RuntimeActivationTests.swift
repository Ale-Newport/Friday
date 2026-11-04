import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

extension Harness {
    /// Makes the named engine report a detection on its next frame and feeds audio until it does.
    func triggerDetection(on engineID: String = "alpha") async throws {
        let engine = try #require(factory.latest(engineID))
        engine.trigger()
        // The pipeline gates itself on the very first accepted detection, so exactly one frame is processed.
        try await feedFrames(1, engine: engine)
    }

    func activate(on engineID: String = "alpha") async throws {
        try await triggerDetection(on: engineID)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RuntimeActivationTests {
    // MARK: - The flow

    @Test func aDetectionRunsTheWholeActivationFlowAndReturnsToIdle() async throws {
        let harness = Harness.make()
        let log = await EventLog(harness.runtime)
        try await harness.startListening()

        try await harness.activate()
        try await eventually("session ended") { log.sessionOutcomes == [.completed] }
        try await harness.runtime.waitForState("listening again") { $0 == .listening }

        // The exact sequence from the specification (the initial `initializing` is the starting state, not a change).
        try await eventually("the whole sequence") {
            log.states.map(\.label) == ["listening", "verifying", "wakeWordVerified", "activated", "commandSession", "listening"]
        }

        #expect(harness.assistant.calls.count == 1)
        let call = try #require(harness.assistant.calls.first)
        #expect(call.event.keyword == .jarvis)
        #expect(call.event.engineID == "alpha")
        #expect(log.acceptedDetections.count == 1)
        await harness.runtime.stop()
    }

    @Test func activationReportsMeasuredLatency() async throws {
        let harness = Harness.make()
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        try await harness.activate()
        try await eventually("dispatch event") {
            log.events.contains { if case .activationDispatched = $0 { true } else { false } }
        }
        let dispatched = log.events.compactMap { event -> Double? in
            if case .activationDispatched(_, _, let latency) = event { latency } else { nil }
        }
        let latency = try #require(dispatched.first)
        #expect(latency >= 0 && latency < 2, "audio→dispatch latency should be measured and sane, got \(latency)")
        await harness.runtime.stop()
    }

    @Test func anEngineThatKeepsFiringStillActivatesTheAssistantOnlyOnce() async throws {
        let factory = EngineFactory()
        let engines = [factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.detectEveryNthFrame = 1
            return behavior
        })]
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(engines: engines, factory: factory, assistant: assistant)
        try await harness.startListening()
        let engine = try #require(factory.latest("alpha"))

        harness.capture.push(seconds: 1.0)
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }
        let framesAtActivation = engine.callLog.processCalls
        harness.capture.push(seconds: 2.0)
        try await Task.sleep(for: .milliseconds(30))

        #expect(assistant.calls.count == 1)
        #expect(engine.callLog.processCalls == framesAtActivation, "the engine is not fed while the assistant works")
        assistant.release()
        await harness.runtime.stop()
    }

    @Test func theDetectorIsGatedWhileTheAssistantWorksAndResumesAfterwards() async throws {
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(assistant: assistant)
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))

        try await harness.activate()
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }
        #expect(await harness.runtime.pipelineStatistics().isGated)

        let frames = engine.callLog.processCalls
        harness.capture.push(seconds: 1.0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.callLog.processCalls == frames)

        assistant.release()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(await harness.runtime.pipelineStatistics().isGated == false)
        try await harness.feedFrames(5, engine: engine)
        #expect(engine.callLog.processCalls > frames)
        await harness.runtime.stop()
    }

    @Test func detectionsInsideThePostSessionHoldoffAreIgnoredAndLaterOnesWork() async throws {
        // Detections on engine frames 10, 20 (inside the holdoff after the first session) and 100 (well after).
        let factory = EngineFactory()
        let engines = [factory.descriptor(id: "alpha", behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.detectAtFrames = [10, 20, 100]
            return behavior
        })]
        let harness = Harness.make(engines: engines, factory: factory)
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        let engine = try #require(factory.latest("alpha"))

        // Keep feeding until the engine has seen well past frame 100.
        let deadline = ContinuousClock.now + .seconds(10)
        while engine.callLog.processCalls < 130 {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: "130 frames") }
            harness.capture.push(seconds: 0.1)
            try await Task.sleep(for: .milliseconds(2))
        }
        try await eventually("two activations") { harness.assistant.calls.count == 2 }

        try await eventually("both detections logged (frame 20 falls inside the holdoff)") { log.acceptedDetections.count == 2 }
        try await eventually("the holdoff suppression logged") {
            log.suppressions.contains { if case .holdoff = $0 { true } else { false } }
        }
        await harness.runtime.stop()
    }

    // MARK: - Ending a session

    @Test func aStuckAssistantIsCancelledWhenTheSessionTimesOut() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.maxSessionDuration = 30
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(settings: settings, assistant: assistant)
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        try await harness.activate()
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }

        try await eventually("timeout timer armed") { harness.clock.sleeperCount >= 1 }
        harness.clock.advance(by: .seconds(31))

        try await harness.runtime.waitForState("listening") { $0 == .listening }
        try await eventually("the time-out logged") { log.sessionOutcomes == [.timedOut] }
        try await eventually("handler cancelled") { assistant.cancelledCount == 1 }
        await harness.runtime.stop()
    }

    @Test func theAssistantCanEndTheSessionBeforeItsHandlerReturns() async throws {
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(assistant: assistant)
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        try await harness.activate()
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }

        try #require(assistant.calls.first).session.finish(.completed)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        try await eventually("the completion logged") { log.sessionOutcomes == [.completed] }
        assistant.release()
        await harness.runtime.stop()
    }

    @Test func assistantPhaseUpdatesReachTheSnapshotAndClearWhenTheSessionEnds() async throws {
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(assistant: assistant)
        try await harness.startListening()
        try await harness.activate()
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }

        try #require(assistant.calls.first).session.setPhase(.thinking)
        try await harness.runtime.waitForSnapshot("thinking") { $0.assistantPhase == .thinking }

        assistant.release()
        try await harness.runtime.waitForSnapshot("cleared") { $0.state == .listening && $0.assistantPhase == nil }
        await harness.runtime.stop()
    }

    @Test func disablingDetectionDuringASessionCancelsTheAssistant() async throws {
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(assistant: assistant)
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        try await harness.activate()
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }

        var settings = await harness.runtime.snapshot().settings
        settings.isEnabled = false
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        try await eventually("assistant cancelled") { assistant.cancelledCount == 1 }
        try await eventually("the cancellation logged") { log.sessionOutcomes == [.cancelled] }
        #expect(!harness.capture.isRunning)
        await harness.runtime.stop()
    }

    // MARK: - Verification hook

    @Test func aRejectingVerifierPreventsActivationAndDetectionContinues() async throws {
        let verifier = ScriptedVerifier(decision: .reject(reason: "not the owner"))
        let harness = Harness.make(verifiers: [verifier])
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))

        try await harness.triggerDetection()
        try await eventually("rejection") {
            log.events.contains { if case .verificationRejected = $0 { true } else { false } }
        }
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(harness.assistant.calls.isEmpty)

        let frames = engine.callLog.processCalls
        try await harness.feedFrames(5, engine: engine)
        #expect(engine.callLog.processCalls > frames, "a rejected detection must not leave the detector gated")
        await harness.runtime.stop()
    }

    @Test func aVerifierThatNeverAnswersIsTreatedAsARejection() async throws {
        let clock = ManualClock()
        let slow = ScriptedVerifier(decision: .accept, delay: .seconds(60), clock: clock)
        let harness = Harness.make(verifiers: [slow], clock: clock)
        let log = await EventLog(harness.runtime)
        try await harness.startListening()

        try await harness.triggerDetection()
        try await eventually("verifier and timeout armed") { clock.sleeperCount >= 2 }
        clock.advance(by: .seconds(3))
        try await eventually("timed-out rejection") {
            log.events.contains { if case .verificationRejected(_, let reason) = $0 { reason.contains("timed out") } else { false } }
        }
        #expect(harness.assistant.calls.isEmpty)
        await harness.runtime.stop()
    }

    @Test func aVerifierGetsPreRollAudioOnlyBecauseItAskedForIt() async throws {
        final class Capturing: DetectionVerifier, @unchecked Sendable {
            let requiredPreRoll: Double
            let contexts = Protected<[VerificationContext]>([])
            init(preRoll: Double) { requiredPreRoll = preRoll }
            func verify(_ context: VerificationContext) async -> VerificationDecision {
                contexts.withLock { $0.append(context) }
                return .accept
            }
        }
        let withPreRoll = Capturing(preRoll: 0.5)
        let harness = Harness.make(verifiers: [withPreRoll])
        try await harness.startListening()
        // Feed a second of audio first so the pre-roll buffer is full when the detection happens.
        harness.capture.push(seconds: 1.0)
        try await harness.triggerDetection()
        try await eventually("verifier called") { !withPreRoll.contexts.get().isEmpty }
        let context = try #require(withPreRoll.contexts.get().first)
        #expect(context.sampleRate == 16_000)
        #expect(context.preRoll?.count == 8_000)
        await harness.runtime.stop()

        // Without a verifier asking, nothing is retained at all.
        let plain = Capturing(preRoll: 0)
        let second = Harness.make(verifiers: [plain])
        try await second.startListening()
        second.capture.push(seconds: 1.0)
        try await second.triggerDetection()
        try await eventually("verifier called") { !plain.contexts.get().isEmpty }
        #expect(plain.contexts.get().first?.preRoll == nil)
        await second.runtime.stop()
    }

    // MARK: - Developer and test aids

    @Test func simulatedWakeWordsTakeTheSamePathAsRealOnes() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        await harness.runtime.simulateWakeWord()
        try await eventually("assistant called") { harness.assistant.calls.count == 1 }
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        await harness.runtime.stop()
    }

    @Test func accuracyTestModeStaysOnUntilEveryoneWhoAskedForItHasGivenItBack() async throws {
        let harness = Harness.make()
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))
        let one = await harness.runtime.enterAccuracyTestMode(cooldown: 0.2)
        let other = await harness.runtime.enterAccuracyTestMode(cooldown: 0.2)

        await harness.runtime.leaveAccuracyTestMode(one)
        await harness.runtime.leaveAccuracyTestMode(one)          // a second time: nothing more happens, and the other’s claim stands
        engine.trigger()
        try await harness.feedFrames(40, engine: engine)
        try await eventually("the detection counted") { log.acceptedDetections.count == 1 }
        #expect(harness.assistant.calls.isEmpty, "one test ending must not wake the assistant in the middle of another")

        await harness.runtime.leaveAccuracyTestMode(other)
        try await harness.triggerDetection()
        try await eventually("real activation again") { harness.assistant.calls.count == 1 }
        await harness.runtime.stop()
    }

    @Test func accuracyTestModeCountsDetectionsWithoutActivatingAnything() async throws {
        let harness = Harness.make()
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        let lease = await harness.runtime.enterAccuracyTestMode(cooldown: 0.2)
        let engine = try #require(harness.factory.latest("alpha"))

        for _ in 0..<3 {
            engine.trigger()
            try await harness.feedFrames(40, engine: engine)   // 1.3 s: clear of both the cooldown and the debounce window
        }
        try await eventually("three detections") { log.acceptedDetections.count == 3 }
        #expect(harness.assistant.calls.isEmpty)
        #expect(await harness.runtime.snapshot().state == .listening)
        #expect(await harness.runtime.pipelineStatistics().isGated == false)

        await harness.runtime.leaveAccuracyTestMode(lease)
        try await harness.triggerDetection()
        try await eventually("real activation again") { harness.assistant.calls.count == 1 }
        await harness.runtime.stop()
    }

    // MARK: - Microphone ownership during a session

    @Test func pausingMidSessionWithTheReleasePolicyDoesNotStrandTheMicrophone() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.sessionAudioPolicy = .releaseMicrophone
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(settings: settings, assistant: assistant)
        try await harness.startListening()
        try await harness.activate()
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }
        #expect(!harness.capture.isRunning, "the assistant has the microphone")

        // The user turns detection off while the assistant is mid-session, then back on.
        settings.isEnabled = false
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        settings.isEnabled = true
        await harness.runtime.apply(settings)

        try await harness.runtime.waitForState("listening again") { $0 == .listening }
        #expect(harness.capture.isRunning, "re-enabling must reopen the microphone the session had closed")
        assistant.release()
        await harness.runtime.stop()
    }


    @Test func theReleaseMicrophonePolicyClosesTheInputDuringTheSessionAndReopensItAfter() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.sessionAudioPolicy = .releaseMicrophone
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(settings: settings, assistant: assistant)
        try await harness.startListening()
        try await harness.activate()
        try await harness.runtime.waitForState("command session") { if case .commandSession = $0 { true } else { false } }

        #expect(!harness.capture.isRunning, "the assistant has the microphone to itself")
        #expect(await harness.runtime.snapshot().capture == nil)

        assistant.release()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        try await eventually("microphone reopened") { harness.capture.isRunning }
        #expect(harness.capture.startCount == 2)
        await harness.runtime.stop()
    }
}
