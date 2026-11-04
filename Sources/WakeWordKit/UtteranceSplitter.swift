import Foundation

/// Finds the stretches of a recording where someone is speaking, so that one long take of "Jarvis … Jarvis … Jarvis" becomes one
/// clip per utterance (what the voice-learning tools work from) and a live recording can tell when a phrase has just been said.
/// A stretch ends at a pause of at least `pause` seconds; each clip keeps a little of the room around it. Levels are relative to the
/// recording's own noise floor, so a quiet microphone and a noisy room are both handled; a recording with no pause in it (one
/// trimmed word) comes back whole.
///
/// Everything is in 20 ms frames (``framesPerSecond``): ``frameLevels(_:sampleRate:)`` measures them, ``ranges(levels:floor:pause:shortest:)``
/// finds the stretches, ``split(_:sampleRate:pause:shortest:longest:)`` cuts the clips.
public enum UtteranceSplitter {
    public static let framesPerSecond = 50
    /// Room kept before and after a stretch when it is cut out, in seconds.
    public static let marginBefore = 0.3
    public static let marginAfter = 0.4
    /// A frame counts as sound when it is this many decibels above the room (and above ``minimumThresholdDecibels``).
    public static let marginAboveFloorDecibels: Float = 10
    public static let minimumThresholdDecibels: Float = -55

    /// The level of each 20 ms frame, in dBFS (−120 for a frame of numbers that are not audio).
    public static func frameLevels(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        let hop = sampleRate / framesPerSecond
        guard hop > 0 else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / hop)
        var index = 0
        while index + hop <= samples.count {
            var sum: Float = 0
            for sample in samples[index..<index + hop] { sum += sample * sample }
            let rms = (sum / Float(hop)).squareRoot()
            levels.append(rms.isFinite ? 20 * log10(max(rms, 1e-6)) : -120)
            index += hop
        }
        return levels
    }

    /// The level of the room: the quietest tenth of the frames, which a conversation does not drag up.
    public static func noiseFloor(of levels: [Float]) -> Float {
        guard !levels.isEmpty else { return -120 }
        let sorted = levels.sorted()
        return sorted[sorted.count / 10]
    }

    /// The level a frame must exceed to count as sound, given the room's.
    public static func threshold(floor: Float) -> Float {
        max(floor + marginAboveFloorDecibels, minimumThresholdDecibels)
    }

    /// The stretches of `levels` (frame indices, end exclusive) that stand out from the room, with gaps shorter than `pause` seconds
    /// closed and stretches shorter than `shortest` seconds dropped. `floor` is the room's level; by default it is estimated from
    /// `levels` themselves, which needs a recording that has some quiet in it.
    public static func ranges(levels: [Float], floor: Float? = nil, pause: Double = 0.45, shortest: Double = 0.25) -> [Range<Int>] {
        guard !levels.isEmpty else { return [] }
        let threshold = threshold(floor: floor ?? noiseFloor(of: levels))
        let gap = Int(min(600, max(0, pause.isFinite ? pause : 0.45)) * Double(framesPerSecond))
        var runs: [(start: Int, end: Int)] = []
        var current: (start: Int, end: Int)?
        for (frame, level) in levels.enumerated() where level > threshold {
            if let open = current, frame - open.end <= gap { current = (open.start, frame) } else {
                if let open = current { runs.append(open) }
                current = (frame, frame)
            }
        }
        if let open = current { runs.append(open) }
        return runs
            .filter { Double($0.end - $0.start + 1) / Double(framesPerSecond) >= shortest }
            .map { $0.start..<$0.end + 1 }
    }

    /// Cuts `samples` into the stretches where someone speaks, each with a little room around it. A recording in which nothing stands
    /// out (one trimmed word, or constant sound) comes back whole — in pieces no longer than `longest` seconds, so that a long
    /// stretch of constant sound is not mistaken for one enormous utterance; a stretch longer than `longest` is cut short.
    public static func split(
        _ samples: [Float], sampleRate: Int = 16_000, pause: Double = 0.45, shortest: Double = 0.25, longest: Double = 12
    ) -> [[Float]] {
        let hop = sampleRate / framesPerSecond
        let limit = Int(min(3_600, max(0.1, longest.isFinite ? longest : 12)) * Double(sampleRate))
        guard hop > 0, samples.count >= hop * 5 else { return samples.isEmpty ? [] : [samples] }
        let levels = frameLevels(samples, sampleRate: sampleRate)
        let found = ranges(levels: levels, pause: pause, shortest: shortest)
        guard !found.isEmpty else {
            guard limit > 0, samples.count > limit else { return [samples] }
            return stride(from: 0, to: samples.count, by: limit).map { Array(samples[$0..<min($0 + limit, samples.count)]) }
        }
        return found.map { clip(of: $0, in: samples, frameCount: levels.count, sampleRate: sampleRate, longest: longest) }
    }

    /// The samples of one stretch with its margins, no longer than `longest` seconds.
    public static func clip(of range: Range<Int>, in samples: [Float], frameCount: Int, sampleRate: Int = 16_000, longest: Double = 12) -> [Float] {
        let hop = sampleRate / framesPerSecond
        let limit = Int(min(3_600, max(0.1, longest.isFinite ? longest : 12)) * Double(sampleRate))
        let before = Int(marginBefore * Double(framesPerSecond)), after = Int(marginAfter * Double(framesPerSecond))
        let start = max(0, range.lowerBound - before) * hop
        let end = min(frameCount, range.upperBound + after) * hop
        guard start < end, start < samples.count else { return [] }
        let clip = Array(samples[start..<min(end, samples.count)])
        return clip.count > limit ? Array(clip.prefix(limit)) : clip
    }
}
