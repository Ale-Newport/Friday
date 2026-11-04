import CryptoKit
import Foundation
import Testing
import WakeWordKit
@testable import SherpaOnnxBackend

/// Tests against the real sherpa-onnx library and model. They run when the files have been fetched
/// (`Scripts/fetch-sherpa.sh`) and are skipped otherwise. Unlike a licensed engine, this one needs no key and no
/// network, so — for the first time in this project — a real detection can be verified end to end: the audio comes
/// from the Mac's own speech synthesiser, so no recording and no microphone are involved.
enum RealSherpa {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/SherpaOnnx")
    static let library = root.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib")
    static let profile = SherpaOnnxBackend.phoneModel
    static var modelDirectory: URL { root.appendingPathComponent("models/\(profile.directory)") }
    static var model: SherpaOnnxWakeWordEngine.ModelFiles {
        .init(
            encoder: modelDirectory.appendingPathComponent(profile.encoder), decoder: modelDirectory.appendingPathComponent(profile.decoder),
            joiner: modelDirectory.appendingPathComponent(profile.joiner), tokens: modelDirectory.appendingPathComponent(profile.tokens)
        )
    }
    static var isAvailable: Bool {
        ([library] + model.all).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var environment: EngineEnvironment {
        EngineEnvironment(resources: EngineResourceLocator(
            searchDirectories: [root.appendingPathComponent("models")], libraryDirectories: [root.appendingPathComponent("lib")]
        ))
    }

    /// The real files, plus a `jarvis_pronunciations.txt` with `content` in a folder of its own (like the user's Models folder).
    static func environment(pronunciationFile content: String) throws -> (EngineEnvironment, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-user-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try content.write(to: folder.appendingPathComponent("jarvis_pronunciations.txt"), atomically: true, encoding: .utf8)
        let environment = EngineEnvironment(resources: EngineResourceLocator(
            searchDirectories: [folder, root.appendingPathComponent("models")], libraryDirectories: [root.appendingPathComponent("lib")]
        ))
        return (environment, { try? FileManager.default.removeItem(at: folder) })
    }

    static func engine(
        sensitivity: Float = 0.5, levelNormaliser: LevelNormaliser.Configuration? = LevelNormaliser.Configuration()
    ) -> SherpaOnnxWakeWordEngine {
        SherpaOnnxWakeWordEngine(configuration: .init(
            libraryURL: library, model: model, pronunciations: profile.pronunciations, sensitivity: sensitivity,
            levelNormaliser: levelNormaliser
        ))
    }

    /// `clip` scaled so that its loudest sample is `peak` (linear): speech as a microphone farther away delivers it.
    static func scaled(_ clip: [Float], toPeak peak: Float) -> [Float] {
        let loudest = clip.reduce(0) { max($0, abs($1)) }
        return loudest > 0 ? clip.map { $0 * peak / loudest } : clip
    }

    // MARK: Audio from the system's own voices

    /// Whether `voice` is really installed. `say -v NAME` succeeds for a listed voice that is not downloaded and then
    /// speaks with the system's *default* voice, so a voice only counts if what it produces differs from that default.
    static func voiceExists(_ voice: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { return false }
        func bytes(_ arguments: [String]) -> Data? {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: output) }
            guard run("/usr/bin/say", arguments + ["-o", output.path, "Jarvis, what time is it?"]) else { return nil }
            return try? Data(contentsOf: output)
        }
        guard let requested = bytes(["-v", voice]), let fallback = bytes([]) else { return false }
        return requested != fallback
    }

    /// (The same launcher the app uses: Foundation's `Process` would pass the accents of a voice's name decomposed, and `say` would speak
    /// with the system's voice instead.)
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Bool {
        MacSpeech.run(tool, arguments)
    }

    private static let spoken = Protected<[String: [Float]]>([:])
    /// Synthesised clips are kept between test runs (the voices do not change), so only the first run pays for them.
    private static let cache = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-sherpa-tests", isDirectory: true)

    /// Mono samples of `text`, spoken by `voice`, at `rate` Hz (16 000 unless the test plays it through a microphone
    /// source running at the Mac's usual 48 000).
    static func speech(_ text: String, voice: String, rate: Int = 16_000) throws -> [Float] {
        let key = "\(voice)|\(text)|\(rate)"
        if let cached = spoken.withLock({ $0[key] }) { return cached }
        let name = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let wav = cache.appendingPathComponent("\(name).wav")
        if !FileManager.default.fileExists(atPath: wav.path) {
            let aiff = cache.appendingPathComponent("\(name)-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: aiff) }
            let part = cache.appendingPathComponent("\(name)-\(UUID().uuidString).wav")   // written whole, then moved into place
            guard run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text]),
                  run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@\(rate)", "-c", "1", aiff.path, part.path]) else {
                throw SpeechUnavailable()
            }
            if (try? FileManager.default.moveItem(at: part, to: wav)) == nil { try? FileManager.default.removeItem(at: part) }
        }
        let samples = try pcm(of: wav)
        spoken.withLock { $0[key] = samples }
        return samples
    }

    struct SpeechUnavailable: Error {}

    static func pcm(of url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
                return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map {
                    Float(Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8)) / 32768
                }
            }
            offset += 8 + size + (size & 1)
        }
        throw SpeechUnavailable()
    }

    /// Deterministic room noise of peak amplitude `level`.
    static func roomNoise(count: Int, level: Float, seed: UInt64 = 42) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(Int64(bitPattern: state >> 11) & 0xFFFFF) / Float(0xFFFFF) * 2 - 1) * level
        }
    }

    /// `clip` with room noise of peak amplitude `level` laid over it.
    static func roomNoiseMixed(_ clip: [Float], level: Float) -> [Float] {
        zip(clip, roomNoise(count: clip.count, level: level)).map { $0 + $1 }
    }

    /// How many times the engine fires while listening to `clip`, with half a second of room noise before it and a
    /// second after — as a microphone would deliver it (never digital silence). Starts from a fresh stream at the
    /// middle sensitivity.
    static func detections(in clip: [Float], engine: SherpaOnnxWakeWordEngine, noise: Float = 0.003, sensitivity: Float = 0.5, secondsAfter: Double = 1) throws -> Int {
        try engine.updateSensitivity(sensitivity)   // a fresh stream: nothing carries over from an earlier clip
        let padded = [Float](repeating: 0, count: 8_000) + clip + [Float](repeating: 0, count: Int(16_000 * secondsAfter))
        let mixed = zip(padded, roomNoise(count: padded.count, level: noise)).map { $0 + $1 }
        let frameLength = engine.audioRequirements.frameLength
        var count = 0
        var index = 0
        while index + frameLength <= mixed.count {
            let frame = AudioFrame(samples: Array(mixed[index..<index + frameLength]), sampleRate: 16_000, sequence: UInt64(index / frameLength), captureTime: .zero)
            if try engine.processAudio(frame) != nil { count += 1 }
            index += frameLength
        }
        return count
    }
}

