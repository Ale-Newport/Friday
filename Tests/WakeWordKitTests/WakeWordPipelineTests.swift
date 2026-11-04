import Foundation
import Testing
@testable import WakeWordKit

struct WakeWordPipelineTests {
    static func makePipeline(
        validation: DetectionValidator.Configuration = .init(cooldown: 2, debounceWindow: 0.6),
        gateOnAccepted: Bool = true,
        maxFailures: Int = 5
    ) -> (WakeWordPipeline, EventCollector) {
        let collector = EventCollector()
        let pipeline = WakeWordPipeline(
            configuration: .init(validation: validation, gateOnAcceptedDetection: gateOnAccepted, maxConsecutiveEngineFailures: maxFailures),
            sink: collector.sink
        )
        return (pipeline, collector)
    }

    // MARK: Hostile input

    @Test func audioAtANonsenseSampleRateIsDiscardedNotProcessed() throws {
        let (pipeline, collector) = Self.makePipeline()
        let engine = RecordingEngine()
        try pipeline.install(engine)
        let samples = [Float](repeating: 0.01, count: 4_800)
        var time = HostTime(seconds: 1_000)
        // A device in the middle of switching formats can briefly report 0 Hz (or worse); none of this may
        // reach the resampler, where a zero or absurd ratio would divide by zero or allocate without bound.
        for rate in [0.0, -48_000, .nan, .infinity, 999, 768_001, 1e12] {
            pipeline.ingest(samples, sampleRate: rate, hostTime: time)
            time = time.advanced(bySeconds: 0.1)
        }
        #expect(pipeline.statistics().chunksDiscarded == 7)
        #expect(engine.frames.isEmpty)
        #expect(collector.faults.isEmpty)

        Audio.feed(pipeline, seconds: 1, sampleRate: 48_000, from: time)   // and normal service resumes
        #expect(engine.frames.count > 25)
    }

    @Test func anEngineFaultNamesTheEngineThatFaultedSoALateReportCanBeRecognisedAsStale() async throws {
        let (pipeline, collector) = Self.makePipeline(maxFailures: 2)
        func brokenEngine() async throws -> MockWakeWordEngine {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.failFromFrame = (index: 0, error: .processingFailed("dead"))
            let engine = MockWakeWordEngine(behavior: behavior)
            try await engine.initialize()
            return engine
        }
        let first = try await brokenEngine()
        try pipeline.install(first)
        Audio.feed(pipeline, seconds: 0.5, sampleRate: 48_000)
        let second = try await brokenEngine()
        try pipeline.install(second)
        Audio.feed(pipeline, seconds: 0.5, sampleRate: 48_000, from: HostTime(seconds: 2_000))

        let identities = collector.events.compactMap { event -> ObjectIdentifier? in
            if case .engineFault(_, let engine) = event { engine } else { nil }
        }
        #expect(identities == [ObjectIdentifier(first), ObjectIdentifier(second)], "one fault per engine, each naming its own engine")
    }

    @Test func aDiscardedSampleRateIsNeverPublishedAsAStatistic() throws {
        let (pipeline, _) = Self.makePipeline()
        try pipeline.install(RecordingEngine())
        Audio.feed(pipeline, seconds: 0.2, sampleRate: 48_000)
        #expect(pipeline.statistics().inputSampleRate == 48_000)
        // The Diagnostics view formats this number as an Int; infinity or NaN there is a crash, not a curiosity.
        for rate in [Double.infinity, .nan, -1, 1e12, 5] {
            pipeline.ingest([Float](repeating: 0.01, count: 480), sampleRate: rate, hostTime: HostTime(seconds: 2_000))
            #expect(pipeline.statistics().inputSampleRate == 48_000, "a discarded rate (\(rate)) must not replace the last real one")
        }
    }

    // MARK: Audio preparation

    @Test func engineReceivesExactlySizedFramesAtItsOwnSampleRate() throws {
        let (pipeline, _) = Self.makePipeline()
        let engine = RecordingEngine()
        try pipeline.install(engine)
        Audio.feed(pipeline, seconds: 2, sampleRate: 48_000)

        let frames = engine.frames
        #expect(frames.count >= 60 && frames.count <= 63) // 2 s / 32 ms = 62.5
        #expect(frames.allSatisfy { $0.samples.count == 512 && $0.sampleRate == 16_000 })
        #expect(frames.map(\.sequence) == Array(0..<UInt64(frames.count)))
    }

