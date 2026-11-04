/// What an engine needs from the audio pipeline. Different engines ask for different sample
/// rates and frame sizes; the pipeline adapts the microphone stream to whatever is requested.
///
/// Frames are always mono. Samples are delivered as normalised `Float` in `[-1, 1]` (see
/// `AudioFrame`); engines that want integers convert with `AudioFrame.copyInt16Samples(into:)`.
public struct AudioRequirements: Equatable, Sendable {
    /// Samples per second the engine expects.
    public var sampleRate: Int
    /// Number of samples (per channel) in every frame passed to `processAudio`.
    public var frameLength: Int

    public init(sampleRate: Int, frameLength: Int) {
        self.sampleRate = sampleRate
        self.frameLength = frameLength
    }

    /// Length of one frame in seconds.
    public var frameDuration: Double { Double(frameLength) / Double(sampleRate) }

    public var isValid: Bool { sampleRate >= 4_000 && sampleRate <= 192_000 && frameLength > 0 && frameLength <= 1 << 20 }
}

/// One fixed-size block of engine-ready audio: mono, normalised `Float` samples at the sample
/// rate the engine requested.
///
/// A frame owns its samples (value semantics), so an engine may keep or forward it without
/// worrying about buffer lifetimes. Frames are created at the engine's frame rate (about 30 per
/// second for a 512-sample / 16 kHz engine), never inside a real-time audio callback.
public struct AudioFrame: Sendable {
    /// Mono samples in `[-1, 1]`.
    public let samples: [Float]
    public let sampleRate: Int
    /// Monotonic counter, starting at 0, of frames produced since the pipeline last (re)started.
    public let sequence: UInt64
    /// Capture time of the first sample.
    public let captureTime: HostTime

    public init(samples: [Float], sampleRate: Int, sequence: UInt64, captureTime: HostTime) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
        self.captureTime = captureTime
    }

    public var duration: Double { Double(samples.count) / Double(sampleRate) }

    /// Capture time of the end of the frame (first sample time plus the frame duration).
    public var endTime: HostTime { captureTime.advanced(bySeconds: duration) }

    /// Writes the samples as clipped, rounded 16-bit PCM into `buffer`, resizing it if needed.
    /// Reuse the same buffer across calls to avoid per-frame allocations.
    public func copyInt16Samples(into buffer: inout [Int16]) {
        if buffer.count != samples.count {
            buffer = [Int16](repeating: 0, count: samples.count)
        }
        for index in samples.indices {
            let scaled = (samples[index] * 32768).rounded()
            buffer[index] = Int16(max(-32768, min(32767, scaled)))
        }
    }

    public func int16Samples() -> [Int16] {
        var buffer: [Int16] = []
        copyInt16Samples(into: &buffer)
        return buffer
    }
}
