import Foundation
import Testing
import FridayAudio
import WakeWordKit
@testable import WakeWordCore

@Suite(.timeLimit(.minutes(1)))
struct RuntimeAudioLifecycleTests {
    // MARK: - Microphone interruptions

    @Test func aRouteChangeRestartsCaptureAfterTheDebounceWithoutReloadingTheEngine() async throws {
        let harness = Harness.make()
        try await harness.startListening()

        harness.capture.simulateConfigurationChange()
        try await eventually("debounce armed") { harness.clock.sleeperCount == 1 }
        #expect(harness.capture.startCount == 1, "not before the debounce")
        #expect(!harness.capture.isRunning)

        harness.clock.advance(by: .milliseconds(300))
        try await eventually("capture restarted") { harness.capture.startCount == 2 && harness.capture.isRunning }
        #expect(await harness.runtime.snapshot().state == .listening)
        #expect(harness.factory.engines(id: "alpha").count == 1)
        await harness.runtime.stop()
    }

    @Test func aBurstOfRouteChangesIsCoalescedIntoOneRestart() async throws {
        let harness = Harness.make()
        try await harness.startListening()

        for _ in 0..<3 {
            harness.capture.simulateConfigurationChange()
            try await Task.sleep(for: .milliseconds(10))
        }
        try await eventually("single debounce timer") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .milliseconds(300))
        try await eventually("restarted") { harness.capture.isRunning }
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.capture.startCount == 2)
        await harness.runtime.stop()
    }

    @Test func anInterruptionIsHandledTheSameWay() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        harness.capture.simulateInterruption("another app took the device")
        try await eventually("debounce armed") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .milliseconds(300))
        try await eventually("capture restarted") { harness.capture.isRunning }
        await harness.runtime.stop()
    }

    @Test func aRestartStormBecomesARetryableErrorInsteadOfAnEndlessLoop() async throws {
        let harness = Harness.make()   // maxRestartsInWindow = 4
        try await harness.startListening()

        for round in 1...5 {
            harness.capture.simulateConfigurationChange()
            try await eventually("debounce armed (\(round))") { harness.clock.sleeperCount >= 1 }
            harness.clock.advance(by: .milliseconds(300))
            if round < 5 {
                try await eventually("restart \(round)") { harness.capture.startCount == round + 1 }
            }
        }
        try await harness.runtime.waitForState("error") { if case .error = $0 { true } else { false } }
        let snapshot = await harness.runtime.snapshot()
        #expect(snapshot.retryAt != nil, "it will try again later, with backoff")
        #expect(!harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func aCaptureThatFailsToStartIsRetriedWithBackoffAndRecovers() async throws {
        let harness = Harness.make()
        harness.capture.failNextStarts(with: [.engineFailed("HAL not ready")])
        await harness.runtime.start()
        let snapshot = try await harness.runtime.waitForSnapshot("error with retry") {
            if case .error = $0.state { $0.retryAt != nil } else { false }
        }
        #expect(snapshot.retryAt != nil)
        try await eventually("retry timer armed") { harness.clock.sleeperCount == 1 }

        harness.clock.advance(by: .seconds(5))
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(harness.capture.startCount == 2)
        #expect(harness.factory.engines(id: "alpha").count == 1, "the engine survives a capture failure")
        await harness.runtime.stop()
    }

    // MARK: - Input devices

    @Test func aMissingPreferredMicrophoneFallsBackToTheDefaultWithANoticeAndReturnsWhenItReappears() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.input = .device(uid: "usb-1")
        let harness = Harness.make(settings: settings)
        harness.capture.failNextStarts(with: [.deviceUnavailable(uid: "usb-1")])
        try await harness.startListening()

        #expect(harness.capture.selections == [.device(uid: "usb-1"), .systemDefault])
        let fallback = await harness.runtime.snapshot()
        #expect(fallback.notice?.contains("isn’t connected") == true)

        // The preferred microphone is plugged in: switch back to it.
        harness.devices.set([FakeDevices.builtIn, FakeDevices.usb])
        try await eventually("restart debounce") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .milliseconds(300))
        try await harness.runtime.waitForSnapshot("back on the preferred device") { $0.notice == nil && $0.state == .listening }
        #expect(harness.capture.selections.last == .device(uid: "usb-1"))
        await harness.runtime.stop()
    }

    @Test func changingTheInputSelectionRestartsCaptureOnTheNewDeviceOnly() async throws {
        let harness = Harness.make()
        try await harness.startListening()

        var settings = await harness.runtime.snapshot().settings
        settings.input = .device(uid: "usb-1")
        await harness.runtime.apply(settings)
        try await eventually("capture restarted on the USB microphone") {
            harness.capture.selections == [.systemDefault, .device(uid: "usb-1")]
        }
        #expect(harness.factory.engines(id: "alpha").count == 1)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        await harness.runtime.stop()
    }

    @Test func aChangeOfTheSystemDefaultMicrophoneRestartsCaptureWhenFollowingTheDefault() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        harness.devices.set([FakeDevices.usb, FakeDevices.builtIn], emitting: .defaultInputChanged)
        try await eventually("debounce armed") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .milliseconds(300))
        try await eventually("restarted") { harness.capture.startCount == 2 }
        await harness.runtime.stop()
    }

    @Test func aDefaultChangeIsIgnoredWhenAnExplicitDeviceIsSelected() async throws {
        var settings = RuntimeSettings(engineID: "alpha")
        settings.input = .device(uid: "usb-1")
        let harness = Harness.make(settings: settings)
        try await harness.startListening()
        harness.devices.set([FakeDevices.builtIn, FakeDevices.usb], emitting: .defaultInputChanged)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.clock.sleeperCount == 0)
        #expect(harness.capture.startCount == 1)
        await harness.runtime.stop()
    }

    @Test func withNoMicrophoneAtAllDetectionWaitsAndResumesWhenOneIsConnected() async throws {
        let harness = Harness.make()
        harness.capture.failNextStarts(with: [.noInputDevice])
        await harness.runtime.start()
        try await harness.runtime.waitForState("waiting for a microphone") { $0 == .paused(.noInputDevice) }
        #expect(harness.factory.engines(id: "alpha").count == 1, "the engine stays loaded while waiting")

        harness.devices.set([FakeDevices.builtIn])
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(harness.capture.startCount == 2)
        await harness.runtime.stop()
    }

    // MARK: - Sleep, wake, user switching

    @Test func sleepStopsTheMicrophoneKeepsTheEngineAndWakeResumesAfterDevicesSettle() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        let engine = try #require(harness.factory.latest("alpha"))

        harness.system.send(.willSleep)
        try await harness.runtime.waitForState("sleeping") { $0 == .paused(.systemSleep) }
        #expect(!harness.capture.isRunning)
        #expect(!engine.isShutDown, "waking up must not need the network again")

        harness.system.send(.didWake)
        try await eventually("settle delay armed") { harness.clock.sleeperCount == 1 }
        #expect(await harness.runtime.snapshot().state == .paused(.systemSleep), "devices are given a moment to reappear")
        harness.clock.advance(by: .seconds(1))
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(harness.capture.startCount == 2)
        #expect(harness.factory.engines(id: "alpha").count == 1)
        await harness.runtime.stop()
    }

    @Test func aQuickSleepWakeSleepNeverWakesTheMicrophoneInBetween() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        harness.system.send(.willSleep)
        try await harness.runtime.waitForState("sleeping") { $0 == .paused(.systemSleep) }
        harness.system.send(.didWake)
        try await eventually("settle armed") { harness.clock.sleeperCount == 1 }
        harness.system.send(.willSleep)   // back to sleep before the settle delay elapsed
        try await Task.sleep(for: .milliseconds(30))
        harness.clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await harness.runtime.snapshot().state == .paused(.systemSleep))
        #expect(!harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func userDisabledDetectionStaysOffAcrossSleepAndWake() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        var settings = await harness.runtime.snapshot().settings
        settings.isEnabled = false
        await harness.runtime.apply(settings)
        try await harness.runtime.waitForState("disabled") { $0 == .paused(.userDisabled) }

        harness.system.send(.willSleep)
        harness.system.send(.didWake)
        try await eventually("settle armed") { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.runtime.snapshot().state == .paused(.userDisabled), "waking up must not override the user")
        #expect(!harness.capture.isRunning)
        await harness.runtime.stop()
    }

    @Test func fastUserSwitchingHandsTheMicrophoneAwayAndBack() async throws {
        let harness = Harness.make()
        try await harness.startListening()
        harness.system.send(.userSessionDidResignActive)
        try await harness.runtime.waitForState("inactive session") { $0 == .paused(.userSessionInactive) }
        #expect(!harness.capture.isRunning)
        harness.system.send(.userSessionDidBecomeActive)
        try await harness.runtime.waitForState("listening") { $0 == .listening }
        #expect(harness.capture.isRunning)
        await harness.runtime.stop()
    }
}
