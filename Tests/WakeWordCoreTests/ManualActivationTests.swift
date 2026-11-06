import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

/// `activateManually()`: the hotkey, the menu item and the microphone button must open a session whatever the
/// detector is doing — in particular while the wake word is switched off — and leave the runtime as they found it.
@Suite(.timeLimit(.minutes(1)))
struct ManualActivationTests {
    private func commandSession(_ state: ActivationState) -> Bool {
        if case .commandSession = state { true } else { false }
    }

    @Test func whileTheWakeWordIsOffAPressOpensTheMicrophoneForOneSessionAndPausesAgainAfterwards() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.isEnabled = false
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(settings: settings, assistant: assistant)
        let log = await EventLog(harness.runtime)
        await harness.runtime.start()
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        #expect(harness.capture.startCount == 0)

        let outcome = await harness.runtime.activateManually()
        #expect(outcome == .started)
        try await harness.runtime.waitForState("command session", commandSession)
        #expect(harness.capture.isRunning, "the microphone is open for the session")
        #expect(harness.factory.engines().isEmpty, "no detector model is loaded just to listen once")
        #expect(assistant.calls.count == 1)
        let call = try #require(assistant.calls.first)
        #expect(call.event.engineID == WakeWordRuntime.manualActivationEngineID)

        assistant.release()
        try await harness.runtime.waitForState("paused again") { $0 == .paused(.userDisabled) }
        try await eventually("session ended") { log.sessionOutcomes == [.completed] }
        #expect(!harness.capture.isRunning, "the pause releases the microphone again")
        #expect(harness.factory.engines().isEmpty)
        #expect(await harness.runtime.snapshot().settings.isEnabled == false, "the setting itself is untouched")
        await harness.runtime.stop()
    }

    @Test func whileListeningAPressStartsTheSessionAtOnceAndDetectionResumesAfterwards() async throws {
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(assistant: assistant)
        let log = await EventLog(harness.runtime)
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))

        #expect(await harness.runtime.activateManually() == .started)
        try await harness.runtime.waitForState("command session", commandSession)
        #expect(await harness.runtime.pipelineStatistics().isGated, "the detector is gated during the session")
        assistant.release()
        try await harness.runtime.waitForState("listening again") { $0 == .listening }
        try await eventually("the usual sequence") {
            log.states.map(\.label) == ["listening", "verifying", "wakeWordVerified", "activated", "commandSession", "listening"]
        }
        #expect(await harness.runtime.snapshot().engine?.id == "alpha", "the loaded detector stays")
        #expect(harness.factory.engines().count == 1)
        try await harness.feedFrames(3, engine: engine)   // and it is fed again
        await harness.runtime.stop()
    }

    @Test func aPressDuringASessionDoesNothing() async throws {
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(assistant: assistant)
        try await harness.startListening()
        try await harness.activate()
        try await harness.runtime.waitForState("command session", commandSession)

        #expect(await harness.runtime.activateManually() == .alreadyActive)
        #expect(assistant.calls.count == 1)
        assistant.release()
        await harness.runtime.stop()
    }

    @Test func aDeniedMicrophoneIsReportedAndThePauseIsKept() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.isEnabled = false
        let permission = FakePermission(.denied)
        let harness = Harness.make(settings: settings, permission: permission)
        await harness.runtime.start()
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }

        #expect(await harness.runtime.activateManually() == .failed(.microphone(.denied)))
        #expect(await harness.runtime.snapshot().state == .paused(.userDisabled))
        #expect(harness.capture.startCount == 0)
        #expect(harness.assistant.calls.isEmpty)
        await harness.runtime.stop()
    }

    @Test func thePermissionPromptIsShownForAPressAndARefusalRestoresThePause() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.isEnabled = false
        let permission = FakePermission(.notDetermined, grantOnRequest: false)
        let harness = Harness.make(settings: settings, permission: permission)
        await harness.runtime.start()
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        #expect(permission.requests == 0, "a disabled app does not prompt on its own")

        #expect(await harness.runtime.activateManually() == .failed(.microphone(.denied)))
        #expect(permission.requests == 1)
        try await harness.runtime.waitForState("paused again") { $0 == .paused(.userDisabled) }
        #expect(!harness.capture.isRunning)
        #expect(harness.assistant.calls.isEmpty)
        await harness.runtime.stop()
    }

    @Test func aGrantedPromptLetsTheSessionStart() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.isEnabled = false
        let permission = FakePermission(.notDetermined, grantOnRequest: true)
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(settings: settings, permission: permission, assistant: assistant)
        await harness.runtime.start()
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }

        #expect(await harness.runtime.activateManually() == .started)
        try await harness.runtime.waitForState("command session", commandSession)
        #expect(permission.requests == 1)
        assistant.release()
        try await harness.runtime.waitForState("paused again") { $0 == .paused(.userDisabled) }
        await harness.runtime.stop()
    }

    @Test func aSleepingMacCannotBeActivated() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        harness.system.send(.willSleep)
        try await harness.runtime.waitForState("asleep") { $0 == .paused(.systemSleep) }

        #expect(await harness.runtime.activateManually() == .failed(.paused(.systemSleep)))
        #expect(harness.assistant.calls.isEmpty)
        await harness.runtime.stop()
    }

    @Test func aRuntimeThatIsNotRunningSaysSo() async throws {
        let harness = Harness.make()
        #expect(await harness.runtime.activateManually() == .failed(.notRunning))
        try await harness.startListening()
        await harness.runtime.stop()
        #expect(await harness.runtime.activateManually() == .failed(.notRunning))
    }

    @Test func turningTheWakeWordOnDuringAManualSessionLeavesTheDetectorListeningAfterwards() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.isEnabled = false
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(settings: settings, assistant: assistant)
        await harness.runtime.start()
        try await harness.runtime.waitForState("paused") { $0 == .paused(.userDisabled) }
        #expect(await harness.runtime.activateManually() == .started)
        try await harness.runtime.waitForState("command session", commandSession)

        settings.isEnabled = true
        await harness.runtime.apply(settings)
        assistant.release()
        try await harness.runtime.waitForState("listening with a detector") { $0 == .listening }
        try await harness.runtime.waitForSnapshot("the detector loads after the session") { $0.engine?.id == "alpha" }
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func aFailureAfterWhichTheMicrophoneCameBackIsRetriedByAPress() async throws {
        let permission = FakePermission(.denied)
        let assistant = RecordingAssistant(.holdUntilReleased)
        let harness = Harness.make(permission: permission, assistant: assistant)
        await harness.runtime.start()
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }

        permission.set(.authorized)   // granted in System Settings, but the app has not noticed yet
        #expect(await harness.runtime.activateManually() == .started)
        try await harness.runtime.waitForState("command session", commandSession)
        assistant.release()
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        try await harness.runtime.waitForSnapshot("the detector is loaded afterwards") { $0.engine?.id == "alpha" }
        await harness.runtime.stop()
    }
}
