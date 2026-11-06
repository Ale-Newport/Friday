import Foundation
import FridaySpeech
import Testing
@testable import SherpaOnnxSpeech

struct SileroVoiceActivityDetectorTests {
    static let installed = SpeechFixtures.sileroIsInstalled
    static let sampleRate = SileroVoiceActivityDetector.sampleRate

    // MARK: Without the model

    @Test func reportsSetupNeededWhenFilesAreMissing() {
        let nowhere = URL(fileURLWithPath: "/nonexistent/friday-\(UUID().uuidString)")
        let detector = SileroVoiceActivityDetector(resources: .developmentDefault(repositoryRoot: nowhere))
        guard case .needsSetup(let reason) = detector.availability() else {
            Issue.record("expected needsSetup, got \(detector.availability())")
            return
        }
        #expect(reason.en.contains("silero_vad.onnx"))
        #expect(reason.es.contains("silero_vad.onnx"))
        #expect(throws: SpeechError.self) { try detector.prepare() }
        // Audio fed to an unusable detector is dropped, not crashed on.
        detector.accept([Float](repeating: 0, count: 1_000))
        #expect(!detector.isSpeechActive)
        #expect(detector.popSegments().isEmpty)
        detector.flush()
        detector.reset()
    }

    @Test func identifiesItself() {
        let detector = SileroVoiceActivityDetector(resources: SpeechFixtures.resources)
        #expect(detector.id == "silero")
        #expect(SileroVoiceActivityDetector.sampleRate == 16_000)
        #expect(SileroVoiceActivityDetector.windowSize == 512)
        #expect(detector.configuration.libraryURL == SpeechFixtures.resources.libraryURL)
        #expect(detector.configuration.modelURL == SpeechFixtures.resources.sileroModelURL)
    }

    // MARK: Cache

