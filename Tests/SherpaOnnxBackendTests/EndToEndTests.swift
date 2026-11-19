import Foundation
import FridayAudio
import WakeWordCore
import Testing
import WakeWordKit
@testable import SherpaOnnxBackend

/// The whole application core — capture source, resampler, pipeline, validator, state machine, runtime, assistant
/// callback — around the *real* free engine and the Mac's own voices playing the part of the microphone. This is the
/// path a spoken "Jarvis" takes in the app, minus only the hardware.
struct StubDevices: AudioDeviceProviding {
    func inputDevices() -> [AudioInputDevice] { [AudioInputDevice(uid: "builtin", name: "Built-in Microphone", transport: .builtIn, inputChannelCount: 1)] }
    func defaultInputDevice() -> AudioInputDevice? { inputDevices().first }
    func changes() -> AsyncStream<AudioDeviceChange> { AsyncStream { _ in } }
}

struct StubPermission: MicrophonePermissionProviding {
    func status() -> MicrophoneAuthorization { .authorized }
    func request() async -> MicrophoneAuthorization { .authorized }
}

final class CountingAssistant: AssistantActivationHandler, @unchecked Sendable {
    private let events = Protected<[WakeWordEvent]>([])
    var calls: [WakeWordEvent] { events.get() }
    func onWakeWordDetected(_ event: WakeWordEvent, session: ActivationSession) async {
        events.withLock { $0.append(event) }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRIDAY_HEADLESS_CI"] == nil && RealSherpa.isAvailable && RealSherpa.voiceExists("Samantha"), "needs the sherpa files and a macOS voice"))
struct EndToEndTests {
    static let micRate = 48_000.0

    /// Starts the real runtime on a synthetic microphone and returns it, ready and listening.
    static func listening() async throws -> (runtime: WakeWordRuntime, microphone: SyntheticAudioSource, assistant: CountingAssistant) {
        let microphone = SyntheticAudioSource(sampleRate: micRate)
        microphone.setSignal(.whiteNoise(amplitude: 0.003))
        let assistant = CountingAssistant()
        var settings = RuntimeSettings(engineID: SherpaOnnxBackend.engineID)
        settings.cooldown = 1
        settings.postSessionHoldoff = 0.2
        let runtime = WakeWordRuntime(
            settings: settings,
            dependencies: RuntimeDependencies(
                registry: WakeWordEngineRegistry([SherpaOnnxBackend.descriptor]), credentials: InMemoryCredentialStore(),
                resources: RealSherpa.environment.resources, capture: microphone, devices: StubDevices(),
                permission: StubPermission(), assistant: assistant
            )
        )
        await runtime.start()
        let deadline = ContinuousClock.now + .seconds(60)   // an upper bound only: it takes about half a second, but not under a sanitizer on a busy Mac
        while await runtime.snapshot().state != .listening {
            if case .error(let failure) = await runtime.snapshot().state { throw Failed("the runtime failed to start: \(failure.message)") }
            guard ContinuousClock.now < deadline else { throw Failed("the runtime never reached 'listening'") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (runtime, microphone, assistant)
    }

    struct Failed: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }

    /// Plays `samples` into the microphone as it would arrive: 100 ms buffers, room noise before and after.
    static func play(_ samples: [Float], into microphone: SyntheticAudioSource, quietAfter: Double = 2.5, roomNoise: Float = 0.003) {
        microphone.push(seconds: 1.0)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 4_800)
            let noise = RealSherpa.roomNoise(count: end - index, level: roomNoise, seed: UInt64(index))
            microphone.push(zip(samples[index..<end], noise).map { $0 + $1 })
            index = end
        }
        microphone.push(seconds: quietAfter)
    }

    @Test func aSpokenJarvisReachesTheAssistantExactlyOnce() async throws {
        let (runtime, microphone, assistant) = try await Self.listening()
        defer { Task { await runtime.stop() } }
        let speech = try RealSherpa.speech("Hey Jarvis, what time is it?", voice: "Samantha", rate: Int(Self.micRate))
        Self.play(speech, into: microphone)

        let deadline = ContinuousClock.now + .seconds(5)
        while assistant.calls.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))   // and nothing more arrives
        #expect(assistant.calls.count == 1)
        let event = try #require(assistant.calls.first)
        #expect(event.keyword == .jarvis)
        #expect(event.engineID == SherpaOnnxBackend.engineID)
    }

    /// A voice at the level of a microphone across the room (peak −34 dBFS) still reaches the assistant: the level stage works inside
    /// the whole application core, not only on the engine.
    @Test func quietSpeechStillReachesTheAssistant() async throws {
        let (runtime, microphone, assistant) = try await Self.listening()
        defer { Task { await runtime.stop() } }
        let speech = RealSherpa.scaled(try RealSherpa.speech("Hey Jarvis, what time is it?", voice: "Samantha", rate: Int(Self.micRate)), toPeak: 0.02)
        Self.play(speech, into: microphone, roomNoise: 0.0002)

        let deadline = ContinuousClock.now + .seconds(5)
        while assistant.calls.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(assistant.calls.count == 1, "heard at −34 dBFS: \(assistant.calls.count) activation(s)")
    }

    @Test func speechWithoutTheWordNeverReachesTheAssistant() async throws {
        let (runtime, microphone, assistant) = try await Self.listening()
        defer { Task { await runtime.stop() } }
        let speech = try RealSherpa.speech("Several members raised concerns about the budget, while others argued for the project.", voice: "Samantha", rate: Int(Self.micRate))
        Self.play(speech, into: microphone)
        try await Task.sleep(for: .milliseconds(500))
        #expect(assistant.calls.isEmpty)
        #expect(await runtime.snapshot().state == .listening)
    }

    @Test func aQuietRoomKeepsTheNeuralModelIdleEndToEnd() async throws {
        let (runtime, microphone, _) = try await Self.listening()
        defer { Task { await runtime.stop() } }

        /// Average seconds the engine spent per frame between two snapshots of the running statistics.
        func average(from start: DurationStatistics, to end: DurationStatistics) -> Double {
            end.count > start.count ? (end.totalSeconds - start.totalSeconds) / Double(end.count - start.count) : 0
        }

        let beforeQuiet = await runtime.pipelineStatistics()
        microphone.push(seconds: 30)   // thirty seconds of nothing but room noise
        try await Task.sleep(for: .milliseconds(300))
        let afterQuiet = await runtime.pipelineStatistics()
        #expect(afterQuiet.framesProcessed - beforeQuiet.framesProcessed >= 290, "the pipeline still delivered every frame")
        let quiet = average(from: beforeQuiet.engineProcessTime, to: afterQuiet.engineProcessTime)

        // Then three seconds of loud noise, which the model must really work on. The quiet frames must cost a small fraction of
        // these — a ratio, so that the check means the same on a busy Mac or under a sanitizer (about 14 µs against 1.3 ms here).
        microphone.setSignal(.whiteNoise(amplitude: 0.1))
        microphone.push(seconds: 3)
        try await Task.sleep(for: .milliseconds(300))
        let afterLoud = await runtime.pipelineStatistics()
        let loud = average(from: afterQuiet.engineProcessTime, to: afterLoud.engineProcessTime)
        #expect(afterLoud.framesProcessed - afterQuiet.framesProcessed >= 25, "the loud frames were delivered too")
        #expect(quiet * 5 < loud, "a quiet frame costs \(quiet * 1e6) µs, a loud one \(loud * 1e6) µs: the gate keeps the model idle in a quiet room")
    }
}
