import Foundation
import AVFoundation
import os

/// Plays synthesised speech chunks as they arrive, with immediate cancellation (barge-in, "stop").
public actor SpeechPlayer {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "tts.player")

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attachedRate: Double = 0
    private var generation = 0
    private var scheduled = 0
    private var completed = 0
    private var finishedScheduling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var isPlaying = false
    public var volume: Float = 1 {
        didSet { player.volume = volume }
    }
    /// Called when playback of an utterance ends (completed or cancelled).
    public var onStateChange: (@Sendable (Bool) -> Void)?

    public init() {
        engine.attach(player)
    }

    private func prepare(sampleRate: Double) throws {
        if engine.isRunning, attachedRate == sampleRate { return }
        if engine.isRunning { engine.stop() }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        attachedRate = sampleRate
        try engine.start()
    }

    /// Plays every chunk of `chunks`; returns when the audio finished or `stop()` was called.
    /// Returns `true` if the utterance played to the end.
    @discardableResult
    public func play(_ chunks: AsyncThrowingStream<AudioChunk, any Error>) async throws -> Bool {
        generation += 1
        let myGeneration = generation
        scheduled = 0
        completed = 0
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
                    try prepare(sampleRate: Double(chunk.sampleRate))
                    player.volume = volume
                    player.play()
                    started = true
                }
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sampleRate), channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count))!
                buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
                chunk.samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.samples.count)
                }
                scheduled += 1
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { await self?.bufferCompleted(generation: myGeneration) }
                }
            }
        } catch {
            if generation == myGeneration { player.stop() }
            throw error
        }
        guard started, generation == myGeneration else { return false }
        finishedScheduling = true
        if completed >= scheduled { return true }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
        return generation == myGeneration
    }

    private func bufferCompleted(generation: Int) {
        guard generation == self.generation else { return }
        completed += 1
        if finishedScheduling, completed >= scheduled {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    /// Stops immediately. Any `play` in progress returns `false`.
    public func stop() {
        generation += 1
        player.stop()
        isPlaying = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
        onStateChange?(false)
    }

    public func shutdown() {
        stop()
        engine.stop()
    }
}
