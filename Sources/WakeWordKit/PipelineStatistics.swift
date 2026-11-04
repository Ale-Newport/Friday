import Foundation

/// Running count / total / maximum of a duration, in seconds. Constant memory, no allocation.
public struct DurationStatistics: Equatable, Sendable {
    public private(set) var count: UInt64 = 0
    public private(set) var totalSeconds: Double = 0
    public private(set) var maxSeconds: Double = 0
    public private(set) var lastSeconds: Double = 0

    public init() {}

    public mutating func record(_ seconds: Double) {
        count &+= 1
        totalSeconds += seconds
        maxSeconds = Swift.max(maxSeconds, seconds)
        lastSeconds = seconds
    }

    public var averageSeconds: Double { count == 0 ? 0 : totalSeconds / Double(count) }
}

/// Counters maintained by the pipeline for diagnostics. Reading them never affects detection.
public struct PipelineStatistics: Equatable, Sendable {
    /// Microphone buffers received.
    public var chunksIngested: UInt64 = 0
    /// Buffers discarded because detection was gated (an assistant session) or no engine is installed.
    public var chunksDiscarded: UInt64 = 0
    /// Frames passed to the engine.
    public var framesProcessed: UInt64 = 0
    /// Frames the engine failed to process.
    public var engineErrors: UInt64 = 0
    public var detectionsAccepted: UInt64 = 0
    public var detectionsSuppressed: UInt64 = 0
    /// Sample rate of the most recent microphone buffer.
    public var inputSampleRate: Double = 0
    /// Level of the most recent microphone buffer.
    public var level: AudioLevel = .silence
    /// Wall time the engine took per frame.
    public var engineProcessTime = DurationStatistics()
    /// Delay between the end of the audio that completed a keyword and the engine reporting it.
    public var captureToDetectionLatency = DurationStatistics()
    public var isGated = false
    public var hasEngine = false

    public init() {}
}