    @Test func differentEnginesGetDifferentRatesAndFrameSizesFromTheSameMicrophoneStream() throws {
        let (pipeline, _) = Self.makePipeline()
        let engine = RecordingEngine(requirements: .init(sampleRate: 8_000, frameLength: 160))
        try pipeline.install(engine)
        Audio.feed(pipeline, seconds: 1, sampleRate: 44_100)
        let frames = engine.frames
        #expect(abs(frames.count - 50) <= 2) // 1 s / 20 ms
        #expect(frames.allSatisfy { $0.samples.count == 160 && $0.sampleRate == 8_000 })
    }

    @Test func frameContentDoesNotDependOnMicrophoneChunking() throws {
        func frames(chunk: Int) throws -> [[Float]] {
            let (pipeline, _) = Self.makePipeline()
            let engine = RecordingEngine()
            try pipeline.install(engine)
            Audio.feed(pipeline, seconds: 1, sampleRate: 48_000, chunk: chunk)
            return engine.frames.map(\.samples)
        }
        // The noise generator advances per sample, so every chunking sees identical input.
        let reference = try frames(chunk: 4_800)
        for chunk in [480, 1_000, 4_096] {
            let other = try frames(chunk: chunk)
            let common = min(reference.count, other.count)
            #expect(common > 25)
            for index in 0..<common {
                let worst = zip(reference[index], other[index]).map { abs($0 - $1) }.max() ?? 0
                #expect(worst < 1e-5, "frame \(index) differs with chunk \(chunk)")
            }
        }
    }

    @Test func frameTimestampsAdvanceByExactlyOneFrameDuration() throws {
        let (pipeline, _) = Self.makePipeline()
        let engine = RecordingEngine()
        try pipeline.install(engine)
        Audio.feed(pipeline, seconds: 1, sampleRate: 48_000, chunk: 1_234)
        let frames = engine.frames
        for (previous, next) in zip(frames, frames.dropFirst()) {
            let step = next.captureTime.seconds(since: previous.captureTime)
            #expect(abs(step - 0.032) < 1e-4, "frame \(next.sequence) step \(step)")
        }
    }

    @Test func aChangeOfMicrophoneSampleRateIsHandledWithoutDroppingTheStream() throws {
        let (pipeline, _) = Self.makePipeline()
        let engine = RecordingEngine()
        try pipeline.install(engine)
        let mid = Audio.feed(pipeline, seconds: 1, sampleRate: 48_000)
        let before = engine.frames.count
        Audio.feed(pipeline, seconds: 1, sampleRate: 44_100, from: mid)
        #expect(engine.frames.count - before >= 28)
        #expect(engine.frames.allSatisfy { $0.samples.count == 512 })
    }

    // MARK: Detection, gating, duplicates

    @Test func acceptedDetectionProducesAnEventAndGatesTheEngine() throws {
        let (pipeline, collector) = Self.makePipeline()
        let engine = RecordingEngine(detectOn: [10])
        try pipeline.install(engine)
        Audio.feed(pipeline, seconds: 2, sampleRate: 48_000)

        let detections = collector.detections
        #expect(detections.count == 1)
        #expect(detections[0].keyword == .jarvis)
        #expect(detections[0].engineID == "recording")
        #expect(detections[0].frameSequence == 10)
        #expect(detections[0].captureToDetectionLatency >= 0)
        // Frame 10 was the last one the engine saw: the pipeline gated itself immediately.
        #expect(engine.frames.count == 11)
        #expect(pipeline.statistics().isGated)
        #expect(pipeline.statistics().chunksDiscarded > 0)
    }

    @Test func gatedPipelineDiscardsAudioWithoutTouchingTheEngine() throws {
        let (pipeline, _) = Self.makePipeline()
        let engine = RecordingEngine()
        try pipeline.install(engine)
        pipeline.setGated(true)
        Audio.feed(pipeline, seconds: 1)
        #expect(engine.frames.isEmpty)
        pipeline.setGated(false)
        Audio.feed(pipeline, seconds: 1)
        #expect(!engine.frames.isEmpty)
    }

