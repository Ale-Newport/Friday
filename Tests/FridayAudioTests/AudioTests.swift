import Foundation
import Testing
import WakeWordKit
@testable import FridayAudio

// MARK: - Synthetic source

struct SyntheticAudioSourceTests {
    final class Received: @unchecked Sendable {
        private let state = Protected<[(count: Int, rate: Double, time: HostTime, peak: Float)]>([])
        var chunks: [(count: Int, rate: Double, time: HostTime, peak: Float)] { state.get() }
        var handler: AudioChunkHandler {
            { [state] samples, rate, time in
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                state.withLock { $0.append((samples.count, rate, time, peak)) }
            }
        }
    }

    @Test func manualPushesAreDeliveredSynchronouslyWithAContinuousTimeline() throws {
        let source = SyntheticAudioSource(sampleRate: 48_000)
        let received = Received()
        let info = try source.start(input: .systemDefault, handler: received.handler)
        #expect(info.sampleRate == 48_000 && info.channelCount == 1)
        #expect(source.isRunning)

        source.push([Float](repeating: 0, count: 4_800))
        source.push([Float](repeating: 0, count: 2_400))
        let chunks = received.chunks
        #expect(chunks.map(\.count) == [4_800, 2_400])
        #expect(abs(chunks[1].time.seconds(since: chunks[0].time) - 0.1) < 1e-6, "second chunk starts exactly where the first ended")
    }

