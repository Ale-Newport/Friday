import Foundation
import Testing
import WakeWordKit
@testable import FridayAudio

/// The injection wrapper replaces microphone chunks with queued audio at the capture's own rate and cadence.
struct InjectableCaptureSourceTests {
    final class Chunks: @unchecked Sendable {
        private let state = Protected<[[Float]]>([])
        var all: [[Float]] { state.withLock { $0 } }
        func append(_ chunk: [Float]) { state.withLock { $0.append(chunk) } }
    }

    @Test func passesMicrophoneThroughWhenNothingIsQueued() throws {
        let inner = SyntheticAudioSource(sampleRate: 16_000)
        let source = InjectableCaptureSource(wrapping: inner)
        let received = Chunks()
        try source.start(input: .systemDefault) { samples, _, _ in received.append(Array(samples)) }
        inner.push([Float](repeating: 0.25, count: 320))
        #expect(received.all.count == 1)
        #expect(received.all.first?.allSatisfy { $0 == 0.25 } == true)
        #expect(!source.isInjecting)
        source.stop()
    }

    @Test func replacesMicrophoneChunksUntilTheQueueIsDrained() throws {
        let inner = SyntheticAudioSource(sampleRate: 16_000)
        let source = InjectableCaptureSource(wrapping: inner)
        let received = Chunks()
        try source.start(input: .systemDefault) { samples, _, _ in received.append(Array(samples)) }
        #expect(source.captureSampleRate == 16_000)
        let done = Protected(false)
        // 480 samples of 0.5 at 16 kHz, no padding: exactly one and a half 320-sample microphone chunks.
        let queued = source.inject([Float](repeating: 0.5, count: 480), sampleRate: 16_000, leadingSilence: 0, trailingSilence: 0) { done.withLock { $0 = true } }
        #expect(queued)
        #expect(source.isInjecting)
        let mic = [Float](repeating: 0.1, count: 320)
        inner.push(mic)  // whole chunk replaced
        inner.push(mic)  // half replaced, half zero-padded
        inner.push(mic)  // queue empty: microphone again, completion fires
        let chunks = received.all
        #expect(chunks.count == 3)
        #expect(chunks[0].allSatisfy { $0 == 0.5 })
        #expect(chunks[1].prefix(160).allSatisfy { $0 == 0.5 })
        #expect(chunks[1].suffix(160).allSatisfy { $0 == 0 })
        #expect(chunks[2].allSatisfy { $0 == 0.1 })
        #expect(!source.isInjecting)
        #expect(done.withLock { $0 })
        source.stop()
    }

    @Test func resamplesToTheCaptureRateAndPadsWithSilence() throws {
        let inner = SyntheticAudioSource(sampleRate: 48_000)
        let source = InjectableCaptureSource(wrapping: inner)
        let received = Chunks()
        try source.start(input: .systemDefault) { samples, _, _ in received.append(Array(samples)) }
        // 0.1 s of a 440 Hz tone at 16 kHz → 0.1 s at 48 kHz, plus 0.05 s lead and 0.05 s tail of silence.
        let tone = (0..<1_600).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) * 0.5 }
        #expect(source.inject(tone, sampleRate: 16_000, leadingSilence: 0.05, trailingSilence: 0.05))
        // 0.2 s of injected audio (plus the resampler's flushed tail) in 48 kHz chunks of 4 800 samples (100 ms):
        // it spans two chunks and spills a little into the third; the fourth is the microphone again.
        for _ in 0..<4 { inner.push([Float](repeating: 0.9, count: 4_800)) }
        let chunks = received.all
        #expect(chunks.count == 4)
        // Lead-in silence, then the tone (non-zero), in the first chunk.
        #expect(chunks[0].prefix(2_000).allSatisfy { $0 == 0 })
        #expect(chunks[0].suffix(2_000).contains { abs($0) > 0.1 })
        // Nothing of the microphone's 0.9 level leaks while injecting.
        #expect(!chunks[0].contains { $0 == 0.9 })
        #expect(!chunks[1].contains { $0 == 0.9 })
        #expect(!chunks[2].contains { $0 == 0.9 })
        #expect(chunks[3].allSatisfy { $0 == 0.9 })
        source.stop()
    }

    @Test func injectionFailsWhenNotRunning() {
        let source = InjectableCaptureSource(wrapping: SyntheticAudioSource(sampleRate: 16_000))
        #expect(!source.inject([0, 0, 0], sampleRate: 16_000))
    }
}