    @Test func cacheHandsOutOneDetectorPerEndpointingAndResetsIt() {
        let cache = VoiceActivityDetectorCache(resources: SpeechFixtures.resources)
        #expect(cache.detectorID == nil)
        let first = cache.detector(minimumSilence: 0.8)
        let again = cache.detector(minimumSilence: 0.8)
        #expect(first === again, "the same endpointing reuses the loaded detector")
        #expect(cache.detectorID == first.id)
        #expect(first.id == (Self.installed ? "silero" : "energy"))
        let other = cache.detector(minimumSilence: 1.2)
        #expect(other !== first, "a new endpointing needs a new detector")
        #expect(cache.detector(minimumSilence: 1.2) === other)
        #expect(cache.detector(minimumSilence: 0.8) !== first, "only the latest configuration is kept")
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func cachedDetectorForgetsTheLastUtteranceWhenReused() throws {
        let cache = VoiceActivityDetectorCache(resources: SpeechFixtures.resources)
        let detector = cache.detector(minimumSilence: 0.5)
        let (audio, _, _) = try Self.paddedSpeech()
        detector.accept(Array(audio[0..<(audio.count / 2)]))   // half way through the words
        #expect(detector.isSpeechActive)
        let reused = cache.detector(minimumSilence: 0.5)
        #expect(reused === detector)
        #expect(!reused.isSpeechActive, "reuse starts from silence")
        #expect(reused.popSegments().isEmpty)
        reused.accept(audio)
        reused.flush()
        let segments = reused.popSegments()
        #expect(segments.count == 1)
        #expect((segments.first?.startSample ?? 0) < 2 * Self.sampleRate, "offsets count from the reuse")
    }

    // MARK: With the model

    /// "one two three" from the Mac's synthesiser with a second of silence before and after.
    private static func paddedSpeech() throws -> (samples: [Float], speechStart: Int, speechEnd: Int) {
        let speech = try SpeechFixtures.spoken("one two three")
        let padding = [Float](repeating: 0, count: sampleRate)
        return (padding + speech + padding, padding.count, padding.count + speech.count)
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func findsOneUtteranceInPaddedSpeech() throws {
        let detector = SileroVoiceActivityDetector(resources: SpeechFixtures.resources)
        #expect(detector.availability() == .available)
        try detector.prepare()
        let (audio, speechStart, speechEnd) = try Self.paddedSpeech()
        #expect(SpeechFixtures.rms(Array(audio[speechStart..<speechEnd])) > 0.01, "the synthesiser produced silence")

        // Fed in odd-sized chunks, as a microphone would (and never a multiple of the 512-sample window).
        var activeAt: [Int] = []
        var offset = 0
        var step = 160
        while offset < audio.count {
            let end = min(audio.count, offset + step)
            detector.accept(Array(audio[offset..<end]))
            if detector.isSpeechActive { activeAt.append(end) }
            offset = end
            step = step == 160 ? 333 : 160
        }
        #expect(!activeAt.isEmpty, "speech was never detected")
        if let first = activeAt.first, let last = activeAt.last {
            // Detection starts around the onset (the model needs a few windows) and ends around the end of speech (plus
            // the trailing silence the detector waits for before closing).
            #expect(first >= speechStart, "speech detected during the leading silence (at sample \(first))")
            #expect(first < speechStart + Self.sampleRate / 2, "speech detected late (at sample \(first), onset \(speechStart))")
            #expect(last <= speechEnd + Self.sampleRate, "still 'speaking' well into the trailing silence (at sample \(last))")
        }
        #expect(!detector.isSpeechActive, "silence at the end should have closed the utterance")

        detector.flush()
        let segments = detector.popSegments()
        #expect(segments.count == 1, "expected one segment, got \(segments.count): \(segments.map { ($0.startSample, $0.samples.count) })")
        if let segment = segments.first {
            let start = Double(segment.startSample) / Double(Self.sampleRate)
            let duration = Double(segment.samples.count) / Double(Self.sampleRate)
            let speechSeconds = Double(speechEnd - speechStart) / Double(Self.sampleRate)
            print("silero: segment starts at \(String(format: "%.3f", start)) s, lasts \(String(format: "%.3f", duration)) s (speech: 1.000 s + \(String(format: "%.3f", speechSeconds)) s)")
            #expect(start > 0.5 && start < 1.3, "segment starts at \(start) s, speech at 1.0 s")
            #expect(duration > speechSeconds * 0.5 && duration < speechSeconds + 1.0, "segment lasts \(duration) s for \(speechSeconds) s of speech")
            #expect(SpeechFixtures.rms(segment.samples) > 0.01)
            // The segment's samples are the input at that offset.
            let expected = Array(audio[segment.startSample..<min(audio.count, segment.startSample + segment.samples.count)])
            #expect(expected.count == segment.samples.count)
            #expect(zip(expected, segment.samples).allSatisfy { abs($0 - $1) < 1e-6 })
        }
        #expect(detector.popSegments().isEmpty, "segments are removed when returned")
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func resetForgetsEverythingAndSilenceYieldsNothing() throws {
        let detector = SileroVoiceActivityDetector(resources: SpeechFixtures.resources)
        try detector.prepare()
        let (audio, _, _) = try Self.paddedSpeech()
        detector.accept(Array(audio[0..<(audio.count / 2)]))   // half way through the words
        #expect(detector.isSpeechActive)
        detector.reset()
        #expect(!detector.isSpeechActive)
        #expect(detector.popSegments().isEmpty)

        // Two seconds of silence: no segment, and the offsets restart from the reset.
        detector.accept([Float](repeating: 0, count: 2 * Self.sampleRate))
        detector.flush()
        #expect(detector.popSegments().isEmpty)

        detector.reset()
        detector.accept(audio)
        detector.flush()
        let segments = detector.popSegments()
        #expect(segments.count == 1)
        #expect((segments.first?.startSample ?? 0) < 2 * Self.sampleRate, "offsets count from the last reset")
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func flushClosesAnOpenUtterance() throws {
        let detector = SileroVoiceActivityDetector(resources: SpeechFixtures.resources)
        try detector.prepare()
        let speech = try SpeechFixtures.spoken("one two three")
        detector.accept([Float](repeating: 0, count: Self.sampleRate) + speech)   // ends mid-utterance, with a partial window left over
        #expect(detector.popSegments().isEmpty, "no trailing silence yet, so the utterance is still open")
        detector.flush()
        let segments = detector.popSegments()
        #expect(segments.count == 1)
        #expect(!detector.isSpeechActive)
    }
}
