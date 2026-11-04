import Foundation
import Testing
@testable import FridaySpeech

private func tone(seconds: Double, amplitude: Float, rate: Int = 16_000) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { i in amplitude * sin(Float(i) * 2 * .pi * 220 / Float(rate)) }
}

@Suite struct EnergyVADTests {
    @Test func detectsOneUtteranceBetweenSilences() {
        let vad = EnergyVoiceActivityDetector(minimumSilence: 0.5, minimumSpeech: 0.2)
        var audio = tone(seconds: 1.0, amplitude: 0.001)   // room
        audio += tone(seconds: 0.8, amplitude: 0.3)         // speech
        audio += tone(seconds: 1.0, amplitude: 0.001)       // silence closes it
        var active = false
        for chunk in stride(from: 0, to: audio.count, by: 800) {
            vad.accept(Array(audio[chunk..<min(chunk + 800, audio.count)]))
            if vad.isSpeechActive { active = true }
        }
        #expect(active)
        let segments = vad.popSegments()
        #expect(segments.count == 1)
        if let segment = segments.first {
            #expect(segment.samples.count > 10_000 && segment.samples.count < 25_000)
        }
    }

    @Test func ignoresVeryShortBlips() {
        let vad = EnergyVoiceActivityDetector(minimumSilence: 0.4, minimumSpeech: 0.3)
        var audio = tone(seconds: 1.0, amplitude: 0.001)
        audio += tone(seconds: 0.1, amplitude: 0.3)
        audio += tone(seconds: 1.0, amplitude: 0.001)
        vad.accept(audio)
        #expect(vad.popSegments().isEmpty)
    }

    @Test func flushClosesAnOpenSegment() {
        let vad = EnergyVoiceActivityDetector(minimumSilence: 2, minimumSpeech: 0.2)
        vad.accept(tone(seconds: 0.5, amplitude: 0.001) + tone(seconds: 0.6, amplitude: 0.3))
        #expect(vad.isSpeechActive)
        vad.flush()
        #expect(!vad.isSpeechActive)
        #expect(vad.popSegments().count == 1)
    }
}

@Suite struct MicrophoneRecorderTests {
    @Test func resamplesAndKeepsTheLastSeconds() {
        let recorder = MicrophoneRecorder(seconds: 2)
        let input = tone(seconds: 3, amplitude: 0.5, rate: 48_000)
        input.withUnsafeBufferPointer { recorder.tap($0, sampleRate: 48_000) }
        let position = recorder.position
        #expect(abs(position - 48_000) < 400)   // 3 s at 16 kHz, minus the resampler's filter delay
        let tail = recorder.samples(from: position - 1_000, to: position)
        #expect(tail.count == 1_000)
        // Older than the capacity is gone.
        #expect(recorder.samples(from: 0, to: 100).isEmpty)
        let (drained, next) = recorder.drain(since: position - 500)
        #expect(drained.count == 500)
        #expect(next == position)
    }
}