    @Test func anEngineThatFiresOnEveryFrameActivatesOnceWhenNotGated() async throws {
        let (pipeline, collector) = Self.makePipeline(gateOnAccepted: false)
        let engine = MockWakeWordEngine(behavior: {
            var behavior = MockWakeWordEngine.Behavior()
            behavior.detectEveryNthFrame = 1
            return behavior
        }())
        try pipeline.install(engine)
        try await engine.initialize()
        Audio.feed(pipeline, seconds: 1.5)

        #expect(collector.detections.count == 1)
        #expect(collector.suppressions.count > 30)
        #expect(collector.suppressions.allSatisfy { $0 == .debounced })
    }

    @Test func cooldownLetsLaterUtterancesThroughOnlyAfterItExpires() throws {
        // Detections at frames 20 (≈0.64 s), 50 (≈1.6 s: inside the 2 s cooldown), 120 (≈3.84 s: after).
        let (pipeline, collector) = Self.makePipeline(gateOnAccepted: false)
        let engine = RecordingEngine(detectOn: [20, 50, 120])
        try pipeline.install(engine)
        Audio.feed(pipeline, seconds: 5)

        #expect(collector.detections.map(\.frameSequence) == [20, 120])
        #expect(collector.suppressions.count == 1)
        if case .cooldown = collector.suppressions[0] {} else { Issue.record("expected a cooldown rejection") }
    }

    @Test func holdoffAfterResumingIgnoresDetectionsForTheRequestedAudioTime() throws {
        let (pipeline, collector) = Self.makePipeline(gateOnAccepted: false)
        // 32 ms frames after resuming: detections at frame 10 (0.32 s) and 60 (1.92 s).
        let engine = RecordingEngine(detectOn: [10, 60])
        try pipeline.install(engine)
        pipeline.setGated(true)
        pipeline.setGated(false, holdoff: 1.0)
        Audio.feed(pipeline, seconds: 3)

        #expect(collector.detections.map(\.frameSequence) == [60])
        #expect(collector.suppressions.count == 1)
        if case .holdoff = collector.suppressions[0] {} else { Issue.record("expected a holdoff rejection") }
    }

    @Test func injectedDetectionsGoThroughTheSameValidationAndGating() throws {
        let (pipeline, collector) = Self.makePipeline()
        try pipeline.install(RecordingEngine())
        pipeline.injectDetection(DetectionResult(keyword: .jarvis), at: HostTime(seconds: 2_000))
        #expect(collector.detections.count == 1)
        #expect(pipeline.statistics().isGated)
        // Gated → a second injection is ignored entirely.
        pipeline.injectDetection(DetectionResult(keyword: .jarvis), at: HostTime(seconds: 2_010))
        #expect(collector.detections.count == 1)
    }

    // MARK: Engine management

    @Test func installReturnsThePreviousEngineAndTheNewOneReceivesSubsequentAudio() throws {
        let (pipeline, _) = Self.makePipeline()
        let first = RecordingEngine(identifier: "first")
        let second = RecordingEngine(identifier: "second")
        #expect(try pipeline.install(first) == nil)
        Audio.feed(pipeline, seconds: 0.5)
        let seen = first.frames.count
        #expect(seen > 0)

        let replaced = try pipeline.install(second)
        #expect((replaced as? RecordingEngine) === first)
        Audio.feed(pipeline, seconds: 0.5, from: HostTime(seconds: 1_001))
        #expect(first.frames.count == seen)
        #expect(second.frames.count > 0)
        #expect(second.frames.first?.sequence == 0) // the sequence restarts with the new engine
    }

    @Test func uninstallStopsDeliveryAndHandsTheEngineBack() throws {
        let (pipeline, _) = Self.makePipeline()
        let engine = RecordingEngine()
        try pipeline.install(engine)
        #expect((pipeline.uninstall() as? RecordingEngine) === engine)
        Audio.feed(pipeline, seconds: 0.5)
        #expect(engine.frames.isEmpty)
        #expect(pipeline.statistics().hasEngine == false)
    }

    @Test func enginesWithUnusableRequirementsAreRejected() {
        let (pipeline, _) = Self.makePipeline()
        let broken = RecordingEngine(requirements: .init(sampleRate: 16_000, frameLength: 0))
        #expect(throws: WakeWordError.self) { try pipeline.install(broken) }
    }