@Suite(.enabled(if: RealSherpa.isAvailable, "run Scripts/fetch-sherpa.sh to enable"))
struct RealSherpaLibraryTests {
    @Test func theLibraryLoadsAndReportsTheVersionTheHeaderWasPinnedTo() throws {
        let bindings = try LibraryBindings.load(from: RealSherpa.library)
        #expect(bindings.version == "1.13.8", "the vendored header and the library must come from the same release; got \(bindings.version)")
    }

    @Test func loadingTheSameLibraryTwiceReusesTheTable() throws {
        #expect(try LibraryBindings.load(from: RealSherpa.library) === LibraryBindings.load(from: RealSherpa.library))
    }

    @Test func aMissingOrForeignLibraryIsAnAvailabilityProblem() {
        for url in [URL(fileURLWithPath: "/nonexistent/libsherpa-onnx-c-api.dylib"), RealSherpa.model.tokens] {
            do {
                _ = try LibraryBindings.load(from: url)
                Issue.record("expected failure for \(url.lastPathComponent)")
            } catch {
                guard case .engineUnavailable = error else { Issue.record("wrong error \(error)"); return }
                #expect(error.recovery == .needsUserAction(.installEngineFiles))
            }
        }
    }

    @Test func theRegisteredEngineIsAvailableAndBuildsWithoutAnyKey() async throws {
        #expect(SherpaOnnxBackend.descriptor.preflight(RealSherpa.environment) == .ready)
        let engine = try SherpaOnnxBackend.descriptor.makeEngine(RealSherpa.environment)
        let began = ContinuousClock.now
        try await engine.initialize()
        #expect(ContinuousClock.now - began < .seconds(60), "loading three small networks is not a long wait (about half a second; the bound allows for a sanitizer on a busy Mac)")
        #expect(engine.audioRequirements == AudioRequirements(sampleRate: 16_000, frameLength: 1_600))
        engine.shutdown()
    }

