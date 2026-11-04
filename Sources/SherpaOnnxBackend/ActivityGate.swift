import Foundation
import WakeWordKit

/// A very cheap "is anything happening?" detector placed in front of the neural keyword model.
///
/// The model costs a little over a millisecond of CPU per 100 ms of audio — small, but it adds up when it runs all day
/// on a silent room. Almost all of that audio is silence, in which no one can have said anything, so the gate keeps
/// the model idle until the sound level rises above what the room normally sounds like:
///
/// * the **noise floor** is a low percentile of the last few seconds of frame levels, so a conversation does not
///   drag it up (speech filling most of those seconds below −48 dBFS still can: that is a limit of the design);
/// * the gate **opens** when a frame is `margin` louder than that floor — or louder than `openAbove` outright, so in a
///   room that is always noisy it simply stays open and the model hears everything, as without a gate;
/// * it stays open for `hangoverFrames` after the last loud frame, because the model needs to hear what follows the
///   word before it commits to a decision.
public struct ActivityGate: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Decibels above the room's noise floor that count as "something happening".
        public var marginDecibels: Float = 8
        /// A level (dBFS, per-frame RMS) that always counts, whatever the floor is.
        public var openAboveDecibels: Float = -48
        /// Frames the gate stays open after the last loud one (100 ms each).
        public var hangoverFrames = 15
        /// How many recent frames the noise floor is estimated from (10 s).
        public var floorWindowFrames = 100
        /// Which of the recent levels counts as the floor (0.2 = the 20th percentile).
        public var floorPercentile: Float = 0.2
        /// Frames of audio kept from *before* the gate opened, so the start of a word is not lost.
        public var preRollFrames = 6

        public init() {}
    }

    let configuration: Configuration
    private(set) var isOpen = false
    private(set) var noiseFloorDecibels: Float = -120
    private var levels: [Float] = []
    private var cursor = 0
    private var quietFrames = 0

    init(_ configuration: Configuration = Configuration()) {
        // Nonsense settings (a percentile outside 0…1, no history, a negative count) would trap or never settle: clamp them.
        var sane = configuration
        sane.floorPercentile = sane.floorPercentile.isFinite ? min(1, max(0, sane.floorPercentile)) : Configuration().floorPercentile
        sane.floorWindowFrames = max(1, sane.floorWindowFrames)
        sane.hangoverFrames = max(0, sane.hangoverFrames)
        sane.preRollFrames = max(0, sane.preRollFrames)
        self.configuration = sane
    }

    /// Feeds one frame's level (dBFS) and returns whether the gate is open for that frame. A level that is not a number
    /// (NaN, infinity) tells the gate nothing: it is ignored and the gate stays as it was.
    mutating func update(levelDecibels level: Float) -> Bool {
        guard level.isFinite else { return isOpen }
        if levels.isEmpty {
            // Until history accumulates, the first frame stands in for the room.
            levels = [Float](repeating: level, count: max(1, configuration.floorWindowFrames))
        } else {
            levels[cursor] = level
            cursor = (cursor + 1) % levels.count
        }
        let sorted = levels.sorted()
        noiseFloorDecibels = sorted[min(sorted.count - 1, Int(Float(sorted.count) * configuration.floorPercentile))]

        if level > noiseFloorDecibels + configuration.marginDecibels || level > configuration.openAboveDecibels {
            isOpen = true
            quietFrames = 0
        } else if isOpen {
            quietFrames += 1
            if quietFrames > configuration.hangoverFrames { isOpen = false }
        }
        return isOpen
    }
}