    @Test func stoppingEndsDeliveryAndReleasesTheHandler() throws {
        let source = SyntheticAudioSource()
        let received = Received()
        try source.start(input: .systemDefault, handler: received.handler)
        source.stop()
        source.stop()   // idempotent
        source.push([0, 0, 0])
        #expect(received.chunks.isEmpty)
        #expect(!source.isRunning)
        #expect(source.stopCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopWaitsForADeliveryThatIsAlreadyUnderWay() async throws {
        let source = SyntheticAudioSource()
        let insideHandler = DispatchSemaphore(value: 0)
        let letHandlerFinish = DispatchSemaphore(value: 0)
        let handlerFinished = Protected(false)
        let stopReturned = Protected(false)
        try source.start(input: .systemDefault) { _, _, _ in
            insideHandler.signal()
            letHandlerFinish.wait()
            handlerFinished.withLock { $0 = true }
        }
        // Blocking pushes and stops run on their own threads and the test awaits them, so no cooperative thread is
        // parked while the handler is held (#8).
        Thread { source.push([0, 0, 0]) }.start()
        await insideHandler.waitOffPool()   // the handler is running right now

        let stopping = Task {
            await offPool {
                source.stop()
                stopReturned.withLock { $0 = true }
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!stopReturned.get(), "once stop() returns the handler must be finished — a real capture guarantees the same")

        letHandlerFinish.signal()
        await stopping.value
        #expect(handlerFinished.get())
        #expect(!source.isRunning)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHandlerThatStopsTheCaptureFromInsideItsOwnCallbackDoesNotDeadlock() throws {
        let source = SyntheticAudioSource()
        let calls = Protected(0)
        try source.start(input: .systemDefault) { [unowned source] _, _, _ in
            calls.withLock { $0 += 1 }
            source.stop()
        }
        source.push([0, 0, 0])
        source.push([0, 0, 0])   // already stopped: not delivered
        #expect(calls.get() == 1)
        #expect(!source.isRunning)
    }

    @Test func startingAgainReplacesTheRunningCapture() throws {
        let source = SyntheticAudioSource()
        let first = Received(), second = Received()
        try source.start(input: .systemDefault, handler: first.handler)
        try source.start(input: .device(uid: "x"), handler: second.handler)
        source.push([1])
        #expect(first.chunks.isEmpty && second.chunks.count == 1)
        #expect(source.selections == [.systemDefault, .device(uid: "x")])
    }

    @Test func injectedStartFailuresAreThrownInOrderThenClear() throws {
        let source = SyntheticAudioSource()
        source.failNextStarts(with: [.noInputDevice, .engineFailed("x")])
        #expect(throws: AudioCaptureError.noInputDevice) { try source.start(input: .systemDefault, handler: { _, _, _ in }) }
        #expect(throws: AudioCaptureError.engineFailed("x")) { try source.start(input: .systemDefault, handler: { _, _, _ in }) }
        try source.start(input: .systemDefault, handler: { _, _, _ in })
        #expect(source.isRunning)
    }

    @Test func routeChangesStopCaptureAndAreAnnounced() async throws {
        let source = SyntheticAudioSource()
        var events = source.events().makeAsyncIterator()
        try source.start(input: .systemDefault, handler: { _, _, _ in })
        source.simulateConfigurationChange()
        #expect(await events.next() == .configurationChanged)
        #expect(!source.isRunning)

        try source.start(input: .systemDefault, handler: { _, _, _ in })
        source.simulateInterruption("test")
        #expect(await events.next() == .interrupted(reason: "test"))
    }

    @Test func signalsHaveTheRequestedShape() throws {
        let source = SyntheticAudioSource(sampleRate: 48_000)
        let received = Received()
        try source.start(input: .systemDefault, handler: received.handler)

        source.push(seconds: 0.2)                                        // silence by default
        source.setSignal(.tone(frequency: 440, amplitude: 0.5))
        source.push(seconds: 0.2)
        source.setSignal(.whiteNoise(amplitude: 0.1))
        source.push(seconds: 0.2)

        let peaks = received.chunks.map(\.peak)
        #expect(peaks.count == 6)
        #expect(peaks[0] == 0 && peaks[1] == 0)
        #expect(peaks[2] > 0.45 && peaks[2] <= 0.5 && peaks[3] > 0.45 && peaks[3] <= 0.5)
        #expect(peaks[4] > 0.05 && peaks[4] <= 0.1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRIDAY_HEADLESS_CI"] == nil, "real-time pacing is not reliable on shared CI machines"))
    func realTimeGenerationRunsAtTheMicrophonesPace() async throws {
        let source = SyntheticAudioSource(sampleRate: 16_000)
        let received = Received()
        try source.start(input: .systemDefault, handler: received.handler)
        source.beginRealTimeGeneration(chunkDuration: 0.05)
        try await Task.sleep(for: .milliseconds(520))
        source.stop()
        let count = received.chunks.count
        #expect((7...12).contains(count), "expected about 10 chunks in 0.5 s, got \(count)")
        try await Task.sleep(for: .milliseconds(150))
        #expect(received.chunks.count == count, "no chunks after stop()")
    }
}

// MARK: - Devices

struct CoreAudioDeviceCatalogTests {
    @Test func listsTheMacsRealInputDevicesConsistently() {
        let catalog = CoreAudioDeviceCatalog()
        let devices = catalog.inputDevices()
        for device in devices {
            #expect(!device.uid.isEmpty && !device.name.isEmpty)
            #expect(device.inputChannelCount > 0)
            #expect(CoreAudioDeviceCatalog.deviceID(forUID: device.uid) != nil, "\(device.name) must resolve back to a Core Audio object")
        }
        #expect(Set(devices.map(\.uid)).count == devices.count, "UIDs are unique")
        if let defaultDevice = catalog.defaultInputDevice() {
            #expect(devices.contains(defaultDevice), "the default input must be one of the listed inputs")
        }
    }

    @Test func anUnknownUIDDoesNotResolve() {
        #expect(CoreAudioDeviceCatalog.deviceID(forUID: "no-such-device-\(UUID().uuidString)") == nil)
    }

    @Test func changeStreamsCanBeCreatedAndAbandonedSafely() async {
        let catalog = CoreAudioDeviceCatalog()
        let task = Task { for await _ in catalog.changes() {} }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        _ = await task.value
    }
}

// MARK: - Permission and the real capture source's failure paths (no microphone needed)

struct StubPermission: MicrophonePermissionProviding {
    var value: MicrophoneAuthorization
    func status() -> MicrophoneAuthorization { value }
    func request() async -> MicrophoneAuthorization { value }
}

struct CapturePreconditionTests {
    @Test func systemPermissionReportsAKnownState() {
        let status = SystemMicrophonePermission().status()
        #expect([.notDetermined, .authorized, .denied, .restricted].contains(status))
        #expect(MicrophoneAuthorization.authorized.isAuthorized && !MicrophoneAuthorization.denied.isAuthorized)
        #expect(SystemMicrophonePermission.settingsURL.scheme == "x-apple.systempreferences")
    }

    @Test(arguments: [MicrophoneAuthorization.denied, .restricted, .notDetermined])
    func theRealSourceNeverOpensTheMicrophoneWithoutPermission(status: MicrophoneAuthorization) {
        let source = AVAudioEngineCaptureSource(permission: StubPermission(value: status))
        #expect(throws: AudioCaptureError.microphoneNotAuthorized(status)) {
            try source.start(input: .systemDefault, handler: { _, _, _ in })
        }
        #expect(!source.isRunning)
    }

    @Test func aMissingExplicitDeviceIsReportedBeforeAnyAudioEngineIsTouched() {
        let source = AVAudioEngineCaptureSource(permission: StubPermission(value: .authorized))
        let uid = "no-such-device-\(UUID().uuidString)"
        #expect(throws: AudioCaptureError.deviceUnavailable(uid: uid)) {
            try source.start(input: .device(uid: uid), handler: { _, _, _ in })
        }
        #expect(!source.isRunning)
    }

    @Test func stoppingAnIdleSourceIsHarmless() {
        let source = AVAudioEngineCaptureSource(permission: StubPermission(value: .authorized))
        source.stop()
        source.stop()
        #expect(!source.isRunning)
    }

    @Test func errorsDescribeThemselvesForTheUI() {
        #expect(AudioCaptureError.microphoneNotAuthorized(.denied).errorDescription?.contains("turned off") == true)
        #expect(AudioCaptureError.noInputDevice.errorDescription?.contains("No microphone") == true)
        #expect(AudioCaptureError.engineFailed("x").errorDescription?.contains("x") == true)
    }
}