    @Test func sensitivityReachesTheInstalledEngineAndFailsWithoutOne() async throws {
        let (pipeline, _) = Self.makePipeline()
        #expect(throws: WakeWordError.notInitialized) { try pipeline.updateSensitivity(0.7) }
        let mock = MockWakeWordEngine()
        try await mock.initialize()
        try pipeline.install(mock)
        try pipeline.updateSensitivity(0.7)
        #expect(mock.callLog.sensitivityUpdates == [0.7])
    }

    // MARK: Failure handling

    @Test func transientFrameFailuresAreCountedButTheEngineKeepsRunning() async throws {
        let (pipeline, collector) = Self.makePipeline(maxFailures: 5)
        var behavior = MockWakeWordEngine.Behavior()
        behavior.failFromFrame = (index: 3, error: .processingFailed("glitch"))
        let engine = MockWakeWordEngine(behavior: behavior)
        try await engine.initialize()
        try pipeline.install(engine)
        Audio.feed(pipeline, seconds: 0.22) // 6–7 frames: 3 ok, then failures below the limit
        let statistics = pipeline.statistics()
        #expect(statistics.engineErrors >= 3 && statistics.engineErrors < 5)
        #expect(collector.faults.isEmpty)
    }

    @Test func repeatedFailuresTakeTheEngineOutOfServiceAndReportOnce() async throws {
        let (pipeline, collector) = Self.makePipeline(maxFailures: 5)
        var behavior = MockWakeWordEngine.Behavior()
        behavior.failFromFrame = (index: 0, error: .processingFailed("dead"))
        let engine = MockWakeWordEngine(behavior: behavior)
        try await engine.initialize()
        try pipeline.install(engine)
        Audio.feed(pipeline, seconds: 2)

        #expect(collector.faults == [.processingFailed("dead")])
        #expect(engine.callLog.processCalls == 5) // no further calls after the fault
    }

    @Test func reinstallingAnEngineClearsTheFault() async throws {
        let (pipeline, collector) = Self.makePipeline(maxFailures: 2)
        var broken = MockWakeWordEngine.Behavior()
        broken.failFromFrame = (index: 0, error: .processingFailed("dead"))
        let bad = MockWakeWordEngine(behavior: broken)
        try await bad.initialize()
        try pipeline.install(bad)
        Audio.feed(pipeline, seconds: 0.5)
        #expect(collector.faults.count == 1)

        let good = RecordingEngine()
        try pipeline.install(good)
        Audio.feed(pipeline, seconds: 0.5, from: HostTime(seconds: 1_001))
        #expect(good.frames.count > 10)
    }

    // MARK: Statistics

    @Test func statisticsTrackLevelsFramesAndEngineTime() throws {
        let (pipeline, _) = Self.makePipeline()
        try pipeline.install(RecordingEngine())
        Audio.feed(pipeline, seconds: 1, amplitude: 0.2)
        let statistics = pipeline.statistics()
        #expect(statistics.chunksIngested == 10)
        #expect(statistics.framesProcessed >= 30)
        #expect(statistics.engineProcessTime.count == statistics.framesProcessed)
        #expect(statistics.inputSampleRate == 48_000)
        #expect(statistics.level.peak > 0.1 && statistics.level.peak <= 0.2)

        pipeline.resetStatistics()
        #expect(pipeline.statistics().chunksIngested == 0)
        #expect(pipeline.statistics().hasEngine)
    }

    @Test func preRollIsOnlyRetainedWhenAVerifierAsksForIt() throws {
        let collector = EventCollector()
        let none = WakeWordPipeline(configuration: .init(preRollDuration: 0), sink: collector.sink)
        try none.install(RecordingEngine(detectOn: [20]))
        Audio.feed(none, seconds: 1)
        guard case .detection(_, let withoutPreRoll, _)? = collector.events.first else { Issue.record("no detection"); return }
        #expect(withoutPreRoll == nil)

        let collector2 = EventCollector()
        let some = WakeWordPipeline(configuration: .init(preRollDuration: 0.5), sink: collector2.sink)
        try some.install(RecordingEngine(detectOn: [20]))
        Audio.feed(some, seconds: 1)
        guard case .detection(_, let retained?, let rate)? = collector2.events.first else { Issue.record("no detection"); return }
        #expect(rate == 16_000)
        #expect(retained.count == 8_000) // 0.5 s at 16 kHz
    }
}
