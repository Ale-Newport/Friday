import Foundation
import Testing
@testable import WakeWordKit

struct VoiceCaptureTests {
    /// `seconds` of a sine at `rate`, as one array.
    static func sine(_ seconds: Double, rate: Double = 48_000, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    static func feed(_ capture: VoiceCapture, _ samples: [Float], rate: Double = 48_000, chunk: Int = 4_800) {
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + chunk)
            samples[index..<end].withUnsafeBufferPointer { capture.append($0, sampleRate: rate) }
            index = end
        }
    }

    @Test func whatTheMicrophoneDeliversIsKeptAtSixteenKilohertz() {
        let capture = VoiceCapture()
        Self.feed(capture, Self.sine(2))
        // The converter's look-ahead holds back a few milliseconds; everything else arrives.
        #expect(abs(capture.seconds - 2) < 0.05, "\(capture.seconds) s")
        #expect(capture.frameCount == capture.sampleCount / VoiceCapture.frameLength)
        #expect(capture.frameCount >= 98)
    }

    @Test func theLevelOfEachFrameIsItsRMSInDecibels() {
        let capture = VoiceCapture()
        Self.feed(capture, Self.sine(1, amplitude: 0.5) + [Float](repeating: 0, count: 48_000))
        let levels = capture.levels()
        #expect(abs(levels[20] - 20 * log10(Float(0.5) / Float(2).squareRoot())) < 0.3, "\(levels[20])")
        #expect(levels[80] < -100, "silence is at the bottom of the scale: \(levels[80])")
        #expect(abs(capture.latestLevelDecibels - levels.last!) < 1e-6)
        #expect(VoiceCapture().latestLevelDecibels == -120, "nothing heard yet")
    }

    @Test func theStoredAudioDoesNotDependOnHowTheMicrophoneChunkedIt() {
        let signal = Self.sine(1.5)
        let a = VoiceCapture(), b = VoiceCapture()
        Self.feed(a, signal, chunk: 4_800)
        Self.feed(b, signal, chunk: 1_117)
        #expect(a.allSamples() == b.allSamples(), "the converter is bit-for-bit independent of the chunking")
    }

    @Test func aMicrophoneThatChangesItsRateKeepsTheRecordingGoing() {
        let capture = VoiceCapture()
        Self.feed(capture, Self.sine(1, rate: 48_000), rate: 48_000)
        let before = capture.seconds
        Self.feed(capture, Self.sine(1, rate: 16_000), rate: 16_000, chunk: 1_600)   // a Bluetooth headset switching to call mode
        #expect(abs(capture.seconds - before - 1) < 0.05, "the second second arrives too: \(capture.seconds)")
    }

    @Test func nonsenseIsIgnoredOrBecomesSilence() {
        let capture = VoiceCapture()
        let tone = Self.sine(0.2)
        for rate in [0.0, -1, .nan, .infinity, 999, 768_001] {
            tone.withUnsafeBufferPointer { capture.append($0, sampleRate: rate) }
        }
        #expect(capture.sampleCount == 0, "a rate that is not one takes nothing")
        capture.append(UnsafeBufferPointer(start: nil, count: 0), sampleRate: 48_000)
        var broken = [Float](repeating: 0.1, count: 4_800)
        broken[10] = .nan; broken[11] = .infinity; broken[12] = 9
        Self.feed(capture, broken)
        #expect(capture.allSamples().allSatisfy { $0.isFinite && abs($0) <= 1 }, "what is stored is audio")
    }

    @Test func itHoldsNoMoreThanItWasGivenRoomFor_andSaysSo() {
        let capture = VoiceCapture(maximumSeconds: 1)
        Self.feed(capture, Self.sine(3))
        #expect(capture.isFull && capture.sampleCount == VoiceCapture.sampleRate, "\(capture.sampleCount)")
        let before = capture.allSamples()
        Self.feed(capture, Self.sine(1))
        #expect(capture.allSamples() == before, "once full it takes nothing more")
    }

    @Test func aClosedCaptureIgnoresALateBufferAndStaysReadable() {
        let capture = VoiceCapture()
        Self.feed(capture, Self.sine(0.5))
        capture.close()
        let kept = capture.allSamples()
        Self.feed(capture, Self.sine(0.5))
        #expect(capture.isClosed && capture.allSamples() == kept)
        #expect(!capture.samples(frames: 0..<10).isEmpty)
    }

    @Test func rangesAreClampedToWhatExists() {
        let capture = VoiceCapture()
        Self.feed(capture, Self.sine(1))
        let count = capture.frameCount
        #expect(capture.samples(frames: -5..<2).count == 2 * VoiceCapture.frameLength)
        #expect(capture.samples(frames: (count - 2)..<(count + 50)).count == 2 * VoiceCapture.frameLength)
        #expect(capture.samples(frames: (count + 5)..<(count + 9)).isEmpty)
        #expect(capture.levels(from: count + 100).isEmpty && capture.levels(from: -3).count == count)
        #expect(abs(capture.peak(frames: 10..<30) - 0.5) < 0.02, "\(capture.peak(frames: 10..<30))")
        #expect(capture.peak(frames: (count + 1)..<(count + 3)) == 0)
    }

    @Test func readingWhileTheMicrophoneWritesIsSafe() async {
        let capture = VoiceCapture(maximumSeconds: 30)
        let writer = Task.detached {
            let signal = Self.sine(0.1)
            for _ in 0..<150 { Self.feed(capture, signal, chunk: 480) }
        }
        var longest = 0
        for _ in 0..<300 {
            longest = max(longest, capture.levels().count)
            _ = capture.samples(frames: 0..<50)
            _ = capture.peak(frames: 0..<50)
            await Task.yield()
        }
        await writer.value
        #expect(capture.frameCount >= longest && capture.frameCount > 500)
    }

    // MARK: The pipeline's audio tap

    @Test func theTapSeesEveryBufferWhetherOrNotAnEngineListens() {
        let (pipeline, _) = WakeWordPipelineTests.makePipeline()
        let capture = VoiceCapture()
        pipeline.setAudioTap { samples, rate in capture.append(samples, sampleRate: rate) }
        Audio.feed(pipeline, seconds: 1, sampleRate: 48_000)   // no engine installed
        #expect(abs(capture.seconds - 1) < 0.05, "\(capture.seconds)")

        let engine = RecordingEngine()
        try? pipeline.install(engine)
        pipeline.setGated(true)
        let before = capture.sampleCount
        Audio.feed(pipeline, seconds: 1, sampleRate: 48_000)   // gated: the engine hears nothing, the tap still does
        #expect(engine.frames.isEmpty)
        #expect(capture.sampleCount - before > 15_000)
    }

    @Test func theTapReceivesTheMicrophonesOwnRateAndSamples() {
        let (pipeline, _) = WakeWordPipelineTests.makePipeline()
        let seen = Protected<[(count: Int, rate: Double, first: Float)]>([])
        pipeline.setAudioTap { samples, rate in seen.withLock { $0.append((samples.count, rate, samples.first ?? 0)) } }
        pipeline.ingest([0.25, 0.5, 0.75, 1.0], sampleRate: 44_100, hostTime: .now)
        let all = seen.get()
        #expect(all.count == 1 && all[0].count == 4 && all[0].rate == 44_100 && all[0].first == 0.25)
    }

    @Test func removingTheTapStopsTheDelivery() {
        let (pipeline, _) = WakeWordPipelineTests.makePipeline()
        let calls = Protected(0)
        pipeline.setAudioTap { _, _ in calls.withLock { $0 += 1 } }
        pipeline.ingest([0.1, 0.2], sampleRate: 48_000, hostTime: .now)
        pipeline.setAudioTap(nil)
        pipeline.ingest([0.1, 0.2], sampleRate: 48_000, hostTime: .now)
        #expect(calls.get() == 1)
    }

    @Test func theTapRunsAfterThePipelinesLockIsReleased() {
        // A tap that asks the pipeline something would deadlock if it were called while the pipeline holds its lock.
        let (pipeline, _) = WakeWordPipelineTests.makePipeline()
        let chunks = Protected<UInt64>(0)
        pipeline.setAudioTap { [unowned pipeline] _, _ in chunks.withLock { $0 = pipeline.statistics().chunksIngested } }
        pipeline.ingest([0.1, 0.2, 0.3], sampleRate: 48_000, hostTime: .now)
        #expect(chunks.get() == 1)
    }

    @Test func aTapDoesNotChangeWhatTheEngineHears() throws {
        func framesHeard(withTap: Bool) throws -> [[Float]] {
            let (pipeline, _) = WakeWordPipelineTests.makePipeline()
            let engine = RecordingEngine()
            try pipeline.install(engine)
            if withTap { pipeline.setAudioTap { _, _ in } }
            Audio.feed(pipeline, seconds: 1, sampleRate: 48_000)
            return engine.frames.map(\.samples)
        }
        #expect(try framesHeard(withTap: true) == framesHeard(withTap: false))
    }
}
