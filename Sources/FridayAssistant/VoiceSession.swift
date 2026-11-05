import Foundation
import FridayCore
import FridaySpeech
import WakeWordKit
import os

/// Captures one utterance from the shared microphone ring buffer: feeds the recogniser and the voice-activity
/// detector until the person stops talking (or nothing is said), and returns the final transcript.
public struct UtteranceCapture: Sendable {
    public var text: String
    public var language: Language?
    public var confidence: Double?
    public var heardSpeech: Bool
    public var speechEndedAt: ContinuousClock.Instant?
    public var transcriptReadyAt: ContinuousClock.Instant
}

public enum ListenOutcome: Sendable {
    case utterance(UtteranceCapture)
    case silence
    case cancelled
    case failed(String)
}

public actor VoiceListener {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "listener")

    public let recorder: MicrophoneRecorder
    private let recognizers: [String: any SpeechRecognizer]
    private let makeDetector: @Sendable () -> any VoiceActivityDetector
    private let settings: @Sendable () -> VoiceSettings
    private var current: Task<ListenOutcome, Never>?

    public init(recorder: MicrophoneRecorder, recognizers: [any SpeechRecognizer], detector: @escaping @Sendable () -> any VoiceActivityDetector, settings: @escaping @Sendable () -> VoiceSettings) {
        self.recorder = recorder
        self.recognizers = Dictionary(uniqueKeysWithValues: recognizers.map { ($0.id, $0) })
        self.makeDetector = detector
        self.settings = settings
    }

    public func availableRecognizers() async -> [(id: String, name: String, availability: FridaySpeech.EngineAvailability)] {
        var result: [(String, String, FridaySpeech.EngineAvailability)] = []
        for recognizer in recognizers.values.sorted(by: { $0.id < $1.id }) { result.append((recognizer.id, recognizer.displayName, await recognizer.availability())) }
        return result
    }

    func activeRecognizer() async -> (any SpeechRecognizer)? {
        let preferred = settings().recognizerID
        if let recognizer = recognizers[preferred], await recognizer.availability().isAvailable { return recognizer }
        if let apple = recognizers["apple"], await apple.availability().isAvailable { return apple }
        return nil
    }

    public func warmUp() async {
        for recognizer in recognizers.values { await recognizer.warmUp() }
    }

    /// Listens from `startPosition` (a recorder sample position, e.g. the end of the wake word) until the end of the
    /// utterance. `onPartial` receives live text for the HUD. `waitForSpeech` is how long to wait for the first words.
    public func listen(
        from startPosition: Int, waitForSpeech: Double? = nil, onPartial: (@Sendable (String) -> Void)? = nil
    ) async -> ListenOutcome {
        current?.cancel()
        let settings = settings()
        let recorder = recorder
        let detector = makeDetector()
        guard let recognizer = await activeRecognizer() else { return .failed("No speech recogniser is available.") }
        let hint: SpeechLanguageHint
        switch settings.spokenLanguage {
        case .automatic: hint = .bilingual(primary: Language(hint: Locale.current.language.languageCode?.identifier) ?? .en)
        case .english: hint = .fixed(.en)
        case .spanish: hint = .fixed(.es)
        }
        let session: any SpeechRecognitionSession
        do {
            session = try await recognizer.makeSession(language: hint, vocabulary: settings.customVocabulary + [settings.wakeWord])
        } catch {
            return .failed(error.localizedDescription)
        }
        let task = Task<ListenOutcome, Never> {
            let clock = ContinuousClock()
            let started = clock.now
            var position = startPosition
            var heardSpeech = false
            var speechEndedAt: ContinuousClock.Instant?
            var lastPartial = ""
            let noSpeechLimit = waitForSpeech ?? settings.noSpeechTimeoutSeconds
            let reader = Task {
                for await update in session.updates {
                    if !update.text.isEmpty, update.text != lastPartial {
                        lastPartial = update.text
                        onPartial?(update.text)
                    }
                }
            }
            defer { reader.cancel() }
            while !Task.isCancelled {
                let (samples, next) = recorder.drain(since: position)
                position = next
                if !samples.isEmpty {
                    detector.accept(samples)
                    session.feed(AudioChunk(samples: samples, sampleRate: MicrophoneRecorder.sampleRate))
                }
                if detector.isSpeechActive { heardSpeech = true }
                let elapsed = started.duration(to: clock.now)
                if !detector.popSegments().isEmpty, heardSpeech, !detector.isSpeechActive {
                    speechEndedAt = clock.now
                    break
                }
                if !heardSpeech, elapsed > .seconds(noSpeechLimit) {
                    session.cancel()
                    return .silence
                }
                if elapsed > .seconds(settings.maxUtteranceSeconds) { detector.flush(); speechEndedAt = clock.now; break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            if Task.isCancelled { session.cancel(); return .cancelled }
            let final = await session.finish()
            let text = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return heardSpeech ? .failed("I couldn't make out any words.") : .silence }
            return .utterance(UtteranceCapture(text: text, language: final.language, confidence: final.confidence, heardSpeech: heardSpeech, speechEndedAt: speechEndedAt, transcriptReadyAt: clock.now))
        }
        current = task
        let outcome = await task.value
        if current == task { current = nil }
        return outcome
    }

    public func cancel() {
        current?.cancel()
        current = nil
    }

    /// Returns true as soon as sustained speech energy appears (used for barge-in while Friday is speaking).
    ///
    /// With `calibration` > 0 the first seconds set the reference level: whatever the microphone picks up then (the
    /// speakers playing Friday's reply, the room) is the floor, and only audio `margin` dB above it counts as speech.
    /// Without calibration the reference is the quietest recent frame, as for ordinary endpointing.
    public func waitForSpeech(timeout: Double, minimumDuration: Double = 0.35, calibration: Double = 0, margin: Float = 8) async -> Bool {
        var position = recorder.position
        let clock = ContinuousClock()
        let started = clock.now
        var activeSince: ContinuousClock.Instant?
        var calibrationLevels: [Float] = []
        var reference: Float = calibration > 0 ? .infinity : -60
        var carry: [Float] = []
        let frame = MicrophoneRecorder.sampleRate / 50  // 20 ms
        while started.duration(to: clock.now) < .seconds(timeout), !Task.isCancelled {
            let (samples, next) = recorder.drain(since: position)
            position = next
            carry.append(contentsOf: samples)
            var levels: [Float] = []
            while carry.count >= frame {
                var sum: Float = 0
                for sample in carry.prefix(frame) { sum += sample * sample }
                carry.removeFirst(frame)
                let rms = (sum / Float(frame)).squareRoot()
                levels.append(rms > 0 ? 20 * log10(rms) : -120)
            }
            let elapsed = started.duration(to: clock.now)
            if calibration > 0, elapsed < .seconds(calibration) {
                calibrationLevels.append(contentsOf: levels)
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if reference == .infinity {
                // The playback level: the loud part of the calibration window, never below a quiet room.
                let sorted = calibrationLevels.sorted()
                reference = sorted.isEmpty ? -50 : max(-50, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))])
            } else if calibration == 0 {
                for level in levels where level < reference { reference = level }
            }
            let active = levels.contains { $0 > reference + margin }
            if active {
                if activeSince == nil { activeSince = clock.now }
                if let since = activeSince, since.duration(to: clock.now) >= .seconds(minimumDuration) { return true }
            } else if !levels.isEmpty {
                activeSince = nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
