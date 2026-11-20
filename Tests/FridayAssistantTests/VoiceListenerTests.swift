import Foundation
import Testing
import FridayCore
import FridaySpeech
@testable import FridayAssistant

@Suite struct VoiceListenerTests {
    private func makeListener(script: [String], settings: VoiceSettings = SettingsBox.fast()) -> (VoiceListener, ScriptedRecognizer, MicrophoneRecorder) {
        let recorder = MicrophoneRecorder(seconds: 30)
        let recognizer = ScriptedRecognizer(script)
        let box = SettingsBox(settings)
        let listener = VoiceListener(recorder: recorder, recognizers: [recognizer], detector: { testDetector() }, settings: { box.current })
        return (listener, recognizer, recorder)
    }

    @Test func anUtteranceIsTranscribed() async {
        let (listener, _, recorder) = makeListener(script: ["open notes"])
        feed(recorder, utteranceAudio())
        let outcome = await listener.listen(from: 0, waitForSpeech: 1)
        guard case .utterance(let capture) = outcome else { Issue.record("expected an utterance, got \(outcome)"); return }
        #expect(capture.text == "open notes")
        #expect(capture.heardSpeech)
        #expect(capture.speechEndedAt != nil)
    }

    /// #3: the Spanish lane can win with an English sentence; the reply must follow the words, not the lane.
    @Test(arguments: [
        ("What time is it?", Language.es, Language.en),
        ("¿Qué hora es?", Language.en, Language.es),
        ("pon mi playlist de estudiar y abre Notes", Language.en, Language.es),
        ("Notes", Language.es, Language.es),  // one ambiguous word: the lane decides
    ])
    func theCapturesLanguageFollowsTheWords(text: String, lane: Language, expected: Language) async {
        let recorder = MicrophoneRecorder(seconds: 30)
        let recognizer = ScriptedRecognizer([text], language: lane)
        let box = SettingsBox(SettingsBox.fast())
        let listener = VoiceListener(recorder: recorder, recognizers: [recognizer], detector: { testDetector() }, settings: { box.current })
        feed(recorder, utteranceAudio())
        let outcome = await listener.listen(from: 0, waitForSpeech: 1)
        guard case .utterance(let capture) = outcome else { Issue.record("expected an utterance, got \(outcome)"); return }
        #expect(capture.language == expected)
    }

    @Test func nothingSaidIsSilenceAfterTheWait() async {
        let (listener, _, _) = makeListener(script: ["never used"])
        let started = ContinuousClock.now
        let outcome = await listener.listen(from: 0, waitForSpeech: 0.4)
        guard case .silence = outcome else { Issue.record("expected silence, got \(outcome)"); return }
        #expect(milliseconds(since: started) < 2_000)
    }

    /// Finding 21: a burst too short to become a segment must not arm the 25 s "speech in progress" wait.
    @Test func aShortNoiseBurstStillTimesOutAsSilence() async {
        let (listener, recognizer, recorder) = makeListener(script: ["never used"])
        feed(recorder, tone(seconds: 0.1, amplitude: 0.3) + tone(seconds: 1.0, amplitude: 0.001))
        let started = ContinuousClock.now
        let outcome = await listener.listen(from: 0, waitForSpeech: 0.5)
        guard case .silence = outcome else { Issue.record("expected silence, got \(outcome)"); return }
        #expect(milliseconds(since: started) < 3_000)
        #expect(recognizer.createdSessions.count == 1)
    }

    /// Finding 29: speech without words is its own outcome, not a recogniser failure.
    @Test func speechWithoutWordsIsUnintelligible() async {
        let (listener, _, recorder) = makeListener(script: [""])
        feed(recorder, utteranceAudio())
        let outcome = await listener.listen(from: 0, waitForSpeech: 1)
        guard case .unintelligible = outcome else { Issue.record("expected unintelligible, got \(outcome)"); return }
    }

