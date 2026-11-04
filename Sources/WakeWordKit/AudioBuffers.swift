import Accelerate
import Foundation

/// Accumulates a continuous sample stream and releases it in fixed-size frames.
///
/// The memory held is bounded by `frameLength` plus the largest single `append`, and a partial
/// frame is never released early. Not thread-safe.
public struct FrameAssembler {
    public let frameLength: Int
    private var buffer: [Float] = []
    private var readIndex = 0

    public init(frameLength: Int) {
        precondition(frameLength > 0, "frameLength must be positive")
        self.frameLength = frameLength
        buffer.reserveCapacity(frameLength * 4)
    }

    /// Samples waiting for the next frame boundary.
    public var pendingCount: Int { buffer.count - readIndex }

    /// Appends samples and calls `emit` once for every complete frame, in order.
    public mutating func append(_ samples: [Float], emit: ([Float]) -> Void) {
        buffer.append(contentsOf: samples)
        while buffer.count - readIndex >= frameLength {
            emit(Array(buffer[readIndex..<(readIndex + frameLength)]))
            readIndex += frameLength
        }
        // Compact once per call (not per frame) so steady-state cost stays tiny.
        if readIndex > 0 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }

    /// Drops any partial frame.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        readIndex = 0
    }
}

/// A fixed-capacity ring of the most recent samples. Used only when a ``DetectionVerifier``
/// asks for audio preceding a detection (for example speaker verification); with the default
/// configuration capacity is zero and nothing is retained.
public struct PreRollBuffer {
    public let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    public var count: Int { filled }

    public mutating func append(_ samples: [Float]) {
        guard capacity > 0 else { return }
        for sample in samples.suffix(capacity) {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        filled = min(capacity, filled + min(samples.count, capacity))
    }

    /// The retained samples, oldest first.
    public func snapshot() -> [Float] {
        guard filled > 0 else { return [] }
        if filled < capacity { return Array(storage[0..<filled]) }
        return Array(storage[writeIndex..<capacity]) + Array(storage[0..<writeIndex])
    }

    public mutating func reset() {
        writeIndex = 0
        filled = 0
    }
}

/// Peak and RMS of an audio block, used for the diagnostics level meter and to detect a dead
/// (all-zero) microphone stream.
public struct AudioLevel: Equatable, Sendable {
    public var peak: Float
    public var rms: Float

    public static let silence = AudioLevel(peak: 0, rms: 0)

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }

    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> AudioLevel {
        guard let base = samples.baseAddress, !samples.isEmpty else { return .silence }
        var peak: Float = 0
        var rms: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(samples.count))
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(samples.count))
        return AudioLevel(peak: peak, rms: rms)
    }

    public var peakDecibels: Float { Self.decibels(peak) }
    public var rmsDecibels: Float { Self.decibels(rms) }

    /// dBFS with a floor of -120 dB.
    public static func decibels(_ linear: Float) -> Float {
        20 * log10(max(linear, 1e-6))
    }
}