    /// Without the check the library throws a C++ exception from inside its C API and the whole process dies — this very
    /// test used to take the test runner down with it. Each of the four files is damaged in turn.
    @Test(arguments: ["encoder", "decoder", "joiner", "tokens"])
    func aDamagedFileIsRefusedInsteadOfAbortingTheProcess(_ role: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-damaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func copy(_ url: URL, damaged: Bool) throws -> URL {
            let target = directory.appendingPathComponent(url.lastPathComponent)
            var bytes = try Data(contentsOf: url)
            if damaged { bytes[bytes.count / 2] ^= 0xFF }   // one flipped byte
            try bytes.write(to: target)
            return target
        }
        let real = RealSherpa.model
        let model = SherpaOnnxWakeWordEngine.ModelFiles(
            encoder: try copy(real.encoder, damaged: role == "encoder"), decoder: try copy(real.decoder, damaged: role == "decoder"),
            joiner: try copy(real.joiner, damaged: role == "joiner"), tokens: try copy(real.tokens, damaged: role == "tokens")
        )
        let engine = SherpaOnnxWakeWordEngine(configuration: .init(libraryURL: RealSherpa.library, model: model, pronunciations: RealSherpa.profile.pronunciations))
        do {
            try await engine.initialize()
            Issue.record("a damaged \(role) must not be accepted")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            let name = try #require(model.all.first { $0.lastPathComponent.hasPrefix(role == "tokens" ? "tokens" : role) }).lastPathComponent
            #expect(detail.contains(name), "\(detail)")
        }
    }

    @Test func aPronunciationWithAnUnknownSoundIsRefusedInsteadOfExitingTheProcess() async throws {
        let engine = SherpaOnnxWakeWordEngine(configuration: .init(
            libraryURL: RealSherpa.library, model: RealSherpa.model, pronunciations: ["JH ZZZ R V"]
        ))
        do {
            try await engine.initialize()
            Issue.record("an unknown sound must not reach the library")
        } catch {
            guard case .invalidConfiguration(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("ZZZ"))
        }
    }

    /// The library compares bytes and answers a sound it cannot find by exiting the process. Spellings that Swift's `String`
    /// equality would have waved through (another Unicode form of a sound the model has) must be refused first; each of these
    /// took the whole process down, at every launch, before the check compared bytes.
    @Test(arguments: [
        ("“à” as a plus a combining accent", "JH AA1 R V AH0 S a\u{0300}"),
        ("the Kelvin sign in place of K", "JH AA1 R V IH0 \u{212A}"),
        ("the library's own marker", "<sos/eos>"),
        ("a tab inside a sound", "JH\tAA1 R V AH0 S"),
    ])
    func aSpellingTheLibraryDoesNotKnowIsRefusedInsteadOfExitingTheProcess(_ name: String, _ pronunciation: String) async throws {
        let engine = SherpaOnnxWakeWordEngine(configuration: .init(libraryURL: RealSherpa.library, model: RealSherpa.model, pronunciations: [pronunciation]))
        do {
            try await engine.initialize()
            Issue.record("\(name) must be refused")
        } catch {
            guard case .invalidConfiguration = error else { Issue.record("\(name): wrong error \(error)"); return }
        }
        // …while the exact bytes of a sound the model has (a Chinese syllable, written as one character) are fine.
        let control = SherpaOnnxWakeWordEngine(configuration: .init(libraryURL: RealSherpa.library, model: RealSherpa.model, pronunciations: ["JH AA1 R V AH0 S \u{00E0}"]))
        try await control.initialize()
        control.shutdown()
    }

    /// The whole path a user's file takes: Models folder → parsed → handed to the engine the descriptor builds → vetted against the
    /// real model's sounds. A sound the model lacks stops the engine with a message and leaves the process alone.
    @Test func aPronunciationFileWithASoundTheModelLacksStopsTheEngineWithAMessage() async throws {
        let (environment, cleanup) = try RealSherpa.environment(pronunciationFile: "# my accent\nJH AA1 R V AH0 S\nJH QQ R V IH0 S\n"); defer { cleanup() }
        let engine = try SherpaOnnxBackend.descriptor.makeEngine(environment)
        do {
            try await engine.initialize()
            Issue.record("a sound the model lacks must not start the engine")
        } catch {
            guard case .invalidConfiguration(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("JH QQ R V IH0 S") && detail.contains("QQ"), "\(detail)")
        }
        let (good, cleanupGood) = try RealSherpa.environment(pronunciationFile: "JH AA1 R B IH0 S\n"); defer { cleanupGood() }
        #expect(SherpaOnnxBackend.descriptor.preflight(good) == .ready)
        let fine = try SherpaOnnxBackend.descriptor.makeEngine(good)
        try await fine.initialize()
        fine.shutdown()
    }

