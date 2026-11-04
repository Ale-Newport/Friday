import Foundation
@testable import WakeWordKit

/// Collects pipeline events from any thread.
final class EventCollector: @unchecked Sendable {
    private let storage = Protected<[WakeWordPipeline.Event]>([])

    var sink: @Sendable (WakeWordPipeline.Event) -> Void {
        { [storage] event in storage.withLock { $0.append(event) } }
    }

    var events: [WakeWordPipeline.Event] { storage.withLock { $0 } }

    var detections: [WakeWordEvent] {
        events.compactMap { if case .detection(let event, _, _) = $0 { event } else { nil } }
    }

    var suppressions: [DetectionValidator.Rejection] {
        events.compactMap { if case .suppressed(_, let reason, _) = $0 { reason } else { nil } }
    }

    var faults: [WakeWordError] {
        events.compactMap { if case .engineFault(let error, _) = $0 { error } else { nil } }
    }
}

/// An engine that records every frame it is given, for asserting on the audio the pipeline
/// prepares. Reports a detection on the frame numbers it is told to.
final class RecordingEngine: WakeWordEngine, @unchecked Sendable {
    let identifier: String
    let audioRequirements: AudioRequirements
    private struct State {
        var frames: [AudioFrame] = []
        var detectOn: Set<Int> = []
        var shutdowns = 0
    }
    private let state = Protected(State())

    init(identifier: String = "recording", requirements: AudioRequirements = .init(sampleRate: 16_000, frameLength: 512), detectOn: Set<Int> = []) {
        self.identifier = identifier
        self.audioRequirements = requirements
        state.withLock { $0.detectOn = detectOn }
    }

    var frames: [AudioFrame] { state.withLock { $0.frames } }
    var shutdowns: Int { state.withLock { $0.shutdowns } }

    func initialize() async throws(WakeWordError) {}

    func processAudio(_ frame: AudioFrame) throws(WakeWordError) -> DetectionResult? {
        state.withLock { state in
            state.frames.append(frame)
            return state.detectOn.contains(state.frames.count - 1) ? DetectionResult(keyword: .jarvis) : nil
        }
    }

    func updateSensitivity(_ value: Float) throws(WakeWordError) {}

    func shutdown() { state.withLock { $0.shutdowns += 1 } }
}

enum Audio {
    /// Feeds `seconds` of low-level noise to `pipeline` in `chunk`-sized pieces and returns the host
    /// time at which the stream ended. Deterministic: the noise is a fixed pattern.
    @discardableResult
    static func feed(
        _ pipeline: WakeWordPipeline,
        seconds: Double,
        sampleRate: Double = 48_000,
        chunk: Int = 4_800,
        from start: HostTime = HostTime(seconds: 1_000),
        amplitude: Float = 0.01
    ) -> HostTime {
        let total = Int(seconds * sampleRate)
        var produced = 0
        var time = start
        var generator = SplitMix64(seed: 42)
        while produced < total {
            let count = min(chunk, total - produced)
            let samples = (0..<count).map { _ in amplitude * (Float(generator.next() % 2001) / 1000 - 1) }
            pipeline.ingest(samples, sampleRate: sampleRate, hostTime: time)
            produced += count
            time = time.advanced(bySeconds: Double(count) / sampleRate)
        }
        return time
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
