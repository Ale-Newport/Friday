import Foundation
import WakeWordKit

/// A continuously running ring buffer of the last seconds of microphone audio at 16 kHz, fed from the wake-word
/// pipeline's audio tap (one microphone, one capture — never a second `AVAudioEngine`). When the wake word fires,
/// the recogniser reads from here starting right after the keyword, so the words spoken in the same breath
/// ("Jarvis open Chrome") are not lost to the detector's ~0.4 s latency.
///
/// Thread model: `append` runs on the audio thread (after the pipeline released its lock); readers run anywhere.
public final class MicrophoneRecorder: @unchecked Sendable {
    public static let sampleRate = 16_000

    private struct State {
        var ring: [Float]
        var writeIndex = 0
        var totalWritten = 0  // samples ever written (monotonic); position of the next write
        var resampler: StreamingResampler?
        var scratch: [Float] = []
        var lastArrival = HostTime.now
        var lastLevel: Float = -120
    }

    private let lock = NSLock()
    private var state: State
    private let capacity: Int

    public init(seconds: Double = 20) {
        capacity = Int(max(2, min(120, seconds)) * Double(Self.sampleRate))
        state = State(ring: [Float](repeating: 0, count: capacity))
        state.scratch.reserveCapacity(Self.sampleRate)
    }

    /// The wake-word pipeline's `AudioTap`. Samples arrive at the microphone's rate (often 48 kHz); they are
    /// resampled to 16 kHz here.
    public func tap(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard sampleRate >= 1_000, !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if state.resampler == nil || state.resampler?.inputRate != sampleRate {
            state.resampler = StreamingResampler(inputRate: sampleRate, outputRate: Double(Self.sampleRate))
        }
        state.scratch.removeAll(keepingCapacity: true)
        state.resampler?.process(samples, appendingTo: &state.scratch)
        var energy: Float = 0
        for raw in state.scratch {
            let sample = raw.isFinite ? min(1, max(-1, raw)) : 0
            state.ring[state.writeIndex] = sample
            state.writeIndex = (state.writeIndex + 1) % capacity
            state.totalWritten += 1
            energy += sample * sample
        }
        if !state.scratch.isEmpty {
            let rms = (energy / Float(state.scratch.count)).squareRoot()
            state.lastLevel = 20 * log10(max(rms, 1e-6))
        }
        state.lastArrival = .now
    }

    /// Position (in samples since start) of the next sample to be written.
    public var position: Int { lock.withLock { state.totalWritten } }
    public var lastLevelDecibels: Float { lock.withLock { state.lastLevel } }

    /// The sample position that corresponds to a host time, assuming the latest buffer ended at its arrival time.
    public func position(at time: HostTime) -> Int {
        lock.withLock {
            let secondsAgo = time.seconds(since: state.lastArrival)
            return max(0, state.totalWritten + Int(secondsAgo * Double(Self.sampleRate)))
        }
    }

    /// Samples from `from` (inclusive) to `to` (exclusive), clamped to what the ring still holds.
    public func samples(from: Int, to: Int) -> [Float] {
        lock.withLock {
            let oldest = max(0, state.totalWritten - capacity)
            let start = max(from, oldest)
            let end = min(to, state.totalWritten)
            guard start < end else { return [] }
            var out = [Float](repeating: 0, count: end - start)
            for (offset, absolute) in (start..<end).enumerated() { out[offset] = state.ring[absolute % capacity] }
            return out
        }
    }

    /// Everything written since `position` (exclusive of nothing), and the new position.
    public func drain(since position: Int) -> (samples: [Float], position: Int) {
        let now = self.position
        return (samples(from: position, to: now), now)
    }
}