    @Test func everyShippedPronunciationUsesOnlySoundsTheRealModelHas() async throws {
        let table = try TokenTable(contentsOf: RealSherpa.model.tokens)
        for pronunciation in SherpaOnnxBackend.phoneModel.pronunciations {
            #expect(table.unknownTokens(in: pronunciation).isEmpty, "\(pronunciation)")
        }
    }

    @Test(.enabled(if: RealSherpa.voiceExists("Samantha"), "needs a macOS voice"))
    func theRecogniserHearsTheSoundsOfAClearlySpokenJarvis() throws {
        let recognizer = SherpaSoundRecognizer(configuration: .init(libraryURL: RealSherpa.library, model: RealSherpa.model))
        try recognizer.initialize()
        defer { recognizer.shutdown() }
        let heard = recognizer.sounds(in: RealSherpa.roomNoiseMixed(try RealSherpa.speech("Jarvis", voice: "Samantha"), level: 0.002)).joined(separator: " ")
        #expect(heard.contains("JH AA1"), "a clear “Jarvis” starts with the sounds of its dictionary pronunciation: \(heard)")
        #expect(recognizer.sounds(in: [Float](repeating: 0, count: 16_000)).isEmpty, "silence is heard as nothing")
    }

    @Test func silenceAndRoomNoiseAreNeverMistakenForTheWord() async throws {
        let engine = RealSherpa.engine()
        try await engine.initialize()
        defer { engine.shutdown() }
        // A quiet room: the activity gate stays closed, so the model never even sees it.
        #expect(try RealSherpa.detections(in: [Float](repeating: 0, count: 16_000 * 30), engine: engine) == 0)
        // A noisy one: the gate is open, the model listens to all of it, and still hears nothing.
        #expect(try RealSherpa.detections(in: [Float](repeating: 0, count: 16_000 * 30), engine: engine, noise: 0.05) == 0, "even a noisy room")
    }
}

/// End to end, with the system's own voices. These pin what was measured with `jarvis-bench kws-eval`: the voices
/// listed here were heard every time, in every phrase, at the shipped settings.
@Suite(.enabled(if: RealSherpa.isAvailable && RealSherpa.voiceExists("Samantha") && RealSherpa.voiceExists("Moira"), "needs the sherpa files and macOS voices"))
struct RealSherpaDetectionTests {
    static let voices = ["Samantha", "Moira", "Rishi"].filter { RealSherpa.voiceExists($0) }
    static let phrases = ["Jarvis", "Hey Jarvis", "Jarvis, what time is it?", "Okay Jarvis, turn on the lights."]

    @Test func jarvisIsHeardByTheClearVoicesInMostPhrasesAndAlwaysWhenSaidOnItsOwn() async throws {
        let engine = RealSherpa.engine()
        try await engine.initialize()
        defer { engine.shutdown() }
        var heard = 0, total = 0
        var misses: [String] = []
        for voice in Self.voices {
            for phrase in Self.phrases {
                total += 1
                if try RealSherpa.detections(in: RealSherpa.speech(phrase, voice: voice), engine: engine) > 0 { heard += 1 } else { misses.append("\(voice): “\(phrase)”") }
            }
            #expect(try RealSherpa.detections(in: RealSherpa.speech("Jarvis", voice: voice), engine: engine) > 0, "\(voice) saying just “Jarvis”")
        }
        // Measured: every one of these. A real person is not a synthesiser, so this is a regression guard, not a promise.
        #expect(heard >= total - 1, "heard \(heard) of \(total); not heard: \(misses)")
    }

    @Test func aTwoSecondPauseAfterTheWordIsEnoughToDecide() async throws {
        let engine = RealSherpa.engine()
        try await engine.initialize()
        defer { engine.shutdown() }
        let word = try RealSherpa.speech("Jarvis", voice: "Samantha")
        let hits = try RealSherpa.detections(in: word, engine: engine, secondsAfter: 2)
        #expect(hits == 1, "exactly one detection per utterance, got \(hits)")
    }

