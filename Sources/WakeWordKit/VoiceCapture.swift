import Foundation

/// What the microphone hears, kept in memory as 16 kHz mono for the few minutes in which a person teaches the app their voice.
///
/// It is fed from the capture thread (through the pipeline's audio tap, see ``WakeWordPipeline/setAudioTap(_:)``) and read from
/// anywhere. **Nothing is ever written to disk**, and the owner discards it when the lesson is over. The memory it can hold is bounded
/// (`maximumSeconds`, reserved up front so that the capture thread never has to grow it); once full it stops taking audio and says so.
///
/// Along with the samples it keeps the level of every 20 ms frame (dBFS), which is what a live session judges "has the person said
/// something?" by, and the room-tone statistics a recording needs.
public final class VoiceCapture: @unchecked Sendable {
    /// The rate everything is stored at.
    public static let sampleRate = 16_000
    /// Samples in one level frame (20 ms).
    public static let frameLength = sampleRate / UtteranceSplitter.framesPerSecond

    private struct State {
        var samples: [Float] = []
        var levels: [Float] = []
        var resampler: StreamingResampler?
        var scratch: [Float] = []
        var frameEnergy: Float = 0
        var frameFill = 0
        var peakByFrame: [Float] = []
        var framePeak: Float = 0
        var closed = false
        var full = false
    }

    private let state = Protected(State())
    private let capacity: Int

    public init(maximumSeconds: Double = 600) {
        let seconds = min(3_600, max(1, maximumSeconds.isFinite ? maximumSeconds : 600))
        capacity = Int(seconds) * Self.sampleRate
        state.withLock { state in
            state.samples.reserveCapacity(capacity)
            state.levels.reserveCapacity(Int(seconds) * UtteranceSplitter.framesPerSecond)
            state.peakByFrame.reserveCapacity(Int(seconds) * UtteranceSplitter.framesPerSecond)
            state.scratch.reserveCapacity(Self.sampleRate)
        }
    }

    // MARK: Writing (the capture thread)

    /// Adds one microphone buffer of any sample rate. Quick, and safe to call after ``close()`` (it then does nothing).
    public func append(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate >= 1_000, sampleRate <= 768_000, !samples.isEmpty else { return }
        state.withLock { state in
            guard !state.closed, !state.full else { return }
            if state.resampler == nil || state.resampler?.inputRate != sampleRate {
                state.resampler = StreamingResampler(inputRate: sampleRate, outputRate: Double(Self.sampleRate))
            }
            state.scratch.removeAll(keepingCapacity: true)
            state.resampler?.process(samples, appendingTo: &state.scratch)
            for raw in state.scratch {
                if state.samples.count >= capacity { state.full = true; return }
                // Numbers that are not audio (a driver glitch) are silence here, as the engines treat them.
                let sample = raw.isFinite ? min(1, max(-1, raw)) : 0
                state.samples.append(sample)
                state.frameEnergy += sample * sample
                state.framePeak = max(state.framePeak, abs(sample))
                state.frameFill += 1
                if state.frameFill == Self.frameLength {
                    let rms = (state.frameEnergy / Float(Self.frameLength)).squareRoot()
                    state.levels.append(20 * log10(max(rms, 1e-6)))
                    state.peakByFrame.append(state.framePeak)
                    state.frameEnergy = 0
                    state.framePeak = 0
                    state.frameFill = 0
                }
            }
        }
    }

    /// Stops taking audio (a late buffer from the capture thread is ignored). The recorded audio stays readable.
    public func close() {
        state.withLock { $0.closed = true }
    }

    // MARK: Reading (any thread)

    /// Complete 20 ms frames recorded so far.
    public var frameCount: Int { state.withLock { $0.levels.count } }
    public var sampleCount: Int { state.withLock { $0.samples.count } }
    public var seconds: Double { Double(sampleCount) / Double(Self.sampleRate) }
    /// True once `maximumSeconds` were recorded: nothing more is taken.
    public var isFull: Bool { state.withLock { $0.full } }
    public var isClosed: Bool { state.withLock { $0.closed } }

    /// The level of the latest complete frame (dBFS), or −120 before there is one.
    public var latestLevelDecibels: Float { state.withLock { $0.levels.last ?? -120 } }

    /// The level of every frame from frame index `start` on (dBFS).
    public func levels(from start: Int = 0) -> [Float] {
        state.withLock { state in
            let from = min(max(0, start), state.levels.count)
            return Array(state.levels[from...])
        }
    }

    /// The samples of the frames in `frames` (clamped to what exists).
    public func samples(frames: Range<Int>) -> [Float] {
        state.withLock { state in
            let lower = min(max(0, frames.lowerBound), state.levels.count) * Self.frameLength
            let upper = min(max(0, frames.upperBound), state.levels.count) * Self.frameLength
            return lower < upper ? Array(state.samples[lower..<upper]) : []
        }
    }

    /// The loudest sample (absolute value) among the frames in `frames`, 0 if there are none.
    public func peak(frames: Range<Int>) -> Float {
        state.withLock { state in
            let lower = min(max(0, frames.lowerBound), state.peakByFrame.count)
            let upper = min(max(0, frames.upperBound), state.peakByFrame.count)
            return lower < upper ? state.peakByFrame[lower..<upper].max() ?? 0 : 0
        }
    }

    /// Everything recorded so far.
    public func allSamples() -> [Float] { state.withLock { $0.samples } }
}