    @Test func noRecogniserIsABilingualFailure() async {
        let recorder = MicrophoneRecorder(seconds: 5)
        let listener = VoiceListener(recorder: recorder, recognizers: [], detector: { testDetector() }, settings: { SettingsBox.fast() })
        let outcome = await listener.listen(from: 0, waitForSpeech: 0.2)
        guard case .failed(let reason) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(!reason.en.isEmpty && !reason.es.isEmpty && reason.en != reason.es)
    }

    @Test func cancellingTheCallerEndsTheListen() async {
        let (listener, _, _) = makeListener(script: ["never used"])
        let task = Task { await listener.listen(from: 0, waitForSpeech: 30) }
        try? await Task.sleep(for: .milliseconds(150))
        let started = ContinuousClock.now
        task.cancel()
        let outcome = await task.value
        guard case .cancelled = outcome else { Issue.record("expected cancelled, got \(outcome)"); return }
        #expect(milliseconds(since: started) < 1_000)
    }

    // MARK: Vocabulary (feature a)

    @Test func mergeDeduplicatesAndCaps() {
        let merged = VoiceListener.mergeVocabulary([["Jarvis"], ["Notes", " notes ", "", "Música"], ["musica", "Spotify", "Jarvis"]], limit: 4)
        #expect(merged == ["Jarvis", "Notes", "Música", "Spotify"])
        let many = VoiceListener.mergeVocabulary([(0..<500).map { "word\($0)" }])
        #expect(many.count == VoiceListener.maximumVocabulary)
    }

    @Test func providerWordsReachTheRecognitionSession() async {
        var settings = SettingsBox.fast()
        settings.customVocabulary = ["Dani", "Notes"]
        let (listener, recognizer, recorder) = makeListener(script: ["hi"], settings: settings)
        await listener.setVocabularyProvider { ["Spotify", "notes", "Calculator"] }
        await listener.refreshVocabulary()
        feed(recorder, utteranceAudio())
        _ = await listener.listen(from: 0, waitForSpeech: 1)
        let vocabulary = recognizer.createdSessions.first?.vocabulary ?? []
        #expect(vocabulary == ["Jarvis", "Dani", "Notes", "Spotify", "Calculator"])
    }

    @Test func removingTheProviderDropsItsWords() async {
        let (listener, recognizer, recorder) = makeListener(script: ["hi"])
        await listener.setVocabularyProvider { ["Spotify"] }
        await listener.refreshVocabulary()
        await listener.setVocabularyProvider(nil)
        feed(recorder, utteranceAudio())
        _ = await listener.listen(from: 0, waitForSpeech: 1)
        #expect(recognizer.createdSessions.first?.vocabulary == ["Jarvis"])
    }

    /// A fetch still in flight when the provider is removed must not write the old provider's words back.
    @Test func aSlowFetchFinishingAfterTheProviderIsRemovedIsDiscarded() async {
        let (listener, recognizer, recorder) = makeListener(script: ["hi"])
        let release = AsyncStream<Void>.makeStream()
        await listener.setVocabularyProvider {
            for await _ in release.stream { break }
            return ["Spotify"]
        }
        let fetching = Task { await listener.refreshVocabulary() }
        try? await Task.sleep(for: .milliseconds(50))   // the fetch is now waiting inside the provider
        await listener.setVocabularyProvider(nil)
        release.continuation.yield(())
        release.continuation.finish()
        await fetching.value
        feed(recorder, utteranceAudio())
        _ = await listener.listen(from: 0, waitForSpeech: 1)
        #expect(recognizer.createdSessions.first?.vocabulary == ["Jarvis"])
    }

    // MARK: Barge-in (finding 7)

