import Foundation
import Testing
import FridayCore
@testable import FridaySpeech
@testable import SherpaOnnxSpeech

/// The Settings ▸ Voice ▸ Vocabulary promise, end to end: phrases with unusual proper nouns are synthesised with
/// Kokoro and recognised by Apple's on-device recogniser with and without the vocabulary. With it, recognition
/// must not be worse on any phrase and must be better on at least one. Skipped (not failed) without the models.
@Suite(.serialized) struct VocabularyRecognitionTests {
    struct Phrase { let text: String; let voice: String; let language: Language; let vocabulary: [String] }

    static let phrases: [Phrase] = [
        Phrase(text: "open Zylora", voice: "af_heart", language: .en, vocabulary: ["Zylora"]),
        Phrase(text: "play some music by Vexlar", voice: "af_heart", language: .en, vocabulary: ["Vexlar"]),
        Phrase(text: "open Quorvix and search for flights", voice: "bm_daniel", language: .en, vocabulary: ["Quorvix"]),
        Phrase(text: "call Marc tomorrow", voice: "af_heart", language: .en, vocabulary: ["Marc"]),
        Phrase(text: "send it to Jon", voice: "af_heart", language: .en, vocabulary: ["Jon"]),
        // Control: ordinary words with a vocabulary that must not touch them.
        Phrase(text: "what's the weather tomorrow", voice: "af_heart", language: .en, vocabulary: ["Zylora", "Vexlar", "Quorvix", "Marc", "Jon"]),
        Phrase(text: "recuérdame comprar leche mañana a las ocho", voice: "ef_dora", language: .es, vocabulary: ["Zylora", "Marc", "Chrome"]),
    ]

    static func recognise(_ samples: [Float], recognizer: AppleSpeechRecognizer, language: Language, vocabulary: [String]) async throws -> (text: String, applied: [String]) {
        let session = try await recognizer.makeSession(language: .fixed(language), vocabulary: vocabulary)
        for start in stride(from: 0, to: samples.count, by: 1600) {
            session.feed(AudioChunk(samples: Array(samples[start..<min(start + 1600, samples.count)]), sampleRate: 16_000))
        }
        let final = await session.finish()
        let applied: [String]
        if #available(macOS 26, *), let apple = session as? AppleSession { applied = apple.contextualStrings } else { applied = [] }
        return (final.text, applied)
    }

    @Test(.enabled(if: SpeechFixtures.kokoroIsInstalled, "run Scripts/fetch-sherpa.sh and Scripts/fetch-speech-models.sh"))
    func vocabularyImprovesOrKeepsRecognitionOfProperNouns() async throws {
        let kokoro = KokoroTextToSpeech(resources: SpeechFixtures.resources)
        let recognizer = AppleSpeechRecognizer()
        guard case .available = await recognizer.availability() else {
            print("skipped: Apple recogniser not available: \(await recognizer.availability())")
            return
        }
        let voices = await kokoro.voices()
        var improved = 0
        var compared = 0
        for phrase in Self.phrases {
            let voice = try #require(voices.first { $0.id == phrase.voice })
            var synthesized: [Float] = []
            var rate = KokoroTextToSpeech.sampleRate
            for try await chunk in kokoro.synthesize(phrase.text, voice: voice, rate: 1) {
                synthesized += chunk.samples
                rate = chunk.sampleRate
            }
            let samples = RecognitionBenchmarkTests.resample(synthesized, from: rate, to: 16_000)
            try #require(samples.count > 1_600, "no audio for \(phrase.text)")

            let plain = try await Self.recognise(samples, recognizer: recognizer, language: phrase.language, vocabulary: [])
            let boosted = try await Self.recognise(samples, recognizer: recognizer, language: phrase.language, vocabulary: phrase.vocabulary)
            #expect(plain.applied.isEmpty)
            #expect(boosted.applied == phrase.vocabulary, "the words reached the session")

            let before = RecognitionBenchmarkTests.wordErrorRate(reference: phrase.text, hypothesis: plain.text)
            let after = RecognitionBenchmarkTests.wordErrorRate(reference: phrase.text, hypothesis: boosted.text)
            print(String(format: "[%@] \"%@\": without → \"%@\" (WER %.2f); with %@ → \"%@\" (WER %.2f)",
                         phrase.language.rawValue, phrase.text, plain.text, before, phrase.vocabulary.description, boosted.text, after))
            #expect(after <= before + 1e-9, "the vocabulary made \"\(phrase.text)\" worse: \"\(plain.text)\" → \"\(boosted.text)\"")
            compared += 1
            if after < before { improved += 1 }
            // Every word of the vocabulary that was spoken is in the transcript when it was close enough to be snapped.
            for word in phrase.vocabulary where phrase.text.localizedCaseInsensitiveContains(word) {
                if !boosted.text.contains(word) { print("  not recovered: \(word) in \"\(boosted.text)\"") }
            }
        }
        print("vocabulary: \(improved) of \(compared) phrases improved, none regressed")
        #expect(compared == Self.phrases.count)
        #expect(improved >= 1, "the vocabulary should fix at least one proper noun the recogniser misspells")
    }
}
