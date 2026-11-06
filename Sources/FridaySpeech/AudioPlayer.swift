import Foundation
import AVFoundation
import os

/// Plays synthesised speech chunks as they arrive, with immediate cancellation (barge-in, "stop").
///
/// `play()` never waits for ever: when the output device changes under it (AirPods connect, headphones are plugged
/// in, a display with speakers appears) the engine stops and posts `AVAudioEngineConfigurationChange`; the player
/// then reconnects to the new output and continues from the sentence that was interrupted, or, when the engine
/// cannot restart, gives the utterance up and `play()` returns `false`. A stop that comes without a notification is
/// caught either by the completion callbacks the engine fires as it stops (they arrive with the engine not running
/// and count as an interruption, not as progress) or by a watchdog that allows the scheduled audio its own length
/// plus a grace period.
public actor SpeechPlayer {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "tts.player")
    /// How long past the end of the scheduled audio `play()` keeps waiting for the last completion before it
    /// decides playback has stalled.
    public static let stallGrace: Duration = .seconds(3)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attachedRate: Double = 0
    /// Bumped by `stop()` and by a failed recovery: `play()` calls and completion callbacks from an older
    /// generation are void.
    private var generation = 0
    /// Bumped when the player node is stopped and restarted within one utterance: the completion callbacks the
    /// stop fires for the cleared buffers carry the old epoch and are ignored.
    private var epoch = 0
    private var scheduled = 0
    private var completed = 0
    /// Buffers scheduled and not yet reported as played back, oldest first; what a restart re-schedules.
    private var pending: [AVAudioPCMBuffer] = []
    private var utteranceRate: Double = 0
    private var finishedScheduling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watchdog: Task<Void, Never>?
    private var configurationObserver: NotificationObserver?
    public private(set) var isPlaying = false
    /// Utterances that continued on a new output device, and ones given up (diagnostics and tests).
    public private(set) var recoveries = 0
    public private(set) var failures = 0
    public var volume: Float = 1 {
        didSet { player.volume = volume }
    }
    /// Called when playback of an utterance ends (completed or cancelled).
    public var onStateChange: (@Sendable (Bool) -> Void)?

    public init() {
        engine.attach(player)
    }

    /// The engine posts `AVAudioEngineConfigurationChange` when the output hardware changed and it stopped itself.
    /// The handler hops onto the actor; the engine is never torn down inside the notification (the SDK forbids it),
    /// only restarted. Registered on first use rather than in `init`, where `self` may not be captured.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationObserver(name: .AVAudioEngineConfigurationChange, object: engine) { [weak self] in
            Task { await self?.engineConfigurationChanged() }
        }
    }

    private func prepare(sampleRate: Double) throws {
        observeConfigurationChanges()
        if engine.isRunning, attachedRate == sampleRate { return }
        if engine.isRunning { engine.stop() }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        attachedRate = sampleRate
        try engine.start()
    }

    /// Plays every chunk of `chunks`; returns when the audio finished, `stop()` was called, or playback could not
    /// go on (output device lost, engine stalled). Returns `true` if the utterance played to the end.
    @discardableResult
    public func play(_ chunks: AsyncThrowingStream<AudioChunk, any Error>) async throws -> Bool {
        generation += 1
        let myGeneration = generation
        epoch += 1
        scheduled = 0
        completed = 0
        pending.removeAll()
        finishedScheduling = false
        isPlaying = true
        onStateChange?(true)
        defer {
            if generation == myGeneration {
                isPlaying = false
                onStateChange?(false)
            }
        }
        var started = false
        do {
            for try await chunk in chunks {
                guard generation == myGeneration else { return false }
                guard !chunk.samples.isEmpty else { continue }
                if !started {
                    utteranceRate = Double(chunk.sampleRate)
                    try prepare(sampleRate: utteranceRate)
                    player.volume = volume
                    player.play()
                    started = true
                }
                guard let buffer = Self.buffer(for: chunk) else { continue }
                scheduled += 1
                schedule(buffer, generation: myGeneration)
            }
        } catch {
            if generation == myGeneration { player.stop() }
            throw error
        }
        guard started, generation == myGeneration else { return false }
        finishedScheduling = true
        if completed >= scheduled { return true }
        armWatchdog(generation: myGeneration)
        await withCheckedContinuation { waiters.append($0) }
        return generation == myGeneration
    }

    static func buffer(for chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.samples.count)
        }
        return buffer
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, generation: Int) {
        let myEpoch = epoch
        pending.append(buffer)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { await self?.bufferCompleted(generation: generation, epoch: myEpoch) }
        }
    }

    private func bufferCompleted(generation: Int, epoch: Int) {
        guard generation == self.generation, epoch == self.epoch else { return }
        guard engine.isRunning else {
            // The engine fires the pending completions as it stops; that is an interruption, not playback.
            Self.logger.notice("audio engine stopped under an utterance; recovering")
            recover()
            return
        }
        if !pending.isEmpty { pending.removeFirst() }
        completed += 1
        if finishedScheduling, completed >= scheduled { resumeWaiters() }
    }

    /// Seconds of audio scheduled and not yet played back (an upper bound: the first buffer may be part way).
    private var pendingSeconds: Double {
        pending.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    }

    /// Gives the pending audio its own length plus `stallGrace`; a `play()` still waiting after that is abandoned.
    private func armWatchdog(generation: Int) {
        watchdog?.cancel()
        let deadline = Duration.seconds(pendingSeconds) + Self.stallGrace
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            await self?.playbackStalled(generation: generation)
        }
    }

    private func playbackStalled(generation: Int) {
        guard generation == self.generation, !waiters.isEmpty else { return }
        Self.logger.error("audio playback stalled (no completion within \(Self.stallGrace) of the end of the audio); giving the utterance up")
        if engine.isRunning { engine.stop() }
        attachedRate = 0
        fail()
    }

    /// The engine reported a change of output hardware (it has stopped). Reconnect and continue the utterance, if any.
    func engineConfigurationChanged() {
        // A completion callback that found the engine stopped may have restarted it already (the notification
        // arrives after those callbacks); a running engine needs nothing more.
        guard !engine.isRunning else { return }
        attachedRate = 0
        guard isPlaying else { return }
        Self.logger.notice("audio output configuration changed during an utterance; recovering")
        recover()
    }

    /// Restarts the engine on the current output and re-schedules the buffers not yet played back, so the utterance
    /// goes on from the start of the interrupted sentence. When the engine cannot start, the utterance is given up.
    private func recover() {
        guard isPlaying else { return }
        let unplayed = pending
        epoch += 1
        player.stop()
        pending.removeAll()
        attachedRate = 0
        do {
            try prepare(sampleRate: utteranceRate)
            player.volume = volume
            player.play()
            for buffer in unplayed { schedule(buffer, generation: generation) }
            recoveries += 1
            if finishedScheduling {
                if unplayed.isEmpty { resumeWaiters() } else { armWatchdog(generation: generation) }
            }
        } catch {
            Self.logger.error("audio engine could not restart after the output changed: \(error.localizedDescription, privacy: .public)")
            fail()
        }
    }

    /// Ends the utterance in progress as interrupted: `play()` returns `false`.
    private func fail() {
        failures += 1
        generation += 1
        player.stop()
        pending.removeAll()
        isPlaying = false
        resumeWaiters()
        onStateChange?(false)
    }

    private func resumeWaiters() {
        watchdog?.cancel()
        watchdog = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// Stops immediately. Any `play` in progress returns `false`.
    public func stop() {
        generation += 1
        player.stop()
        pending.removeAll()
        isPlaying = false
        resumeWaiters()
        onStateChange?(false)
    }

    public func shutdown() {
        stop()
        engine.stop()
        attachedRate = 0
    }

    // MARK: Test hooks

    /// Stops the engine as the system would, without a notification, to exercise the recovery paths.
    func stopEngineForTesting() {
        engine.stop()
    }

    /// What the system does when the output hardware changes: the engine stops and the notification is posted.
    func changeOutputConfigurationForTesting() {
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// Pauses the player node: the engine keeps running and no completion ever arrives, as a stalled output would.
    func pausePlayerForTesting() {
        player.pause()
    }

    var isEngineRunningForTesting: Bool { engine.isRunning }
}

/// A block observer that unregisters itself when released.
final class NotificationObserver: Sendable {
    private let token: NSObjectProtocolBox

    init(name: Notification.Name, object: AnyObject?, handler: @escaping @Sendable () -> Void) {
        token = NSObjectProtocolBox(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { _ in handler() })
    }

    deinit {
        NotificationCenter.default.removeObserver(token.value)
    }

    private final class NSObjectProtocolBox: @unchecked Sendable {
        let value: any NSObjectProtocol
        init(_ value: any NSObjectProtocol) { self.value = value }
    }
}
