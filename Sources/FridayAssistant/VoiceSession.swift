import Foundation
import FridayCore
import FridayIntelligence
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
    /// Nothing was said before the wait ran out.
    case silence
    /// Speech was heard but the recogniser made no words of it (a cough, a fragment, noise shaped like speech).
    case unintelligible
    case cancelled
    /// The recogniser itself is not usable (no engine, the session could not be created).
    case failed(LocalizedText)
}

/// What the wake-word verification stage concluded about the audio around the detection.
public struct WakeWordVerification: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case accepted(transcript: String)
        case rejected(transcript: String)
        /// The check could not run (no recogniser, no audio); the activation proceeds as if unverified.
        case skipped(String)
    }
    public var outcome: Outcome
    public var durationMs: Int
    public var isRejected: Bool { if case .rejected = outcome { return true } else { return false } }
}

public actor VoiceListener {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "listener")

    /// How many words a recognition session is given at most (custom vocabulary, wake word, app/contact names).
    public static let maximumVocabulary = 300
    /// The provider's words are fetched again in the background when older than this.
    static let vocabularyRefreshInterval: Duration = .seconds(60)
    /// Seconds of audio before the detector's end-of-keyword time that are transcribed to verify a wake word.
    public static let wakeWordVerificationWindow = 1.2

    public let recorder: MicrophoneRecorder
    private let recognizers: [String: any SpeechRecognizer]
    private let makeDetector: @Sendable () -> any VoiceActivityDetector
    private let settings: @Sendable () -> VoiceSettings
    private var current: Task<ListenOutcome, Never>?
    private var generation = 0
    /// One detector, reset per utterance: building a Silero detector loads an ONNX model.
    private var cachedDetector: (detector: any VoiceActivityDetector, silence: Double)?
    private var vocabularyProvider: (@Sendable () async -> [String])?
    private var providedVocabulary: [String] = []
    private var vocabularyFetchedAt: ContinuousClock.Instant?
    private var vocabularyRefresh: Task<Void, Never>?

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

    // MARK: Vocabulary

    /// Words the recogniser should expect besides the settings' custom vocabulary and the wake word: installed app
    /// names, playlists, contacts… The provider is called in the background (now, and again when its words are
    /// older than a minute at the next listen), never on the path between the wake word and the first transcript.
    public func setVocabularyProvider(_ provider: (@Sendable () async -> [String])?) {
        vocabularyProvider = provider
        providedVocabulary = []
        vocabularyFetchedAt = nil
        vocabularyRefresh?.cancel()
        vocabularyRefresh = nil
        if provider != nil { scheduleVocabularyRefresh() }
    }

    /// Fetches the provider's words now and waits for them (the app calls it after installing an app or editing
    /// contacts; tests use it to make the next listen deterministic).
    public func refreshVocabulary() async {
        guard let provider = vocabularyProvider else { return }
        let words = await provider()
        providedVocabulary = Self.mergeVocabulary([words])
        vocabularyFetchedAt = ContinuousClock.now
    }

    private func scheduleVocabularyRefresh() {
        guard vocabularyRefresh == nil else { return }
        vocabularyRefresh = Task { [weak self] in
            await self?.refreshVocabulary()
            await self?.finishVocabularyRefresh()
        }
    }

    private func finishVocabularyRefresh() { vocabularyRefresh = nil }

    /// The words for the next recognition session, oldest source first so the cap trims the provider's tail.
    func vocabulary(for settings: VoiceSettings) -> [String] {
        if vocabularyProvider != nil, vocabularyFetchedAt.map({ $0.duration(to: .now) > Self.vocabularyRefreshInterval }) ?? true {
            scheduleVocabularyRefresh()
        }
        return Self.mergeVocabulary([[settings.wakeWord], settings.customVocabulary, providedVocabulary])
    }

    /// Trims, drops empties and very long entries, removes duplicates (case and accent insensitively, keeping the
    /// first spelling) and caps the list.
    static func mergeVocabulary(_ lists: [[String]], limit: Int = maximumVocabulary) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for list in lists {
            for raw in list {
                let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty, word.count <= 60 else { continue }
                let key = KeywordRouter.fold(word)
                guard seen.insert(key).inserted else { continue }
                result.append(word)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    // MARK: Listening

    private func detector(for settings: VoiceSettings) -> any VoiceActivityDetector {
        if let cached = cachedDetector, cached.silence == settings.endpointSilenceSeconds {
            cached.detector.reset()
            return cached.detector
        }
        let fresh = makeDetector()
        cachedDetector = (fresh, settings.endpointSilenceSeconds)
        return fresh
    }

    func languageHint(for settings: VoiceSettings) -> SpeechLanguageHint {
        switch settings.spokenLanguage {
        case .automatic: return .bilingual(primary: settings.promptLanguage)
        case .english: return .fixed(.en)
        case .spanish: return .fixed(.es)
        }
    }

    /// Listens from `startPosition` (a recorder sample position, e.g. the end of the wake word) until the end of the
    /// utterance. `onPartial` receives live text for the HUD. `waitForSpeech` is how long to wait for the first words.
    /// Cancelling the calling task, `cancel()`, or a newer `listen` ends it with `.cancelled`.
    public func listen(
        from startPosition: Int, waitForSpeech: Double? = nil, onPartial: (@Sendable (String) -> Void)? = nil
    ) async -> ListenOutcome {
        generation += 1
        let myGeneration = generation
        // The detector is shared: wait for the previous capture to let go of it (a cancelled capture exits within
        // one 40 ms tick) before resetting it for this one.
        if let previous = current {
            previous.cancel()
            _ = await previous.value
            if current == previous { current = nil }
        }
        guard myGeneration == generation else { return .cancelled }
        let settings = settings()
        let recorder = recorder
        guard let recognizer = await activeRecognizer() else {
            return .failed(LocalizedText(en: "No speech recogniser is available.", es: "No hay ningún reconocedor de voz disponible."))
        }
        guard myGeneration == generation else { return .cancelled }
        let session: any SpeechRecognitionSession
        do {
            session = try await recognizer.makeSession(language: languageHint(for: settings), vocabulary: vocabulary(for: settings))
        } catch {
            Self.logger.error("recognition session failed: \(error.localizedDescription, privacy: .public)")
            return .failed(LocalizedText(en: "Speech recognition could not start: \(error.localizedDescription)", es: "No se pudo iniciar el reconocimiento de voz: \(error.localizedDescription)"))
        }
        guard myGeneration == generation else { session.cancel(); return .cancelled }
        let detector = detector(for: settings)
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
                // "Heard speech" means the detector closed a segment, not that it flickered: both detectors raise
                // `isSpeechActive` on the first loud frame and drop anything shorter than their minimum without ever
                // producing a segment (a cough, a key click, the chime through the speakers).
                let segments = detector.popSegments()
                if !segments.isEmpty { heardSpeech = true }
                let elapsed = started.duration(to: clock.now)
                if heardSpeech, !segments.isEmpty, !detector.isSpeechActive {
                    speechEndedAt = clock.now
                    break
                }
                // The wait for the first words keeps running while nothing is confirmed and nothing is in progress.
                if !heardSpeech, !detector.isSpeechActive, elapsed > .seconds(noSpeechLimit) {
                    session.cancel()
                    return .silence
                }
                if elapsed > .seconds(settings.maxUtteranceSeconds) {
                    detector.flush()
                    if !detector.popSegments().isEmpty { heardSpeech = true }
                    speechEndedAt = clock.now
                    break
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            if Task.isCancelled { session.cancel(); return .cancelled }
            let final = await session.finish()
            let text = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return heardSpeech ? .unintelligible : .silence }
            return .utterance(UtteranceCapture(text: text, language: final.language, confidence: final.confidence, heardSpeech: heardSpeech, speechEndedAt: speechEndedAt, transcriptReadyAt: clock.now))
        }
        current = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if current == task { current = nil }
        return outcome
    }

    public func cancel() {
        generation += 1
        current?.cancel()
        current = nil
    }

    // MARK: Barge-in

    /// Waits for sustained speech energy (used for barge-in while Friday is speaking) and returns the recorder
    /// position where that speech began, less a 0.2 s margin for the detector's latency, so the next capture can
    /// start there and the words that interrupted Friday are not lost. `nil` on timeout or cancellation.
    ///
    /// With `calibration` > 0 the first seconds set the reference level: whatever the microphone picks up then (the
    /// speakers playing Friday's reply, the room) is the floor, and only audio `margin` dB above it counts as speech.
    /// Without calibration the reference is the quietest recent frame, as for ordinary endpointing.
    public func waitForSpeech(timeout: Double, minimumDuration: Double = 0.35, calibration: Double = 0, margin: Float = 8) async -> Int? {
        var position = recorder.position
        let clock = ContinuousClock()
        let started = clock.now
        var activeSince: ContinuousClock.Instant?
        var activeSincePosition = 0
        var calibrationLevels: [Float] = []
        var reference: Float = calibration > 0 ? .infinity : -60
        var carry: [Float] = []
        var carryPosition = position  // recorder position of carry[0]
        let frame = MicrophoneRecorder.sampleRate / 50  // 20 ms
        while started.duration(to: clock.now) < .seconds(timeout), !Task.isCancelled {
            let (samples, next) = recorder.drain(since: position)
            position = next
            carry.append(contentsOf: samples)
            var levels: [(level: Float, start: Int)] = []
            while carry.count >= frame {
                var sum: Float = 0
                for sample in carry.prefix(frame) { sum += sample * sample }
                carry.removeFirst(frame)
                let rms = (sum / Float(frame)).squareRoot()
                levels.append((rms > 0 ? 20 * log10(rms) : -120, carryPosition))
                carryPosition += frame
            }
            let elapsed = started.duration(to: clock.now)
            if calibration > 0, elapsed < .seconds(calibration) {
                calibrationLevels.append(contentsOf: levels.map(\.level))
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if reference == .infinity {
                // The playback level: the loud part of the calibration window, never below a quiet room.
                let sorted = calibrationLevels.sorted()
                reference = sorted.isEmpty ? -50 : max(-50, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))])
            } else if calibration == 0 {
                for entry in levels where entry.level < reference { reference = entry.level }
            }
            if let first = levels.first(where: { $0.level > reference + margin }) {
                if activeSince == nil {
                    activeSince = clock.now
                    activeSincePosition = first.start
                }
                if let since = activeSince, since.duration(to: clock.now) >= .seconds(minimumDuration) {
                    return max(0, activeSincePosition - MicrophoneRecorder.sampleRate / 5)
                }
            } else if !levels.isEmpty {
                activeSince = nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    // MARK: Wake-word verification

    /// Transcribes the ring-buffer audio that ends at `endPosition` (the detector's end-of-keyword position) and
    /// says whether a spelling of `wakeWord` is in it. The window is `wakeWordVerificationWindow` plus `margin`
    /// seconds long, because the detector reports the keyword's end a few hundred milliseconds late.
    public func verifyWakeWord(endingAt endPosition: Int, wakeWord: String, margin: Double = 0.6) async -> WakeWordVerification {
        let clock = ContinuousClock()
        let started = clock.now
        func elapsed() -> Int { milliseconds(started.duration(to: clock.now)) }
        let start = max(0, endPosition - Int((Self.wakeWordVerificationWindow + margin) * Double(MicrophoneRecorder.sampleRate)))
        let samples = recorder.samples(from: start, to: endPosition)
        guard samples.count >= MicrophoneRecorder.sampleRate / 4 else {
            return WakeWordVerification(outcome: .skipped("the ring buffer no longer holds the wake word"), durationMs: elapsed())
        }
        let settings = settings()
        guard let recognizer = await activeRecognizer() else {
            return WakeWordVerification(outcome: .skipped("no speech recogniser"), durationMs: elapsed())
        }
        let session: any SpeechRecognitionSession
        do {
            session = try await recognizer.makeSession(language: languageHint(for: settings), vocabulary: Self.mergeVocabulary([[wakeWord], WakeWordMatcher.spellings(for: wakeWord)]))
        } catch {
            return WakeWordVerification(outcome: .skipped("recognition session failed: \(error.localizedDescription)"), durationMs: elapsed())
        }
        let chunk = MicrophoneRecorder.sampleRate / 10
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            session.feed(AudioChunk(samples: Array(samples[offset..<end]), sampleRate: MicrophoneRecorder.sampleRate))
            offset = end
        }
        let final = await session.finish()
        let transcript = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No words at all is inconclusive (a quiet or clipped keyword), not evidence of other speech: an activation
        // is only dropped when the recogniser positively heard something else.
        guard !transcript.isEmpty else { return WakeWordVerification(outcome: .skipped("no words transcribed"), durationMs: elapsed()) }
        let accepted = WakeWordMatcher.matches(transcript, wakeWord: wakeWord)
        return WakeWordVerification(outcome: accepted ? .accepted(transcript: transcript) : .rejected(transcript: transcript), durationMs: elapsed())
    }
}