    @Test func eachOfSeveralUtterancesInARowIsHeardOnceAndOnlyOnce() async throws {
        let engine = RealSherpa.engine()
        try await engine.initialize()
        defer { engine.shutdown() }
        for voice in ["Samantha", "Moira"] {   // the clear voices: the weaker ones may miss one of three, which is not what is tested here
            let word = try RealSherpa.speech("Jarvis", voice: voice)
            let pause = [Float](repeating: 0, count: 16_000 * 3 / 2)
            let hits = try RealSherpa.detections(in: word + pause + word + pause + word, engine: engine, secondsAfter: 2)
            #expect(hits == 3, "\(voice): three utterances, \(hits) detections")
        }
    }

    /// The level stage is what makes quiet speech audible to the model: at a peak of −32 dBFS, with the room noise scaled to match, the
    /// same utterances are heard far more often with it than without it.
    @Test func quietSpeechIsHeardBecauseOfTheLevelStage() async throws {
        let quiet: Float = 0.025   // −32 dBFS
        let clips = try Self.voices.flatMap { voice in try Self.phrases.map { RealSherpa.scaled(try RealSherpa.speech($0, voice: voice), toPeak: quiet) } }
        func heard(_ normaliser: LevelNormaliser.Configuration?) async throws -> Int {
            let engine = RealSherpa.engine(levelNormaliser: normaliser)
            try await engine.initialize()
            defer { engine.shutdown() }
            return try clips.reduce(0) { $0 + (try RealSherpa.detections(in: $1, engine: engine, noise: 0.00024) > 0 ? 1 : 0) }
        }
        let with = try await heard(LevelNormaliser.Configuration()), without = try await heard(nil)
        #expect(with >= clips.count - 2, "with the level stage: \(with) of \(clips.count)")
        #expect(with > without + 2, "without it: \(without) of \(clips.count)")
    }

    @Test func ordinarySpeechWithoutTheWordDoesNotActivate() async throws {
        let engine = RealSherpa.engine()
        try await engine.initialize()
        defer { engine.shutdown() }
        let text = "The committee met on Tuesday morning to review the proposal for the new library. Several members raised concerns about the budget, while others argued that the project would bring lasting benefits to the neighbourhood."
        for voice in Self.voices {
            #expect(try RealSherpa.detections(in: RealSherpa.speech(text, voice: voice), engine: engine) == 0, "\(voice) reading ordinary text")
        }
    }

    @Test func similarSoundingNamesAreMostlyIgnored() async throws {
        let engine = RealSherpa.engine()
        try await engine.initialize()
        defer { engine.shutdown() }
        var falseAccepts = 0
        let decoys = ["Travis", "Harvest", "Service", "Marvin", "Charles", "Garbage"]
        for voice in Self.voices {
            for decoy in decoys where try RealSherpa.detections(in: RealSherpa.speech(decoy, voice: voice), engine: engine) > 0 { falseAccepts += 1 }
        }
        // About 1 in 16 look-alike words is accepted at the middle of the slider (`kws-eval`: 17 of 338 at arm's length, 21 of 338 with
        // loud synthetic voices) — the price of hearing accents and "hey Jarvis" said in one breath. A bound that still fails if the
        // engine starts accepting most of them.
        #expect(falseAccepts <= 4, "\(falseAccepts) of \(decoys.count * Self.voices.count) look-alike words activated it")
    }

    @Test func moreSensitivityNeverHearsLess() async throws {
        let clips = try Self.voices.flatMap { voice in try Self.phrases.prefix(3).map { try RealSherpa.speech($0, voice: voice) } }
        func total(sensitivity: Float) async throws -> Int {
            let engine = RealSherpa.engine(sensitivity: sensitivity)
            try await engine.initialize()
            defer { engine.shutdown() }
            return try clips.reduce(0) { $0 + (try RealSherpa.detections(in: $1, engine: engine, sensitivity: sensitivity) > 0 ? 1 : 0) }
        }
        let strict = try await total(sensitivity: 0), loose = try await total(sensitivity: 1)
        #expect(loose >= strict, "strict \(strict), responsive \(loose)")
        #expect(loose > 0)
    }
}
