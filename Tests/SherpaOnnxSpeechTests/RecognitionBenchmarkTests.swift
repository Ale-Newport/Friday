import Foundation
import Testing
import FridaySpeech
@testable import SherpaOnnxSpeech

/// Benchmarks Apple's on-device recogniser on sentences synthesised by Kokoro (English and Spanish voices): word
/// error rate and finalisation latency per phrase. Kokoro is used instead of the `say` command because in-process
/// synthesis works everywhere the tests run. Writes a JSON report next to the TTS samples for docs/PERFORMANCE.md.
@Suite(.serialized) struct RecognitionBenchmarkTests {
    struct Phrase { let text: String; let voice: String; let language: String }

    static let phrases: [Phrase] = [
        Phrase(text: "open Chrome", voice: "af_heart", language: "en"),
        Phrase(text: "what's the weather tomorrow", voice: "af_heart", language: "en"),
        Phrase(text: "add milk, actually oat milk, to my groceries list", voice: "bm_daniel", language: "en"),
        Phrase(text: "find the cheapest direct flight from London to Barcelona next Friday", voice: "af_heart", language: "en"),
        Phrase(text: "abre Chrome", voice: "ef_dora", language: "es"),
        Phrase(text: "recuérdame comprar leche mañana a las ocho", voice: "ef_dora", language: "es"),
        Phrase(text: "pon la canción esa de Queen", voice: "em_alex", language: "es"),
        Phrase(text: "busca un hueco de dos horas para estudiar el viernes", voice: "ef_dora", language: "es"),
        Phrase(text: "abre Google and search for machine learning", voice: "ef_dora", language: "mixed"),
        Phrase(text: "pon mi playlist de estudiar y abre Notes", voice: "em_alex", language: "mixed"),
    ]

    static func resample(_ samples: [Float], from source: Int, to target: Int) -> [Float] {
        guard source != target, !samples.isEmpty else { return samples }
        let ratio = Double(source) / Double(target)
        let count = Int(Double(samples.count) / ratio)
        return (0..<count).map { i in
            let position = Double(i) * ratio
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let a = samples[min(index, samples.count - 1)]
            let b = samples[min(index + 1, samples.count - 1)]
            return a + (b - a) * fraction
        }
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        func words(_ s: String) -> [String] {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var d = Array(repeating: Array(repeating: 0, count: h.count + 1), count: r.count + 1)
        for i in 0...r.count { d[i][0] = i }
        for j in 0...h.count { d[0][j] = j }
        if r.count > 0, h.count > 0 {
            for i in 1...r.count { for j in 1...h.count { d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1)) } }
        }
        return Double(d[r.count][h.count]) / Double(r.count)
    }

    static func ms(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    @Test func appleRecognizerOnKokoroSpeech() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = SherpaOnnxSpeechResources.developmentDefault(repositoryRoot: root)
        let kokoro = KokoroTextToSpeech(resources: resources)
        guard case .available = await kokoro.availability() else { print("benchmark skipped: Kokoro not installed"); return }
        let recognizer = AppleSpeechRecognizer()
        guard case .available = await recognizer.availability() else { print("benchmark skipped: recogniser unavailable"); return }
        let voices = await kokoro.voices()
        var rows: [[String: Any]] = []
        var totalWER = 0.0
        var count = 0
        for phrase in Self.phrases {
            guard let voice = voices.first(where: { $0.id == phrase.voice }) else { continue }
            var synthesized: [Float] = []
            var rate = 24_000
            for try await chunk in kokoro.synthesize(phrase.text, voice: voice, rate: 1.0) {
                synthesized += chunk.samples
                rate = chunk.sampleRate
            }
            let samples = Self.resample(synthesized, from: rate, to: 16_000)
            guard samples.count > 1600 else { print("skip (no audio): \(phrase.text)"); continue }
            let session = try await recognizer.makeSession(language: .bilingual(primary: phrase.language == "en" ? .en : .es), vocabulary: ["Chrome", "Notes", "Queen", "Google"])
            let clock = ContinuousClock()
            let started = clock.now
            for chunk in stride(from: 0, to: samples.count, by: 1600) {
                session.feed(AudioChunk(samples: Array(samples[chunk..<min(chunk + 1600, samples.count)]), sampleRate: 16_000))
            }
            let fedAt = clock.now
            let final = await session.finish()
            let finishedAt = clock.now
            let wer = Self.wordErrorRate(reference: phrase.text, hypothesis: final.text)
            totalWER += wer
            count += 1
            let audioSeconds = Double(samples.count) / 16_000
            print(String(format: "[%@] \"%@\" → \"%@\"  WER %.2f  audio %.1fs  finalize %d ms  total %d ms", phrase.language, phrase.text, final.text, wer, audioSeconds, Self.ms(fedAt.duration(to: finishedAt)), Self.ms(started.duration(to: finishedAt))))
            rows.append(["language": phrase.language, "reference": phrase.text, "hypothesis": final.text, "wer": wer, "audio_seconds": audioSeconds, "finalize_ms": Self.ms(fedAt.duration(to: finishedAt)), "total_ms": Self.ms(started.duration(to: finishedAt)), "detected_language": final.language?.rawValue ?? "", "voice": phrase.voice])
        }
        guard count > 0 else { return }
        let average = totalWER / Double(count)
        print(String(format: "Apple SpeechAnalyzer average WER over %d Kokoro phrases: %.2f", count, average))
        let report: [String: Any] = ["engine": "apple-speechanalyzer", "audio": "kokoro", "phrases": rows, "average_wer": average, "date": ISO8601DateFormatter().string(from: Date())]
        // The report goes to $FRIDAY_BENCH_OUT when set, otherwise to a `friday-bench` folder in the temporary directory.
        let out = ProcessInfo.processInfo.environment["FRIDAY_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("friday-bench/stt-benchmark-apple.json")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: out)
        print("benchmark report written to \(out.path)")
        #expect(average < 0.6, "synthesised speech should be mostly recognised")
    }
}
