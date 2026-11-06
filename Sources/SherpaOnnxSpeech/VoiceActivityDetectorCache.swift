import Foundation
import FridaySpeech
import os

/// One voice-activity detector for the whole listening pipeline instead of a new one per utterance. Loading the
/// Silero model is a new ONNX session each time (tens of milliseconds and memory the listener paid for every
/// `listen()` and every barge-in wait); here the detector is built once, `reset()` before each reuse, and rebuilt
/// only when the endpointing changes. When the Silero files are not installed the energy detector stands in.
public final class VoiceActivityDetectorCache: @unchecked Sendable {
    private struct Entry {
        let minimumSilence: Float
        let detector: any VoiceActivityDetector
    }

    private let resources: SherpaOnnxSpeechResources
    private let entry = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    public init(resources: SherpaOnnxSpeechResources) {
        self.resources = resources
    }

    /// The detector for `minimumSilence` seconds of endpointing silence, reset and ready for a new utterance.
    public func detector(minimumSilence: Float) -> any VoiceActivityDetector {
        entry.withLock { entry in
            if let cached = entry, cached.minimumSilence == minimumSilence {
                cached.detector.reset()
                return cached.detector
            }
            let detector = Self.make(resources: resources, minimumSilence: minimumSilence)
            entry = Entry(minimumSilence: minimumSilence, detector: detector)
            return detector
        }
    }

    /// The engine the cached detector runs on (`silero` or `energy`), once one was made.
    public var detectorID: String? { entry.withLock { $0?.detector.id } }

    static func make(resources: SherpaOnnxSpeechResources, minimumSilence: Float) -> any VoiceActivityDetector {
        let silero = SileroVoiceActivityDetector(configuration: .init(resources: resources, minSilenceDuration: minimumSilence))
        if silero.availability().isAvailable, (try? silero.prepare()) != nil { return silero }
        return EnergyVoiceActivityDetector(minimumSilence: Double(minimumSilence))
    }
}
