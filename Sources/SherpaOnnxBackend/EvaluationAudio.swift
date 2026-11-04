import Foundation
import WakeWordKit

/// How the learning and evaluation tools present audio to an engine: the way a microphone would deliver it, deterministically, so that
/// two runs hear exactly the same thing.
public enum EvaluationAudio {
    /// A number that depends only on what is in `clip` (a hash of a few dozen of its samples), so that the same recording is always heard
    /// with the same room noise around it, wherever it sits in a list. (The network is brittle: a different noise pattern can turn a
    /// "Jarvis" heard as English sounds into Mandarin syllables, so comparing two runs that used different noise compares noise.)
    public static func contentSeed(_ clip: [Float]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) { hash = (hash ^ value) &* 0x100_0000_01b3 }
        mix(UInt64(clip.count))
        let step = max(1, clip.count / 64)
        var index = 0
        while index < clip.count { mix(UInt64(clip[index].bitPattern)); index += step }
        return hash
    }

    /// `samples` with deterministic room noise of peak `level` added. Synthesised audio has *digital* silence between words, which no
    /// microphone ever delivers; a model fed exact zeros is outside what it was trained on.
    public static func roomNoise(_ samples: [Float], level: Float, seed: UInt64) -> [Float] {
        guard level > 0 else { return samples }
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        return samples.map { sample in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(Int64(bitPattern: state >> 11) & 0xFFFFF) / Float(0xFFFFF) * 2 - 1
            return sample + unit * level
        }
    }

    /// A click: 12 ms of noise that dies away in a few milliseconds, at `decibels` dBFS, followed by silence until `gap` seconds after it began.
    public static func clickLead(decibels: Float, gap: Double) -> [Float] {
        let burst = roomNoise([Float](repeating: 0, count: 192), level: 1, seed: 77).enumerated().map { $0.element * expf(-Float($0.offset) / 40) }
        let peak = burst.reduce(0) { max($0, abs($1)) }
        let shaped = peak > 0 ? burst.map { $0 / peak * powf(10, decibels / 20) } : burst
        return shaped + [Float](repeating: 0, count: max(0, Int(gap * 16_000) - shaped.count))
    }

    /// Runs `clip` through `engine` as a fresh stream, with half a second of room before it and a second after, and returns the times (in
    /// seconds from the start of the audio) at which the engine reported the word.
    public static func feed(
        _ clip: [Float], through engine: SherpaOnnxWakeWordEngine, sensitivity: Float, noise: Float = 0, seed: UInt64 = 1,
        click: (decibels: Float, gap: Double)? = nil
    ) throws(WakeWordError) -> [Double] {
        try engine.updateSensitivity(sensitivity)   // a fresh stream: nothing carries over from the previous clip
        let frameLength = engine.audioRequirements.frameLength
        let lead = click.map { clickLead(decibels: $0.decibels, gap: $0.gap) } ?? []
        let padded = roomNoise([Float](repeating: 0, count: 8_000) + lead + clip + [Float](repeating: 0, count: 16_000), level: noise, seed: seed)
        var detections: [Double] = []
        var index = 0
        var sequence: UInt64 = 0
        while index + frameLength <= padded.count {
            let frame = AudioFrame(
                samples: Array(padded[index..<index + frameLength]), sampleRate: 16_000, sequence: sequence,
                captureTime: HostTime(seconds: Double(index) / 16_000)
            )
            if try engine.processAudio(frame) != nil { detections.append(Double(index + frameLength) / 16_000) }
            index += frameLength
            sequence += 1
        }
        return detections
    }
}
