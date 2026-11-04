import Foundation

/// Brings speech to the level the network was trained on, whatever the microphone delivers.
///
/// The keyword model is **not level-blind**. The same "Jarvis" that it hears perfectly at a peak of −12 dBFS turns into Mandarin
/// syllables at −18 dBFS and into nothing at −30 — and a MacBook's microphone at arm's length delivers speech 20 dB below what a
/// speech synthesiser (or a close headset) produces. So the frames are scaled before the model sees them, by a gain that follows the
/// speech: it is set when a stretch of sound begins, from the loudest of the frames that begin it, and from then on it falls at once
/// when the speech gets louder and rises only gradually when it gets quieter, so that a trailing-off word is not blown up into the
/// noise. Quiet *noise* never reaches this: the activity gate keeps it away from the model altogether.
///
/// Two things keep a stray noise from spoiling this. A frame counts for its peak but for no more than a few times its RMS
/// (``Configuration/crestLimit``), because a click — a key pressed, a cup set down — is all peak and little energy, and must not hold
/// the gain down for the seconds in which the word arrives. And whatever the gain, no frame is made louder than the target, so a click
/// that opens a stretch is not blown up to full scale just because the speech around it needs a lot of gain.
///
/// Pure logic, like ``ActivityGate``: the engine feeds it what each frame counts for and its loudest sample, and applies the gain it returns.
public struct LevelNormaliser: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// The peak speech is brought to, in dBFS. Anywhere between −3 and −14 dBFS gave the same results in the evaluation (about 91–95 %
        /// of English voices heard with quiet speech, where it was 54 % without this stage); −6 leaves already loud speech untouched.
        public var targetPeakDecibels: Float = -6
        /// Never amplify by more than this: below it a sound is mostly noise, and amplifying it would only feed the model noise.
        public var maximumGainDecibels: Float = 30
        /// Never attenuate by more than this. Loud speech is left alone by default: nothing suggests the network minds it.
        public var maximumAttenuationDecibels: Float = 0
        /// How slowly the remembered peak fades when the speech gets quieter, as a half-life in frames (3 s at 10 frames a second).
        public var releaseHalfLifeFrames: Float = 30
        /// How fast the gain rises towards what a quieter peak asks for, as a fraction of the way per frame.
        public var riseFraction: Float = 0.3
        /// A frame counts for no more than this many times its RMS when the gain is chosen. A click — a key pressed, a cup set down — is
        /// all peak and almost no energy (a crest of 10–15); speech is not (3–5 in a 100 ms frame). Without the limit a click just before
        /// the word holds the gain down for seconds: at −10 dBFS, half a second ahead of it, 95.5 % of the English voices heard fell to
        /// 77.9 %; with it, about 90 %.
        public var crestLimit: Float = 4

        public init() {}
    }

    let configuration: Configuration
    /// The remembered peak of the current stretch of sound (linear, 0 before one has begun).
    private(set) var envelope: Float = 0
    /// The gain the remembered peak asks for.
    private(set) var gain: Float = 1
    /// The gain the latest frame actually got: ``gain``, but never enough to push that frame's own peak past the target.
    private(set) var applied: Float = 1

    init(_ configuration: Configuration = Configuration()) {
        var sane = configuration
        if !sane.targetPeakDecibels.isFinite { sane.targetPeakDecibels = Configuration().targetPeakDecibels }
        sane.targetPeakDecibels = min(0, max(-60, sane.targetPeakDecibels))
        sane.maximumGainDecibels = sane.maximumGainDecibels.isFinite ? min(60, max(0, sane.maximumGainDecibels)) : Configuration().maximumGainDecibels
        sane.maximumAttenuationDecibels = sane.maximumAttenuationDecibels.isFinite ? min(30, max(0, sane.maximumAttenuationDecibels)) : 0
        sane.releaseHalfLifeFrames = sane.releaseHalfLifeFrames.isFinite ? max(1, sane.releaseHalfLifeFrames) : Configuration().releaseHalfLifeFrames
        sane.riseFraction = sane.riseFraction.isFinite ? min(1, max(0.01, sane.riseFraction)) : Configuration().riseFraction
        sane.crestLimit = sane.crestLimit.isFinite ? min(1_000, max(1.5, sane.crestLimit)) : Configuration().crestLimit
        self.configuration = sane
    }

    private var target: Float { powf(10, configuration.targetPeakDecibels / 20) }

    /// What a frame counts for in the gain: its peak, but no more than `crestLimit` times its RMS (see ``Configuration/crestLimit``).
    /// Numbers that are not levels count for nothing.
    func level(peak: Float, rms: Float) -> Float {
        guard peak.isFinite, rms.isFinite else { return 0 }
        return min(max(0, peak), max(0, rms) * configuration.crestLimit)
    }

    /// What the remembered peak asks for, within the limits.
    private func wantedGain(forEnvelope envelope: Float) -> Float {
        guard envelope > 0 else { return 1 }
        let lowest = powf(10, -configuration.maximumAttenuationDecibels / 20)
        let highest = powf(10, configuration.maximumGainDecibels / 20)
        return min(highest, max(lowest, target / envelope))
    }

    /// The most gain a frame whose loudest sample is `peak` may get: the one that brings that sample to the target. A frame with no
    /// usable peak (silence, a number that is not one) is not limited.
    private func ceiling(forPeak peak: Float) -> Float {
        guard peak.isFinite, peak > 0 else { return powf(10, configuration.maximumGainDecibels / 20) }
        return wantedGain(forEnvelope: peak)
    }

    /// A stretch of sound begins. `level` is what the frames that open it (the lead-in and the first loud frame) count for in the gain
    /// (see ``level(peak:rms:)``), `peak` the loudest sample among them. Returns the gain for all of them.
    mutating func begin(level: Float, peak: Float) -> Float {
        envelope = level.isFinite ? max(0, level) : 0
        gain = wantedGain(forEnvelope: envelope)
        applied = min(gain, ceiling(forPeak: peak))
        return applied
    }

    /// The next frame of the same stretch of sound. Returns the gain the previous frame ended with and the one for this frame; the
    /// engine ramps between them across the frame so there is no step in the waveform.
    mutating func advance(level: Float, peak: Float) -> (from: Float, to: Float) {
        let fade = powf(0.5, 1 / configuration.releaseHalfLifeFrames)
        envelope = max(level.isFinite ? max(0, level) : 0, envelope * fade)
        let wanted = wantedGain(forEnvelope: envelope)
        // Quieter speech: the gain rises gradually. Louder: it drops at once.
        gain = wanted < gain ? wanted : gain + (wanted - gain) * configuration.riseFraction
        // Whatever the gain, a frame is never made louder than the target: a click that opens the stretch, or a peaky frame, is not
        // blown up to full scale just because the speech around it needs a lot of gain.
        let next = min(gain, ceiling(forPeak: peak))
        let previous = applied
        applied = next
        // A drop is for the whole frame: a ramp from the old, higher gain would blow its first samples up.
        return next < previous ? (next, next) : (previous, next)
    }

    /// ``begin(level:peak:)`` for a signal whose peaks are its levels.
    mutating func begin(peak: Float) -> Float { begin(level: peak, peak: peak) }

    /// ``advance(level:peak:)`` for a signal whose peaks are its levels.
    mutating func advance(peak: Float) -> (from: Float, to: Float) { advance(level: peak, peak: peak) }
}