    /// `waitForSpeech` reports where the speech began (less 0.2 s), so the next capture can start there.
    @Test func waitForSpeechReturnsWhereTheSpeechBegan() async {
        let (listener, _, recorder) = makeListener(script: [])
        let toneStart = Mutex<Int?>(nil)
        let feeder = Task {
            // 0.9 s of quiet room (covers the 0.5 s calibration), then 1.2 s of speech, then quiet again.
            for _ in 0..<18 { feed(recorder, tone(seconds: 0.05, amplitude: 0.001)); try? await Task.sleep(for: .milliseconds(50)) }
            toneStart.set(recorder.position)
            for _ in 0..<24 { feed(recorder, tone(seconds: 0.05, amplitude: 0.3)); try? await Task.sleep(for: .milliseconds(50)) }
            for _ in 0..<10 { feed(recorder, tone(seconds: 0.05, amplitude: 0.001)); try? await Task.sleep(for: .milliseconds(50)) }
        }
        let position = await listener.waitForSpeech(timeout: 6, minimumDuration: 0.3, calibration: 0.5)
        feeder.cancel()
        guard let position, let start = toneStart.get() else { Issue.record("speech was not detected"); return }
        let expected = start - MicrophoneRecorder.sampleRate / 5
        #expect(abs(position - expected) <= MicrophoneRecorder.sampleRate / 8, "returned \(position), expected about \(expected)")
    }

    @Test func waitForSpeechTimesOutQuietly() async {
        let (listener, _, _) = makeListener(script: [])
        let position = await listener.waitForSpeech(timeout: 0.3, minimumDuration: 0.1)
        #expect(position == nil)
    }

    // MARK: Wake-word verification (feature b)

    @Test func verificationAcceptsAWakeWordSpelling() async {
        let (listener, recognizer, recorder) = makeListener(script: ["Yarvis"])
        feed(recorder, tone(seconds: 2.5, amplitude: 0.3))
        let verification = await listener.verifyWakeWord(endingAt: recorder.position, wakeWord: "Jarvis")
        #expect(verification.outcome == .accepted(transcript: "Yarvis"))
        #expect(!verification.isRejected)
        let session = recognizer.createdSessions.first
        #expect(session?.vocabulary.first == "Jarvis")
        // 1.2 s window + 0.6 s margin of audio was transcribed.
        #expect(abs((session?.samplesFed ?? 0) - Int(1.8 * 16_000)) < 400)
    }

    @Test func verificationRejectsOtherSpeech() async {
        let (listener, _, recorder) = makeListener(script: ["ya había terminado"])
        feed(recorder, tone(seconds: 2.5, amplitude: 0.3))
        let verification = await listener.verifyWakeWord(endingAt: recorder.position, wakeWord: "Jarvis")
        #expect(verification.isRejected)
    }

    @Test func verificationWithoutWordsIsInconclusiveNotRejected() async {
        let (listener, _, recorder) = makeListener(script: [""])
        feed(recorder, tone(seconds: 2.5, amplitude: 0.3))
        let verification = await listener.verifyWakeWord(endingAt: recorder.position, wakeWord: "Jarvis")
        #expect(verification.outcome == .skipped("no words transcribed"))
        #expect(!verification.isRejected)
    }

    @Test func verificationIsSkippedWithoutAudio() async {
        let (listener, _, _) = makeListener(script: ["Jarvis"])
        let verification = await listener.verifyWakeWord(endingAt: 0, wakeWord: "Jarvis")
        guard case .skipped = verification.outcome else { Issue.record("expected skipped, got \(verification.outcome)"); return }
    }
}

@Suite struct WakeWordMatcherTests {
    @Test func knownAndFuzzySpellingsMatch() {
        for heard in ["Jarvis", "hey jarvis open notes", "Yarvis", "jarbis", "Llarvis, abre Notas", "Dyarvis", "jar vis", "Harvis", "Charvis"] {
            #expect(WakeWordMatcher.matches(heard, wakeWord: "Jarvis"), "\(heard) should match")
        }
        #expect(WakeWordMatcher.matches("Hey Friday", wakeWord: "Friday"))
        #expect(WakeWordMatcher.matches("hey, Friday", wakeWord: "Hey Friday"))
    }

    @Test func otherWordsDoNotMatch() {
        for heard in ["", "ya había terminado", "travis", "elvis is here", "open notes", "friday"] {
            #expect(!WakeWordMatcher.matches(heard, wakeWord: "Jarvis"), "\(heard) should not match")
        }
        #expect(!WakeWordMatcher.matches("jarvis", wakeWord: "Friday"))
    }
}

/// A lock-protected box for values set from a background task in a test.
final class Mutex<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
