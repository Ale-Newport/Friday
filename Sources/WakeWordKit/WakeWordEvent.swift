import Foundation

/// An accepted wake-word detection — the one shared data structure that crosses from the
/// detection module to the rest of the application. Identical whichever engine produced it.
public struct WakeWordEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let keyword: WakeKeyword
    public let engineID: String
    /// Engine score, when the engine reports one.
    public let confidence: Float?
    /// Sequence number of the audio frame in which the keyword ended.
    public let frameSequence: UInt64
    /// Capture time of the end of that frame.
    public let audioEndTime: HostTime
    /// When the engine reported the detection.
    public let engineReturnTime: HostTime
    /// Wall-clock time, for display and exported logs.
    public let wallClock: Date

    public init(
        id: UUID = UUID(),
        keyword: WakeKeyword,
        engineID: String,
        confidence: Float?,
        frameSequence: UInt64,
        audioEndTime: HostTime,
        engineReturnTime: HostTime,
        wallClock: Date = Date()
    ) {
        self.id = id
        self.keyword = keyword
        self.engineID = engineID
        self.confidence = confidence
        self.frameSequence = frameSequence
        self.audioEndTime = audioEndTime
        self.engineReturnTime = engineReturnTime
        self.wallClock = wallClock
    }

    /// Seconds between the end of the audio that completed the keyword and the engine reporting
    /// it. Includes microphone buffering, resampling and inference — not the time the speaker
    /// needed to say the word.
    public var captureToDetectionLatency: Double {
        max(0, engineReturnTime.seconds(since: audioEndTime))
    }
}
