import Darwin
import Foundation

/// The engine-independent detection hot path:
///
///     microphone chunk ─► resample to the engine's rate ─► cut into engine-sized frames
///         ─► engine.processAudio ─► validator (debounce / cooldown / holdoff) ─► event
///
/// Nothing here knows which engine is installed, and nothing in the engine knows about the
/// microphone. Engines can be swapped at any time without touching capture: `install(_:)` swaps
/// the engine under the same lock the audio thread takes, so a chunk is processed entirely by the
/// old engine or entirely by the new one.
///
/// ### Threading
/// `ingest` is called from the capture thread; everything else from the supervisor. All state is
/// guarded by one unfair lock, held for the duration of one chunk (tens of microseconds). The
/// `sink` is always invoked *after* the lock is released, so it may call back into the pipeline.
public final class WakeWordPipeline: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var validation: DetectionValidator.Configuration
        /// Stop feeding the engine the instant a detection is accepted, so one utterance can never
        /// produce a second activation. The supervisor lifts the gate when the session ends.
        public var gateOnAcceptedDetection: Bool
        /// After this many consecutive frame failures the engine is considered faulted.
        public var maxConsecutiveEngineFailures: Int
        /// Seconds of audio retained for a ``DetectionVerifier``; 0 retains nothing.
        public var preRollDuration: Double

        public init(
            validation: DetectionValidator.Configuration = .init(),
            gateOnAcceptedDetection: Bool = true,
            maxConsecutiveEngineFailures: Int = 5,
            preRollDuration: Double = 0
        ) {
            self.validation = validation
            self.gateOnAcceptedDetection = gateOnAcceptedDetection
            self.maxConsecutiveEngineFailures = maxConsecutiveEngineFailures
            self.preRollDuration = preRollDuration
        }
    }

    public enum Event: Sendable {
        /// A detection passed validation. The pipeline is gated if `gateOnAcceptedDetection` is set.
        case detection(WakeWordEvent, preRoll: [Float]?, sampleRate: Int)
        /// A detection was ignored (kept for diagnostics and accuracy testing).
        case suppressed(keyword: WakeKeyword, reason: DetectionValidator.Rejection, at: HostTime)
        /// The engine failed repeatedly and has been taken out of service until reinstalled. `engine`
        /// identifies the instance that faulted, so a late event about an engine that has since been
        /// replaced can be recognised as stale.
        case engineFault(WakeWordError, engine: ObjectIdentifier)
    }

    /// Receives a copy of every microphone buffer, before any processing: the samples (valid only for the call) and their sample rate.
    public typealias AudioTap = @Sendable (_ samples: UnsafeBufferPointer<Float>, _ sampleRate: Double) -> Void

    private let lock = UnfairLock()
    private let sink: @Sendable (Event) -> Void

    // Everything below is guarded by `lock`.
    private var configuration: Configuration
    private var validator: DetectionValidator
    private var engine: (any WakeWordEngine)?
    private var requirements = AudioRequirements(sampleRate: 16_000, frameLength: 512)
    private var resampler: StreamingResampler?
    private var assembler = FrameAssembler(frameLength: 512)
    private var preRoll = PreRollBuffer(capacity: 0)
    private var resampled: [Float] = []
    private var isGated = false
    private var tap: AudioTap?
    private var pendingHoldoff: Double?
    private var nextSequence: UInt64 = 0
    private var consecutiveFailures = 0
    private var faulted = false
    private var stats = PipelineStatistics()

    public init(configuration: Configuration = .init(), sink: @escaping @Sendable (Event) -> Void) {
        self.configuration = configuration
        self.validator = DetectionValidator(configuration: configuration.validation)
        self.sink = sink
    }

    // MARK: - Engine management

    /// Installs `engine` (already initialised) and returns the engine it replaces, which the caller
    /// must `shutdown()`. Audio resumes with the new engine on the next chunk.
    @discardableResult
    public func install(_ newEngine: any WakeWordEngine) throws(WakeWordError) -> (any WakeWordEngine)? {
        let newRequirements = newEngine.audioRequirements
        guard newRequirements.isValid else {
            throw .invalidConfiguration("engine \(newEngine.identifier) declared unusable audio requirements \(newRequirements)")
        }
        return lock.withLock {
            let previous = engine
            engine = newEngine
            requirements = newRequirements
            resampler = nil
            assembler = FrameAssembler(frameLength: newRequirements.frameLength)
            resampled.reserveCapacity(newRequirements.sampleRate)
            preRoll = PreRollBuffer(capacity: Int(configuration.preRollDuration * Double(newRequirements.sampleRate)))
            nextSequence = 0
            consecutiveFailures = 0
            faulted = false
            stats.hasEngine = true
            return previous
        }
    }

    /// Removes the engine (if any) and returns it; the caller must `shutdown()` it.
    @discardableResult
    public func uninstall() -> (any WakeWordEngine)? {
        lock.withLock {
            let previous = engine
            engine = nil
            resampler = nil
            assembler.reset()
            preRoll.reset()
            stats.hasEngine = false
            return previous
        }
    }

    /// Forwards a sensitivity change to the installed engine, serialised against processing.
    public func updateSensitivity(_ value: Float) throws(WakeWordError) {
        try lock.withLock { () throws(WakeWordError) -> Void in
            guard let engine else { throw .notInitialized }
            try engine.updateSensitivity(value)
        }
    }

    // MARK: - Control

    /// Gates (suspends) or resumes detection. While gated, chunks are discarded without any
    /// processing. On resume the DSP state is cleared and, if `holdoff` is non-zero, detections are
    /// ignored for that many seconds of *audio* after the first new chunk — long enough for the
    /// tail of synthesised speech to die away.
    public func setGated(_ gated: Bool, holdoff: Double = 0) {
        lock.withLock {
            if gated {
                isGated = true
            } else if isGated {
                isGated = false
                resampler?.reset()
                assembler.reset()
                preRoll.reset()
                pendingHoldoff = holdoff > 0 ? holdoff : nil
            }
            stats.isGated = isGated
        }
    }

    /// Hands every microphone buffer to `tap` from now on (nil: stop). It runs on the capture thread, after the pipeline has done its
    /// own work and with the pipeline's lock released, so it must be quick and must not block. It sees the audio whether or not an
    /// engine is installed or the pipeline is gated — it is how the app records what the person says while they teach it their voice.
    public func setAudioTap(_ newTap: AudioTap?) {
        lock.withLock { tap = newTap }
    }

    public func updateConfiguration(_ newConfiguration: Configuration) {
        lock.withLock {
            let preRollChanged = newConfiguration.preRollDuration != configuration.preRollDuration
            configuration = newConfiguration
            validator.configuration = newConfiguration.validation
            if preRollChanged {
                preRoll = PreRollBuffer(capacity: Int(newConfiguration.preRollDuration * Double(requirements.sampleRate)))
            }
        }
    }

    /// Forgets cooldown/debounce history.
    public func resetValidation() {
        lock.withLock { validator.reset() }
    }

    public func statistics() -> PipelineStatistics {
        lock.withLock { stats }
    }

    public func resetStatistics() {
        lock.withLock {
            let hasEngine = stats.hasEngine
            let gated = stats.isGated
            stats = PipelineStatistics()
            stats.hasEngine = hasEngine
            stats.isGated = gated
        }
    }

    // MARK: - Hot path

    /// Feeds one microphone chunk (mono `Float`, any sample rate). Call from the capture thread.
    /// `hostTime` is the capture time of the first sample.
    public func ingest(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, hostTime: HostTime) {
        var outgoing: [Event] = []
        var currentTap: AudioTap?
        lock.withLock {
            currentTap = tap
            ingestLocked(samples, sampleRate: sampleRate, hostTime: hostTime, outgoing: &outgoing)
        }
        for event in outgoing { sink(event) }
        currentTap?(samples, sampleRate)
    }

    public func ingest(_ samples: [Float], sampleRate: Double, hostTime: HostTime) {
        samples.withUnsafeBufferPointer { ingest($0, sampleRate: sampleRate, hostTime: hostTime) }
    }

    /// Developer aid: pushes a synthetic detection through validation exactly as if the engine had
    /// reported it, so the activation flow can be exercised without speaking.
    public func injectDetection(_ result: DetectionResult, at time: HostTime = .now) {
        var outgoing: [Event] = []
        lock.withLock {
            guard !isGated else { return }
            _ = handleDetection(
                result,
                engineID: engine?.identifier ?? "simulated",
                sequence: nextSequence,
                audioEnd: time,
                returnTime: time,
                outgoing: &outgoing
            )
        }
        for event in outgoing { sink(event) }
    }

    // MARK: - Locked helpers

    private func ingestLocked(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        hostTime: HostTime,
        outgoing: inout [Event]
    ) {
        stats.chunksIngested &+= 1
        stats.level = AudioLevel.measure(samples)

        // A buffer claiming a nonsensical rate (0, NaN, negative) must be dropped, not turned into a
        // resampler whose preconditions would trap on the audio thread and take the app down — and it must
        // not be published as "the input rate" either: Diagnostics formats that number as an integer.
        guard sampleRate.isFinite, sampleRate >= 1_000, sampleRate <= 768_000 else {
            stats.chunksDiscarded &+= 1
            return
        }
        stats.inputSampleRate = sampleRate

        guard !isGated, !faulted, let engine else {
            stats.chunksDiscarded &+= 1
            return
        }

        if let holdoff = pendingHoldoff {
            validator.beginHoldoff(until: hostTime.advanced(bySeconds: holdoff))
            pendingHoldoff = nil
        }

        let outputRate = Double(requirements.sampleRate)
        if resampler == nil || resampler?.inputRate != sampleRate || resampler?.outputRate != outputRate {
            resampler = StreamingResampler(inputRate: sampleRate, outputRate: outputRate)
            assembler.reset()
        }
        resampled.removeAll(keepingCapacity: true)
        resampler?.process(samples, appendingTo: &resampled)

        let frameLength = requirements.frameLength
        let sampleRateInt = requirements.sampleRate
        let carry = assembler.pendingCount
        var emitted = 0
        var stop = false

        assembler.append(resampled) { frameSamples in
            defer { emitted += 1 }
            guard !stop else { return }
            let offsetSeconds = Double(emitted * frameLength - carry) / outputRate
            let frame = AudioFrame(
                samples: frameSamples,
                sampleRate: sampleRateInt,
                sequence: nextSequence,
                captureTime: hostTime.advanced(bySeconds: offsetSeconds)
            )
            nextSequence &+= 1
            if preRoll.capacity > 0 { preRoll.append(frameSamples) }
            if processFrame(frame, with: engine, outgoing: &outgoing) {
                stop = true
            }
        }

        if stop || isGated || faulted {
            assembler.reset()
            resampler?.reset()
        }
    }

    /// Returns true when no further frames of this chunk should be processed.
    private func processFrame(_ frame: AudioFrame, with engine: any WakeWordEngine, outgoing: inout [Event]) -> Bool {
        let started = mach_absolute_time()
        let result: DetectionResult?
        do {
            result = try engine.processAudio(frame)
            consecutiveFailures = 0
        } catch {
            stats.engineErrors &+= 1
            consecutiveFailures += 1
            if consecutiveFailures >= configuration.maxConsecutiveEngineFailures {
                faulted = true
                outgoing.append(.engineFault(error, engine: ObjectIdentifier(engine)))
            }
            return faulted
        }
        let returned = HostTime(ticks: mach_absolute_time())
        stats.framesProcessed &+= 1
        stats.engineProcessTime.record(returned.seconds(since: HostTime(ticks: started)))

        guard let result else { return false }
        return handleDetection(
            result,
            engineID: engine.identifier,
            sequence: frame.sequence,
            audioEnd: frame.endTime,
            returnTime: returned,
            outgoing: &outgoing
        )
    }

    /// Returns true when the pipeline gated itself because the detection was accepted.
    private func handleDetection(
        _ result: DetectionResult,
        engineID: String,
        sequence: UInt64,
        audioEnd: HostTime,
        returnTime: HostTime,
        outgoing: inout [Event]
    ) -> Bool {
        switch validator.evaluate(result, at: audioEnd) {
        case .accept:
            let event = WakeWordEvent(
                keyword: result.keyword,
                engineID: engineID,
                confidence: result.confidence,
                frameSequence: sequence,
                audioEndTime: audioEnd,
                engineReturnTime: returnTime
            )
            stats.detectionsAccepted &+= 1
            stats.captureToDetectionLatency.record(event.captureToDetectionLatency)
            let retained = preRoll.capacity > 0 ? preRoll.snapshot() : nil
            outgoing.append(.detection(event, preRoll: retained, sampleRate: requirements.sampleRate))
            if configuration.gateOnAcceptedDetection {
                isGated = true
                stats.isGated = true
                return true
            }
            return false
        case .reject(let reason):
            stats.detectionsSuppressed &+= 1
            outgoing.append(.suppressed(keyword: result.keyword, reason: reason, at: audioEnd))
            return false
        }
    }
}