func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
}

/// Decides whether a transcript contains the wake word, tolerating the spellings recognisers produce for it
/// ("Yarvis", "Jarbis", "Llarvis", "jar vis").
public enum WakeWordMatcher {
    /// Known spellings of the wake word, one word each (the multi-word ones contribute their last word).
    static func spellings(for wakeWord: String) -> [String] {
        let targets = targets(for: wakeWord)
        var result = targets
        for spelling in UtteranceNormalizer.wakeWordSpellings {
            guard let last = spelling.split(separator: " ").last.map(String.init) else { continue }
            // Only the family of the configured word: "Friday" must not be verified by a "Jarvis" spelling.
            if targets.contains(where: { editDistance(last, $0) <= 2 }) { result.append(last) }
        }
        return result
    }

    /// The words of the wake word worth matching ("hey friday" → ["friday"]).
    static func targets(for wakeWord: String) -> [String] {
        let words = KeywordRouter.fold(wakeWord).split(whereSeparator: { !$0.isLetter }).map(String.init)
        let long = words.filter { $0.count >= 4 }
        return long.isEmpty ? words.filter { !$0.isEmpty } : long
    }

    public static func matches(_ transcript: String, wakeWord: String) -> Bool {
        let heard = KeywordRouter.fold(transcript).split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !heard.isEmpty else { return false }
        let targets = targets(for: wakeWord)
        let known = Set(spellings(for: wakeWord).map { KeywordRouter.fold($0) })
        for (index, word) in heard.enumerated() {
            if known.contains(word) { return true }
            // "jar vis", "yar bis": the recogniser split the word.
            if index + 1 < heard.count, known.contains(word + heard[index + 1]) { return true }
            for target in targets where target.count >= 4 {
                let suffix = String(target.suffix(4))
                if word.count >= target.count - 1, word.hasSuffix(suffix) { return true }
                let tolerance = target.count >= 6 ? 2 : 1
                if abs(word.count - target.count) <= tolerance, editDistance(word, target) <= tolerance { return true }
            }
        }
        return false
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var row = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            row[0] = i
            for j in 1...y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &row)
        }
        return previous[y.count]
    }
}
