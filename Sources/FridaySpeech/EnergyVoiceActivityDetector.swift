import Foundation
import WakeWordKit

/// Noise-floor-relative energy endpointing (the same logic the wake-word project uses to cut utterances): robust,
/// zero-dependency, 20 ms resolution. The Silero detector in `SherpaOnnxSpeech` is preferred when its model is
/// installed; this one is always available.
public final class EnergyVoiceActivityDetector: VoiceActivityDetector, @unchecked Sendable {
    public let id = "energy"
    public var minimumSilence: Double
    public var minimumSpeech: Double
    public var maximumSpeech: Double
    /// Margin above the room level a frame needs to count as speech (dB).
    public var margin: Float

    private let lock = NSLock()
    private var buffer: [Float] = []
    private var levels: [Float] = []
    private var pending: [Float] = []
    private var speaking = false
    private var speechStartFrame = 0
    private var firstSpeechFrame = 0
    private var lastSpeechFrame = 0
    private var totalFrames = 0
    private var segments: [SpeechSegment] = []
    private var floor: Float = -60
    private var floorFrames = 0

    public init(minimumSilence: Double = 0.7, minimumSpeech: Double = 0.25, maximumSpeech: Double = 20, margin: Float = 10) {
        self.minimumSilence = minimumSilence
        self.minimumSpeech = minimumSpeech
        self.maximumSpeech = maximumSpeech
        self.margin = margin
    }

    static let frame = MicrophoneRecorder.sampleRate / UtteranceSplitter.framesPerSecond  // 320 samples = 20 ms

    public var isSpeechActive: Bool { lock.withLock { speaking } }

    public func accept(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: samples)
        while buffer.count >= Self.frame {
            let frame = Array(buffer.prefix(Self.frame))
            buffer.removeFirst(Self.frame)
            process(frame)
        }
    }

    private func process(_ frame: [Float]) {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        let level = rms.isFinite ? 20 * log10(max(rms, 1e-6)) : -120
        levels.append(level)
        pending.append(contentsOf: frame)
        totalFrames += 1
        // Adaptive floor: track the quiet tenth of recent frames (quick to drop, slow to rise).
        if !speaking {
            floorFrames += 1
            if level < floor { floor = level } else { floor += min(0.2, (level - floor) * 0.02) }
        }
        let threshold = max(floor + margin, UtteranceSplitter.minimumThresholdDecibels)
        let silenceFrames = Int(minimumSilence * Double(UtteranceSplitter.framesPerSecond))
        if level > threshold {
            if !speaking {
                speaking = true
                firstSpeechFrame = totalFrames - 1
                speechStartFrame = max(0, totalFrames - 1 - Int(UtteranceSplitter.marginBefore * Double(UtteranceSplitter.framesPerSecond)))
            }
            lastSpeechFrame = totalFrames - 1
        }
        if speaking {
            let sinceSpeech = totalFrames - 1 - lastSpeechFrame
            let length = Double(totalFrames - speechStartFrame) / Double(UtteranceSplitter.framesPerSecond)
            if sinceSpeech >= silenceFrames || length >= maximumSpeech { close() }
        }
        // Keep the pending audio bounded while not speaking (0.5 s of pre-roll).
        let keep = Int(0.5 * Double(MicrophoneRecorder.sampleRate))
        if !speaking, pending.count > keep {
            pending.removeFirst(pending.count - keep)
            levels.removeFirst(max(0, levels.count - keep / Self.frame))
        }
    }

    private func close() {
        let endFrame = min(totalFrames, lastSpeechFrame + 1 + Int(UtteranceSplitter.marginAfter * Double(UtteranceSplitter.framesPerSecond)))
        let durationFrames = lastSpeechFrame - firstSpeechFrame + 1
        speaking = false
        defer { pending.removeAll(keepingCapacity: true); levels.removeAll(keepingCapacity: true) }
        guard Double(durationFrames) / Double(UtteranceSplitter.framesPerSecond) >= minimumSpeech else { return }
        let framesHeld = pending.count / Self.frame
        let firstHeldFrame = totalFrames - framesHeld
        let startOffset = max(0, (speechStartFrame - firstHeldFrame) * Self.frame)
        let endOffset = min(pending.count, max(startOffset, (endFrame - firstHeldFrame) * Self.frame))
        guard endOffset > startOffset else { return }
        segments.append(SpeechSegment(startSample: speechStartFrame * Self.frame, samples: Array(pending[startOffset..<endOffset])))
    }

    public func popSegments() -> [SpeechSegment] {
        lock.withLock {
            let out = segments
            segments.removeAll()
            return out
        }
    }

    public func flush() {
        lock.withLock { if speaking { lastSpeechFrame = max(lastSpeechFrame, totalFrames - 1); close() } }
    }

    public func reset() {
        lock.withLock {
            buffer.removeAll()
            levels.removeAll()
            pending.removeAll()
            speaking = false
            totalFrames = 0
            segments.removeAll()
            floor = -60
            floorFrames = 0
        }
    }

    public var noiseFloorDecibels: Float { lock.withLock { floor } }
}
