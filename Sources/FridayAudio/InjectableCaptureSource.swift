import AVFoundation
import Foundation
import WakeWordKit

/// Wraps a real capture source and lets a test or a script feed recorded speech into the pipeline exactly as if it
/// had come from the microphone: while injected audio is queued it *replaces* the microphone samples chunk for
/// chunk (same cadence, same sample rate, same host-time progression), so the wake-word engine, the ring buffer and
/// the recogniser see one continuous stream. When the queue is empty the microphone passes through untouched.
///
/// This is how the whole voice path (wake word → capture → transcription → planning → reply) is exercised end to
/// end without a person at the microphone; `fridayctl --voice file.wav` uses it.
public final class InjectableCaptureSource: AudioCaptureSource, @unchecked Sendable {
    private struct State {
        var queue: [Float] = []
        var offset = 0
        var sampleRate: Double = 0
        var injected = 0
        var completions: [@Sendable () -> Void] = []
    }

    private let inner: any AudioCaptureSource
    private let state = Protected(State())

    public init(wrapping inner: any AudioCaptureSource) {
        self.inner = inner
    }

    // MARK: AudioCaptureSource

    public var isRunning: Bool { inner.isRunning }

    public func events() -> AsyncStream<AudioCaptureEvent> { inner.events() }

    @discardableResult
    public func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo {
        let state = state
        let info = try inner.start(input: input) { samples, sampleRate, hostTime in
            let replacement: [Float]? = state.withLock { s -> [Float]? in
                guard s.offset < s.queue.count else {
                    if !s.queue.isEmpty {
                        s.queue = []
                        s.offset = 0
                        let done = s.completions
                        s.completions = []
                        for completion in done { completion() }
                    }
                    return nil
                }
                let end = min(s.offset + samples.count, s.queue.count)
                var chunk = Array(s.queue[s.offset..<end])
                if chunk.count < samples.count { chunk.append(contentsOf: repeatElement(0, count: samples.count - chunk.count)) }
                s.offset = end
                return chunk
            }
            if let replacement {
                replacement.withUnsafeBufferPointer { handler($0, sampleRate, hostTime) }
            } else {
                handler(samples, sampleRate, hostTime)
            }
        }
        state.withLock { $0.sampleRate = info.sampleRate }
        return info
    }

    public func stop() {
        inner.stop()
        state.withLock { $0.queue = []; $0.offset = 0 }
    }

    // MARK: Injection

    /// The sample rate the running capture delivers (0 when not running).
    public var captureSampleRate: Double { state.withLock { $0.sampleRate } }

    /// Whether injected audio is still being delivered.
    public var isInjecting: Bool { state.withLock { $0.offset < $0.queue.count } }

    /// Queues mono audio to be delivered in place of the microphone, after `leadingSilence` and followed by
    /// `trailingSilence` seconds of silence (the trailing silence lets the recogniser end the utterance without
    /// depending on the room being quiet). `completion` runs once the last injected chunk was delivered.
    /// - Returns: `false` when the capture is not running (nothing to inject into).
    @discardableResult
    public func inject(_ samples: [Float], sampleRate: Double, leadingSilence: Double = 0.2, trailingSilence: Double = 1.5, completion: (@Sendable () -> Void)? = nil) -> Bool {
        let targetRate = captureSampleRate
        guard targetRate > 0, inner.isRunning else { return false }
        let converted = Self.resample(samples, from: sampleRate, to: targetRate)
        let lead = [Float](repeating: 0, count: Int(leadingSilence * targetRate))
        let tail = [Float](repeating: 0, count: Int(trailingSilence * targetRate))
        state.withLock { s in
            if s.offset >= s.queue.count { s.queue = []; s.offset = 0 }
            s.queue.append(contentsOf: lead + converted + tail)
            s.injected += 1
            if let completion { s.completions.append(completion) }
        }
        return true
    }

    /// Reads any audio file Core Audio can open and returns mono samples (channels averaged) at the file's rate.
    public static func load(contentsOf url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return ([], format.sampleRate) }
        try file.read(into: buffer)
        let channels = Int(format.channelCount)
        let count = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return ([], format.sampleRate) }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let source = data[channel]
            for i in 0..<count { mono[i] += source[i] / Float(channels) }
        }
        return (mono, format.sampleRate)
    }

    static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate != outputRate, !samples.isEmpty else { return samples }
        let resampler = StreamingResampler(inputRate: inputRate, outputRate: outputRate)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * outputRate / inputRate) + 64)
        resampler.process(samples, appendingTo: &output)
        // Flush the filter's tail with silence so the last word is not clipped.
        let tail = [Float](repeating: 0, count: max(64, resampler.latencyInputSamples * 2))
        resampler.process(tail, appendingTo: &output)
        return output
    }
}
