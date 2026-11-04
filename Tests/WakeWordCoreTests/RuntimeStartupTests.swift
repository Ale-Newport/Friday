import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

@Suite(.timeLimit(.minutes(1)))
struct RuntimeStartupTests {
    @Test func startsListeningWhenEverythingIsAvailable() async throws {
        let harness = Harness.make()
        try await harness.startListening()

        let snapshot = await harness.runtime.snapshot()
        #expect(snapshot.state == .listening)
        #expect(snapshot.microphone == .authorized)
        #expect(snapshot.engine?.id == "alpha")
        #expect(snapshot.capture?.deviceName == "Synthetic microphone")
        #expect(snapshot.settings.engineID == "alpha")

        #expect(harness.capture.startCount == 1)
        #expect(harness.capture.isRunning)
        let engine = try #require(harness.factory.latest("alpha"))
        #expect(engine.callLog.initializeCalls == 1)
        #expect(await harness.runtime.pipelineStatistics().hasEngine)
        await harness.runtime.stop()
    }

    @Test func theMicrophoneStreamReachesTheEngineAsFixedSizeFrames() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))
        try await harness.feedFrames(40, engine: engine)
        #expect(engine.callLog.processCalls >= 40)
        let statistics = await harness.runtime.pipelineStatistics()
        #expect(statistics.inputSampleRate == 48_000)
        #expect(statistics.framesProcessed >= 40)
        await harness.runtime.stop()
    }

    @Test func asksForMicrophonePermissionOnFirstRunThenListens() async throws {
        let permission = FakePermission(.notDetermined, grantOnRequest: true)
        let harness = Harness.make(permission: permission)
        try await harness.startListening()
        #expect(permission.requests == 1)
        #expect(await harness.runtime.snapshot().microphone == .authorized)
        await harness.runtime.stop()
    }

    @Test func aDeniedPromptIsAnErrorAndNothingIsCaptured() async throws {
        let permission = FakePermission(.notDetermined, grantOnRequest: false)
        let harness = Harness.make(permission: permission)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }

        let snapshot = await harness.runtime.snapshot()
        guard case .error(let failure) = snapshot.state else { Issue.record("expected an error state"); return }
        #expect(failure.kind == .microphonePermission(.denied))
        #expect(snapshot.microphone == .denied)
        #expect(harness.capture.startCount == 0, "the microphone must never be opened without permission")
        #expect(harness.factory.engines().isEmpty, "no model is loaded before there is something to listen with")
        await harness.runtime.stop()
    }

    @Test func grantingAccessInSystemSettingsRecoversWhenTheAppBecomesActive() async throws {
        let permission = FakePermission(.denied)
        let harness = Harness.make(permission: permission)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }

        permission.set(.authorized)
        harness.system.send(.applicationDidBecomeActive)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func revokingAccessWhileListeningStopsTheMicrophone() async throws {
        let permission = FakePermission(.authorized)
        let harness = Harness.make(permission: permission)
        try await harness.startListening()

        permission.set(.denied)
        harness.system.send(.applicationDidBecomeActive)
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        #expect(!harness.capture.isRunning)
        #expect(await harness.runtime.snapshot().microphone == .denied)
        await harness.runtime.stop()
    }

    @Test func startsPausedAndLoadsNothingWhenDisabledInSettings() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.isEnabled = false
        let permission = FakePermission(.notDetermined)
        let harness = Harness.make(settings: settings, permission: permission)
        await harness.runtime.start()
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.capture.startCount == 0)
        #expect(harness.factory.engines().isEmpty)
        #expect(permission.requests == 0, "a disabled app must not even prompt for the microphone")
        await harness.runtime.stop()
    }

    @Test func stopReleasesTheMicrophoneAndTheEngineAndEndsTheStreams() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))
        let snapshots = await harness.runtime.snapshots()

        await harness.runtime.stop()
        #expect(!harness.capture.isRunning)
        #expect(engine.isShutDown)
        #expect(await harness.runtime.pipelineStatistics().hasEngine == false)

        var ended = false
        for await _ in snapshots {}   // a finished stream completes instead of hanging
        ended = true
        #expect(ended)
    }

    @Test func immediateShutdownReleasesTheMicrophoneAndEngineSynchronouslyFromAnyThread() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))
        #expect(harness.capture.isRunning && !engine.isShutDown)

        // No `await`: this is what process termination can rely on.
        harness.runtime.shutdownImmediately()
        #expect(!harness.capture.isRunning)
        #expect(engine.isShutDown)
        #expect(engine.callLog.shutdownCalls == 1)

        // Idempotent, and a later orderly stop is harmless.
        harness.runtime.shutdownImmediately()
        await harness.runtime.stop()
        #expect(engine.callLog.shutdownCalls <= 2)
    }

    @Test func snapshotsStartWithTheCurrentValueAndRevisionsIncrease() async throws {
        let harness = Harness.make()
        await harness.runtime.start()
        try await harness.runtime.waitForState("listening") { $0 == .listening }

        var iterator = await harness.runtime.snapshots().makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.state == .listening)

        await harness.runtime.apply({ var settings = first.settings; settings.sensitivity = 0.9; return settings }())
        let second = try await harness.runtime.waitForSnapshot("newer revision") { $0.revision > first.revision && $0.settings.sensitivity == 0.9 }
        #expect(second.revision > first.revision)
        await harness.runtime.stop()
    }
}
