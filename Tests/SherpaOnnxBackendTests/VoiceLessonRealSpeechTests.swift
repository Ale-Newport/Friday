import Foundation
import FridayAudio
import WakeWordCore
import Testing
import WakeWordKit
@testable import SherpaOnnxBackend

/// A whole voice lesson on the real engine, with the Mac's own voice at the level of a MacBook's microphone as the person: phrases,
/// pauses, a paragraph read aloud. The lesson's own trainer is a stand-in that keeps what it is given; what is checked is everything
/// before the analysis — that real speech is told apart from the room, counted phrase by phrase, cut out with its margins, and that
/// detection goes on meanwhile without ever waking the assistant.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRIDAY_HEADLESS_CI"] == nil && RealSherpa.isAvailable && RealSherpa.voiceExists("Samantha"), "needs the sherpa files and a macOS voice"), .timeLimit(.minutes(3)))
struct VoiceLessonRealSpeechTests {
    final class Keeper: @unchecked Sendable {
        let recordings = Protected<[VoiceRecordings]>([])
        var trainer: VoiceTrainer {
            VoiceTrainer(
                learn: { [recordings] heard, _, _ in
                    recordings.withLock { $0.append(heard) }
                    return VoiceTrainingReport(verdict: .notImproved(reason: "stand-in"))
                },
                install: { _ in VoiceProfileChange() },
                revert: { _ in },
                currentProfile: { nil },
                removeProfile: { nil }
            )
        }
    }

    static let script = VoiceLessonScript(
        steps: [
            .init(id: "jarvis", title: "Say Jarvis", instruction: "", prompts: ["Jarvis"], kind: .phrases(count: 4, maximumSeconds: 3)),
            .init(id: "hey-jarvis", title: "Call it", instruction: "", prompts: ["Hey Jarvis", "Okay Jarvis"], kind: .phrases(count: 3, maximumSeconds: 4)),
            .init(id: "talk", title: "Talk", instruction: "", prompts: ["Read."], kind: .reading(targetSeconds: 5, minimumSeconds: 3)),
        ],
        calibrationSeconds: 1
    )

    /// What a MacBook's microphone delivers of the voice at arm's length: a peak of −22 dBFS, in a room at −60 dBFS.
    static func said(_ text: String) throws -> [Float] {
        RealSherpa.scaled(try RealSherpa.speech(text, voice: "Samantha", rate: Int(EndToEndTests.micRate)), toPeak: 0.08)
    }

    static func play(_ samples: [Float], into microphone: SyntheticAudioSource, pause: Double = 1.1) {
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 4_800)
            let noise = RealSherpa.roomNoise(count: end - index, level: 0.002, seed: UInt64(index))
            microphone.push(zip(samples[index..<end], noise).map { $0 + $1 })
            index = end
        }
        microphone.setSignal(.whiteNoise(amplitude: 0.002))
        microphone.push(seconds: pause)
    }

    @Test func realSpeechIsCountedPhraseByPhrase_andDetectionGoesOnWithoutWakingTheAssistant() async throws {
        let (runtime, microphone, assistant) = try await EndToEndTests.listening()
        microphone.setSignal(.whiteNoise(amplitude: 0.002))
        let keeper = Keeper()
        let lesson = VoiceLesson(script: Self.script, runtime: runtime, trainer: keeper.trainer, environment: { RealSherpa.environment })
        let detections = Protected(0)
        let events = await runtime.events()
        let watcher = Task { for await event in events { if case .detectionAccepted = event { detections.withLock { $0 += 1 } } } }
        defer { watcher.cancel() }

        await lesson.begin()
        microphone.push(seconds: 1.3)                                      // the room, to learn what is quiet
        try await eventually("the first step") { await lesson.currentState().phase == .recording }

        for _ in 0..<4 { Self.play(try Self.said("Jarvis"), into: microphone) }
        for text in ["Hey Jarvis", "Okay Jarvis", "Hey Jarvis"] { Self.play(try Self.said(text), into: microphone) }
        Self.play(try Self.said("This morning I walked to the market and bought bread, tomatoes and a little cheese for lunch."), into: microphone, pause: 0.6)
        Self.play(try Self.said("After lunch we went for a long walk along the river until the lights of the bridge came on."), into: microphone, pause: 1.0)
        try await eventually("everything recorded", timeout: .seconds(30)) { await lesson.currentState().phase == .readyToLearn }

        await lesson.startLearning()
        try await eventually("the recordings handed over") { keeper.recordings.get().count == 1 }
        let heard = keeper.recordings.get()[0]
        #expect(heard.utterances.map(\.source) == ["jarvis", "jarvis", "jarvis", "jarvis", "hey-jarvis", "hey-jarvis", "hey-jarvis"], "\(heard.utterances.map(\.source))")
        for utterance in heard.utterances {
            let seconds = Double(utterance.samples.count) / Double(VoiceRecordings.sampleRate)
            #expect(seconds > 0.9 && seconds < 3.5, "a phrase with a little room around it: \(seconds) s (\(utterance.source))")
        }
        let talked = Double(heard.ordinaryTalk.reduce(0) { $0 + $1.count }) / Double(VoiceRecordings.sampleRate)
        #expect(talked > 5, "the talk: \(talked) s")

        // The real engine heard the name in the meantime — and the assistant was never woken.
        try await Task.sleep(for: .milliseconds(200))
        #expect(detections.get() >= 1, "the engine went on listening: \(detections.get()) detection(s) reported")
        #expect(assistant.calls.isEmpty, "…without waking the assistant")

        // Afterwards, detection is back to normal.
        await lesson.cancel()
        Self.play(try RealSherpa.speech("Jarvis", voice: "Samantha", rate: Int(EndToEndTests.micRate)), into: microphone, pause: 2.5)
        try await eventually("the assistant woken at last") { !assistant.calls.isEmpty }
        await runtime.stop()
    }
}
