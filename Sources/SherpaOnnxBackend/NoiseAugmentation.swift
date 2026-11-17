import Foundation

/// Noisy copies of the person's recordings, so the pronunciations the tuner keeps also hear "Jarvis" over a TV, music or
/// people talking — not only in the quiet room the lesson was recorded in.
///
/// Every copy is deterministic (seeded from the clip's content), so two runs of the tuner compare like with like. The
/// background is one of:
///  * **babble** — a stretch of ordinary speech (the reference voices or the person's own reading), 8–12 dB below the word;
///  * **music** — a synthetic band (chords, bass, a kick and hi-hat at 100–130 bpm), 6–10 dB below the word;
///  * **noise** — pink noise (fans, traffic, air conditioning), 10–14 dB below the word;
/// with the whole copy's level moved ±6 dB, as a voice nearer or further from the microphone would be.
public enum NoiseAugmentation {
    public enum Background: String, CaseIterable, Sendable { case babble, music, noise }

    /// A noisy copy of `clip` (16 kHz mono). `speech` supplies the babble; without it, babble becomes pink noise.
    public static func augment(_ clip: [Float], background: Background, speech: [[Float]], seed: UInt64) -> [Float] {
        var random = SeededRandom(seed: seed)
        let pad = 4_800  // 0.3 s of background before and after the word
        var padded = [Float](repeating: 0, count: pad) + clip + [Float](repeating: 0, count: pad)
        let signal = activeRMS(clip)
        guard signal > 0 else { return padded }
        var bed: [Float]
        let snr: Float
        switch background {
        case .babble where !speech.isEmpty:
            bed = babble(length: padded.count, speech: speech, random: &random)
            snr = random.float(in: 8...12)
        case .music:
            bed = music(length: padded.count, random: &random)
            snr = random.float(in: 6...10)
        case .babble, .noise:
            bed = pinkNoise(length: padded.count, random: &random)
            snr = random.float(in: 10...14)
        }
        let bedRMS = rms(bed)
        if bedRMS > 0 {
            let scale = signal / powf(10, snr / 20) / bedRMS
            for index in padded.indices { padded[index] += bed[index] * scale }
        }
        let gain = powf(10, random.float(in: -6...6) / 20)
        let peak = padded.reduce(0) { max($0, abs($1)) } * gain
        let limit: Float = peak > 0.98 ? 0.98 / peak : 1
        return padded.map { $0 * gain * limit }
    }

    /// Which background the `index`-th copy gets: they rotate, so every kind is represented.
    public static func background(for index: Int) -> Background { Background.allCases[index % Background.allCases.count] }

    // MARK: Backgrounds

    static func babble(length: Int, speech: [[Float]], random: inout SeededRandom) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        // Two overlapping talkers sound like a room; one sounds like a single interrupting voice. Use both.
        for _ in 0..<2 {
            let source = speech[random.int(below: speech.count)]
            guard !source.isEmpty else { continue }
            var position = random.int(below: max(1, source.count))
            for index in 0..<length {
                out[index] += source[position]
                position += 1
                if position >= source.count { position = 0 }
            }
        }
        return out
    }

    static func music(length: Int, random: inout SeededRandom) -> [Float] {
        let rate: Float = 16_000
        let bpm = random.float(in: 100...130)
        let beat = Int(rate * 60 / bpm)
        // A I–V–vi–IV progression in a random key; each chord lasts two beats.
        let root = 196 * powf(2, Float(random.int(below: 7)) / 12)  // G3 … C#4
        let progression: [[Float]] = [[0, 4, 7], [7, 11, 14], [9, 12, 16], [5, 9, 12]]
        var out = [Float](repeating: 0, count: length)
        var phase = [Float](repeating: 0, count: 4)
        for index in 0..<length {
            let chord = progression[(index / (beat * 2)) % progression.count]
            var sample: Float = 0
            for (voice, semitone) in chord.enumerated() {
                let frequency = root * powf(2, semitone / 12)
                phase[voice] += 2 * .pi * frequency / rate
                if phase[voice] > 2 * .pi { phase[voice] -= 2 * .pi }
                // A soft square-ish tone (fundamental plus odd harmonics) is closer to a real mix than a pure sine.
                sample += 0.3 * (sinf(phase[voice]) + sinf(3 * phase[voice]) / 3 + sinf(5 * phase[voice]) / 5)
            }
            let bassFrequency = root / 2 * powf(2, chord[0] / 12)
            phase[3] += 2 * .pi * bassFrequency / rate
            if phase[3] > 2 * .pi { phase[3] -= 2 * .pi }
            sample += 0.5 * sinf(phase[3])
            // Kick on every beat, hi-hat on the off-beats.
            let inBeat = index % beat
            if inBeat < 1_600 { sample += 0.9 * sinf(2 * .pi * 55 * Float(inBeat) / rate) * expf(-Float(inBeat) / 400) }
            let offBeat = (index + beat / 2) % beat
            if offBeat < 480 { sample += 0.25 * random.float(in: -1...1) * expf(-Float(offBeat) / 80) }
            out[index] = sample
        }
        return out
    }

    static func pinkNoise(length: Int, random: inout SeededRandom) -> [Float] {
        // Paul Kellet's economy filter.
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        return (0..<length).map { _ in
            let white = random.float(in: -1...1)
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            return b0 + b1 + b2 + white * 0.1848
        }
    }

    // MARK: Levels

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// RMS over the loud part of the clip (20 ms frames within 30 dB of the loudest), so silence around the word does
    /// not make the word look quiet.
    static func activeRMS(_ clip: [Float]) -> Float {
        let frame = 320
        var levels: [Float] = []
        var index = 0
        while index + frame <= clip.count {
            levels.append(rms(Array(clip[index..<index + frame])))
            index += frame
        }
        guard let loudest = levels.max(), loudest > 0 else { return rms(clip) }
        let active = levels.filter { $0 > loudest * 0.0316 }
        return (active.reduce(0) { $0 + $1 * $1 } / Float(max(1, active.count))).squareRoot()
    }
}

/// A small deterministic generator (SplitMix64).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * Float(next() >> 40) / Float(1 << 24)
    }
    mutating func int(below bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
}
