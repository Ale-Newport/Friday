import Foundation
import FridaySpeech
import Testing
@testable import SherpaOnnxSpeech

/// Serialized: each test with the model loads 113 MB of weights, and the timings printed are only meaningful when one
/// synthesis runs at a time.
@Suite(.serialized)
struct KokoroTextToSpeechTests {
    // MARK: Without the model

    @Test func exposesEveryVoiceWithItsLanguage() async {
        let engine = KokoroTextToSpeech(resources: SpeechFixtures.resources)
        let voices = await engine.voices()
        #expect(voices.count == 54)
        #expect(Set(voices.map(\.id)).count == 54)
        #expect(voices.allSatisfy { $0.engineID == "kokoro" })
        let byID = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0) })
        #expect(byID["af_heart"]?.language == "en-US")
        #expect(byID["af_heart"]?.name == "Heart (female)")
        #expect(byID["am_adam"]?.language == "en-US")
        #expect(byID["bf_emma"]?.language == "en-GB")
        #expect(byID["bm_daniel"]?.name == "Daniel (male)")
        #expect(byID["ef_dora"]?.language == "es-ES")
        #expect(byID["em_alex"]?.language == "es-ES")
        #expect(byID["em_santa"]?.language == "es-ES")
        #expect(byID["ff_siwis"]?.language == "fr-FR")
        #expect(byID["pm_santa"]?.language == "pt-BR")
        #expect(byID["zf_xiaobei"]?.language == "zh-CN")
        #expect(byID["ef_dora"]?.baseLanguage == .es)
        #expect(byID["af_heart"]?.baseLanguage == .en)
        // The speaker ids follow the model's own table.
        #expect(KokoroVoices.entry(for: "af_heart")?.speakerID == 3)
        #expect(KokoroVoices.entry(for: "ef_dora")?.speakerID == 28)
        #expect(KokoroVoices.entry(for: "em_santa")?.speakerID == 53)
        #expect(voices.filter { $0.language == "en-US" }.count == 20)
        #expect(voices.filter { $0.language == "es-ES" }.count == 3)
    }

    @Test func phonemisationLanguageFollowsTheVoice() {
        #expect(KokoroVoices.espeakVoice(forLanguage: "en-US") == nil)   // the lexicon
        #expect(KokoroVoices.espeakVoice(forLanguage: "en-GB") == "en-gb-x-rp")
        #expect(KokoroVoices.espeakVoice(forLanguage: "es-ES") == "es")
        #expect(KokoroVoices.espeakVoice(forLanguage: "fr-FR") == "fr")
    }

    @Test func reportsSetupNeededWhenFilesAreMissing() async {
        let nowhere = URL(fileURLWithPath: "/nonexistent/friday-\(UUID().uuidString)")
        let engine = KokoroTextToSpeech(resources: .developmentDefault(repositoryRoot: nowhere))
        let availability = await engine.availability()
        guard case .needsSetup(let reason) = availability else {
            Issue.record("expected needsSetup, got \(availability)")
            return
        }
        for text in [reason.en, reason.es] {
            #expect(text.contains("libsherpa-onnx-c-api.dylib"))
            #expect(text.contains("model.int8.onnx"))
            #expect(text.contains("fetch-speech-models"))
        }
        #expect(reason.en != reason.es)
        #expect(availability.detail(in: .es) == reason.es)
        #expect(EngineAvailability.available.detail(in: .en) == nil)

        // Synthesising without the files is an error on the stream, not a crash.
        let voice = await engine.voices()[0]
        await #expect(throws: SpeechError.self) {
            for try await _ in engine.synthesize("Hello", voice: voice, rate: 1) {}
        }
        #expect(engine.loadDuration == nil)
    }

    @Test func aBundleWithoutTheFilesSaysTheBuildIsIncomplete() async {
        // A packaged app cannot be fixed by running repository scripts: the message says so, and in both languages.
        let nowhere = URL(fileURLWithPath: "/nonexistent/friday-\(UUID().uuidString)")
        var resources = SherpaOnnxSpeechResources.developmentDefault(repositoryRoot: nowhere)
        resources.layout = .bundle
        let availability = await KokoroTextToSpeech(resources: resources).availability()
        guard case .needsSetup(let reason) = availability else {
            Issue.record("expected needsSetup, got \(availability)")
            return
        }
        #expect(reason.en.contains("This build of Friday was made without the speech files"))
        #expect(reason.en.contains("Rebuild the app"))
        #expect(reason.es.contains("Esta compilación de Friday se hizo sin los archivos de voz"))
        #expect(reason.es.contains("Vuelve a compilar"))
        #expect(reason.en.contains("model.int8.onnx") && reason.es.contains("model.int8.onnx"))
        // The development layout keeps the plain hint.
        resources.layout = .development
        #expect(resources.setupMessage(missing: ["voices.bin"]).en == "Missing voices.bin; run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh.")
        #expect(resources.setupMessage(missing: ["voices.bin"]).es == "Faltan voices.bin; ejecuta Scripts/fetch-sherpa.sh y Scripts/fetch-speech-models.sh.")
        #expect(SherpaOnnxSpeechResources.locate(bundle: .main)?.layout ?? .bundle == .bundle)
    }

    @Test func locatesFilesInABundleLayout() {
        guard let located = SherpaOnnxSpeechResources.locate(bundle: .main) else { return }   // a bare test runner has no frameworks folder
        #expect(located.libraryURL.lastPathComponent == "libsherpa-onnx-c-api.dylib")
        #expect(located.kokoroDirectory.lastPathComponent == "kokoro-multi-lang-v1_0")
        #expect(located.kokoroDirectory.deletingLastPathComponent().lastPathComponent == "Speech")
        #expect(located.sileroModelURL.lastPathComponent == "silero_vad.onnx")
    }

    @Test func rejectsAVoiceOfAnotherEngine() async {
        let engine = KokoroTextToSpeech(resources: SpeechFixtures.resources)
        let foreign = TTSVoice(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", engineID: "apple")
        await #expect(throws: SpeechError.synthesisFailed("com.apple.voice.compact.en-US.Samantha is not a Kokoro voice")) {
            for try await _ in engine.synthesize("Hello", voice: foreign, rate: 1) {}
        }
    }

    @Test func emptyTextProducesNoAudioAndNoError() async throws {
        let engine = KokoroTextToSpeech(resources: SpeechFixtures.resources)
        let voice = await engine.voices()[0]
        var chunks = 0
        for try await _ in engine.synthesize("   \n", voice: voice, rate: 1) { chunks += 1 }
        #expect(chunks == 0)
    }

    // MARK: With the model (skipped unless the Vendor files are installed)

    static let installed = SpeechFixtures.kokoroIsInstalled

    /// Synthesises `text` with `voiceID`, writes it to the samples folder and returns the audio with its timings.
    private func speak(
        _ text: String, voiceID: String, rate: Float = 1, engine: KokoroTextToSpeech, file: String
    ) async throws -> (samples: [Float], sampleRate: Int, chunks: Int, firstChunk: Duration, total: Duration) {
        let voice = try #require(await engine.voices().first { $0.id == voiceID })
        let clock = ContinuousClock()
        let started = clock.now
        var firstChunk: Duration?
        var samples: [Float] = []
        var sampleRate = 0
        var chunks = 0
        for try await chunk in engine.synthesize(text, voice: voice, rate: rate) {
            if firstChunk == nil { firstChunk = clock.now - started }
            chunks += 1
            samples += chunk.samples
            sampleRate = chunk.sampleRate
        }
        let total = clock.now - started
        let url = SpeechFixtures.samplesDirectory.appendingPathComponent(file)
        try SpeechFixtures.writeWAV(samples, sampleRate: sampleRate, to: url)
        print("kokoro \(voiceID) \"\(text)\": \(String(format: "%.2f", Double(samples.count) / Double(sampleRate))) s of audio, "
              + "\(chunks) chunk(s), first chunk after \(firstChunk ?? .zero), total \(total) → \(url.path)")
        return (samples, sampleRate, chunks, try #require(firstChunk), total)
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func speaksEnglishAndSpanishFromOneLoadedModel() async throws {
        let engine = KokoroTextToSpeech(resources: SpeechFixtures.resources)
        #expect(await engine.availability() == .available)

        try await engine.load()
        let loadDuration = try #require(engine.loadDuration)
        print("kokoro model load: \(loadDuration)")
        #expect(loadDuration < .seconds(20))

        let english = try await speak("Hello, I am Friday. How can I help?", voiceID: "af_heart", engine: engine, file: "kokoro-en-af_heart.wav")
        #expect(english.sampleRate == 24_000)
        #expect(SpeechFixtures.rms(english.samples) > 0.01, "English audio is silent")
        let englishSeconds = Double(english.samples.count) / Double(english.sampleRate)
        #expect(englishSeconds > 1 && englishSeconds < 6, "English audio lasts \(englishSeconds) s")
        #expect(english.chunks == 2, "two sentences, two chunks")
        #expect(english.firstChunk < english.total, "the first sentence arrives before the second is synthesised")

        let spanish = try await speak("Hola, soy Friday. ¿En qué puedo ayudarte?", voiceID: "ef_dora", engine: engine, file: "kokoro-es-ef_dora.wav")
        #expect(spanish.sampleRate == 24_000)
        #expect(SpeechFixtures.rms(spanish.samples) > 0.01, "Spanish audio is silent")
        let spanishSeconds = Double(spanish.samples.count) / Double(spanish.sampleRate)
        #expect(spanishSeconds > 1 && spanishSeconds < 6, "Spanish audio lasts \(spanishSeconds) s")
        #expect(spanish.chunks == 2)

        // Different words, different lengths: the Spanish was not read as English.
        #expect(abs(spanish.samples.count - english.samples.count) > 24_000 / 4)

        // A British voice goes through espeak-ng's Received Pronunciation and still speaks.
        let british = try await speak("Hello, I am Friday. How can I help?", voiceID: "bm_daniel", engine: engine, file: "kokoro-en-gb-bm_daniel.wav")
        #expect(SpeechFixtures.rms(british.samples) > 0.01)

        // Time to first audio should be well under what the whole text takes to say.
        #expect(english.firstChunk < .seconds(5))
        #expect(spanish.firstChunk < .seconds(5))
        #expect(engine.lastReport?.stoppedEarly == false)
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func rateChangesTheDuration() async throws {
        let engine = KokoroTextToSpeech(resources: SpeechFixtures.resources)
        let normal = try await speak("The weather today is sunny with a light breeze.", voiceID: "af_heart", engine: engine, file: "kokoro-rate-1.0.wav")
        let fast = try await speak("The weather today is sunny with a light breeze.", voiceID: "af_heart", rate: 1.5, engine: engine, file: "kokoro-rate-1.5.wav")
        #expect(Double(fast.samples.count) < Double(normal.samples.count) * 0.85, "rate 1.5 should be noticeably shorter")
        #expect(SpeechFixtures.rms(fast.samples) > 0.01)
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func cancellingTheConsumerStopsSynthesisEarly() async throws {
        let engine = KokoroTextToSpeech(resources: SpeechFixtures.resources)
        let voice = try #require(await engine.voices().first { $0.id == "af_heart" })
        let text = """
            The quick brown fox jumps over the lazy dog near the river bank this morning. \
            Meanwhile the farmer was counting his sheep in the field behind the old red barn. \
            Later that afternoon the children walked home from school along the dusty road. \
            In the evening everyone gathered around the table for a long and noisy dinner. \
            After dinner the grandfather told stories about the war and the years that followed. \
            Finally the house fell silent and the stars came out over the sleeping village.
            """
        try await engine.load()

        // Stop listening after the first sentence.
        let clock = ContinuousClock()
        let started = clock.now
        var received = 0
        for try await chunk in engine.synthesize(text, voice: voice, rate: 1) {
            received += chunk.samples.count
            break
        }
        await engine.waitUntilIdle()
        let elapsed = clock.now - started
        let report = try #require(engine.lastReport)
        print("kokoro cancellation: \(report.chunks) chunk(s) of 6 sentences generated in \(elapsed), stopped early: \(report.stoppedEarly)")
        #expect(report.stoppedEarly)
        #expect(report.chunks <= 2, "generation went on for \(report.chunks) sentences after the consumer left")
        #expect(received > 0)

        // And the same text consumed to the end is longer and takes longer.
        let full = try await speak(text, voiceID: "af_heart", engine: engine, file: "kokoro-six-sentences.wav")
        #expect(full.chunks == 6)
        #expect(full.samples.count > received * 3)
        #expect(full.total > elapsed)

        // Cancelling the consuming task works the same way.
        let task = Task {
            var count = 0
            for try await _ in engine.synthesize(text, voice: voice, rate: 1) {
                count += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return count
        }
        let count = try await task.value
        await engine.waitUntilIdle()
        #expect(count <= 2)
        #expect(engine.lastReport?.stoppedEarly == true)
    }

    @Test(.enabled(if: installed, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func warmUpLoadsTheModel() async throws {
        let engine = KokoroTextToSpeech(configuration: .init(resources: SpeechFixtures.resources, warmUpPhrase: "Ready."))
        #expect(engine.loadDuration == nil)
        await engine.warmUp()
        #expect(engine.loadDuration != nil)
        #expect(engine.lastReport?.chunks == 1)
        #expect(await engine.availability() == .available)
    }
}
