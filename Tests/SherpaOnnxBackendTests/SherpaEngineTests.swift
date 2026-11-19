import CryptoKit
import Foundation
import Testing
import WakeWordKit
@testable import SherpaOnnxBackend

// MARK: - Fake native layer

/// Stands in for libsherpa-onnx so the engine's own logic — configuration, activity gating, lifecycle, handle
/// ownership — is verified without the library or the model files.
final class FakeSherpa: SherpaBindings, @unchecked Sendable {
    private struct State {
        var spotterSettings: [SpotterSettings] = []
        var streamKeywords: [String] = []
        var fed: [[Float]] = []
        var resets = 0
        var destroyedSpotters: [UInt] = []
        var destroyedStreams: [UInt] = []
        var next: UInt = 0x1000
        var heardOnFeed: Set<Int> = []
        var spotterAttempts = 0
        var streamAttempts = 0
    }
    private let state = Protected(State())
    let version = "fake-1.0"
    var failSpotter: NativeFailure?
    var failStream: NativeFailure?
    /// When set, `makeSpotter` blocks until the semaphore is signalled (to test races with shutdown).
    var spotterGate: DispatchSemaphore?
    /// The same for `makeStream`.
    var streamGate: DispatchSemaphore?

    var spotterSettings: [SpotterSettings] { state.withLock { $0.spotterSettings } }
    var streamKeywords: [String] { state.withLock { $0.streamKeywords } }
    var fed: [[Float]] { state.withLock { $0.fed } }
    var resets: Int { state.withLock { $0.resets } }
    var destroyedSpotters: [UInt] { state.withLock { $0.destroyedSpotters } }
    var destroyedStreams: [UInt] { state.withLock { $0.destroyedStreams } }
    /// How many times `makeSpotter` was entered (even if it is still blocked on `spotterGate`).
    var spotterAttempts: Int { state.withLock { $0.spotterAttempts } }
    var streamAttempts: Int { state.withLock { $0.streamAttempts } }
    /// The keyword is "heard" when the n-th (0-based) feed call happens.
    func hear(onFeed indices: Set<Int>) { state.withLock { $0.heardOnFeed = indices } }

    func makeSpotter(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer {
        state.withLock { $0.spotterAttempts += 1 }
        spotterGate?.wait()
        if let failSpotter { throw failSpotter }
        return state.withLock { state in
            state.spotterSettings.append(settings)
            state.next += 0x10
            return OpaquePointer(bitPattern: state.next)!
        }
    }

    func destroySpotter(_ spotter: OpaquePointer) { state.withLock { $0.destroyedSpotters.append(UInt(bitPattern: spotter)) } }

    func makeStream(spotter: OpaquePointer, keywords: String) throws(NativeFailure) -> OpaquePointer {
        state.withLock { $0.streamAttempts += 1 }
        streamGate?.wait()
        if let failStream { throw failStream }
        return state.withLock { state in
            state.streamKeywords.append(keywords)
            state.next += 0x10
            return OpaquePointer(bitPattern: state.next)!
        }
    }

    func destroyStream(_ stream: OpaquePointer) { state.withLock { $0.destroyedStreams.append(UInt(bitPattern: stream)) } }

    func reset(spotter: OpaquePointer, stream: OpaquePointer) { state.withLock { $0.resets += 1 } }

    func feed(spotter: OpaquePointer, stream: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> String? {
        let copy = Array(UnsafeBufferPointer(start: samples, count: count))
        return state.withLock { state in
            let index = state.fed.count
            state.fed.append(copy)
            return state.heardOnFeed.contains(index) ? "JARVIS" : nil
        }
    }
}

enum Fixture {
    /// Real files on disk so the engine's existence checks pass.
    /// A tiny token table: the sounds A–D, in the library's own "TOKEN ID" layout.
    static let tokenTable = "<blk> 0\nA 1\nB 2\nC 3\nD 4\n"

    static func model(
        encoder: String = "x", decoder: String = "x", joiner: String = "x", tokens: String = Fixture.tokenTable
    ) throws -> (files: SherpaOnnxWakeWordEngine.ModelFiles, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func file(_ name: String, _ content: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            return url
        }
        let files = SherpaOnnxWakeWordEngine.ModelFiles(
            encoder: try file("encoder.onnx", encoder), decoder: try file("decoder.onnx", decoder),
            joiner: try file("joiner.onnx", joiner), tokens: try file("tokens.txt", tokens)
        )
        return (files, { try? FileManager.default.removeItem(at: directory) })
    }

    /// The digests the four files have right now (what a real installation would have pinned).
    static func digests(of files: SherpaOnnxWakeWordEngine.ModelFiles) throws -> ModelDigests {
        func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
        return ModelDigests(encoder: try digest(files.encoder), decoder: try digest(files.decoder), joiner: try digest(files.joiner), tokens: try digest(files.tokens))
    }

    static func engine(
        _ bindings: FakeSherpa, model: SherpaOnnxWakeWordEngine.ModelFiles, sensitivity: Float = 0.5,
        gate: ActivityGate.Configuration? = nil, pronunciations: [String] = ["A B C", "A B D"], resolutions: Protected<Int>? = nil,
        integrity: ModelIntegrity = .unverified, normaliser: LevelNormaliser.Configuration? = nil
    ) -> SherpaOnnxWakeWordEngine {
        SherpaOnnxWakeWordEngine(
            configuration: .init(
                libraryURL: URL(fileURLWithPath: "/nonexistent/libsherpa-onnx-c-api.dylib"), model: model,
                pronunciations: pronunciations, sensitivity: sensitivity, activityGate: gate, levelNormaliser: normaliser, integrity: integrity
            ),
            makeBindings: { resolutions?.withLock { $0 += 1 }; return bindings }
        )
    }

    /// A frame of constant `amplitude` (so its level is exactly known).
    static func frame(amplitude: Float = 0.1, count: Int = 1_600, rate: Int = 16_000) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: amplitude, count: count), sampleRate: rate, sequence: 0, captureTime: .zero)
    }

    static let loud: Float = 0.1       // −20 dBFS
    static let quiet: Float = 0.0005   // −66 dBFS
}

// MARK: - Engine behaviour

struct SherpaEngineLogicTests {
    @Test func initializationPassesTheModelAndTheKeywordDefinitionToTheNativeLibrary() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, sensitivity: 0.5)
        try await engine.initialize()

        let settings = try #require(bindings.spotterSettings.first)
        #expect(settings.encoder == model.files.encoder.path && settings.decoder == model.files.decoder.path)
        #expect(settings.joiner == model.files.joiner.path && settings.tokens == model.files.tokens.path)
        #expect(settings.numThreads == 1, "one thread: fanning out costs more than it saves for a model this small")
        #expect(settings.maxActivePaths == 12, "twelve alternative readings are kept alive: the strongest accuracy knob the library has")
        // Mid-slider: boost 1.5, threshold 0.06, one entry per pronunciation, all with the same label.
        #expect(settings.initialKeywords == "A B C :1.500 #0.060 @JARVIS/A B D :1.500 #0.060 @JARVIS")
        #expect(bindings.streamKeywords == [settings.initialKeywords])
        #expect(engine.audioRequirements == AudioRequirements(sampleRate: 16_000, frameLength: 1_600))
        #expect(engine.identifier == "sherpa-onnx")
    }

    @Test func theNativeLibraryIsResolvedOnceNotOnEveryFrame() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let resolutions = Protected(0)
        let engine = Fixture.engine(bindings, model: model.files, resolutions: resolutions)
        try await engine.initialize()
        for _ in 0..<100 { _ = try engine.processAudio(Fixture.frame()) }
        engine.shutdown()
        #expect(resolutions.get() == 1)
    }

    @Test func aHeardKeywordBecomesAJarvisDetectionWithNoInventedConfidence() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        bindings.hear(onFeed: [2])
        let engine = Fixture.engine(bindings, model: model.files)
        try await engine.initialize()
        #expect(try engine.processAudio(Fixture.frame()) == nil)
        #expect(try engine.processAudio(Fixture.frame()) == nil)
        let detection = try #require(try engine.processAudio(Fixture.frame()))
        #expect(detection.keyword == .jarvis && detection.confidence == nil)
        #expect(try engine.processAudio(Fixture.frame()) == nil, "one detection per hearing")
    }

    @Test func theLifecycleContractHolds() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files)

        #expect(throws: WakeWordError.notInitialized) { try engine.processAudio(Fixture.frame()) }
        #expect(throws: WakeWordError.notInitialized) { try engine.updateSensitivity(0.4) }
        try await engine.initialize()
        try await engine.initialize()      // idempotent
        #expect(bindings.spotterSettings.count == 1)
        #expect(throws: WakeWordError.invalidFrame(expected: 1_600, actual: 512)) { try engine.processAudio(Fixture.frame(count: 512)) }
        let wrongRate = throwsError { () throws(WakeWordError) -> DetectionResult? in try engine.processAudio(Fixture.frame(rate: 8_000)) }
        if case .invalidConfiguration? = wrongRate {} else { Issue.record("a wrong sample rate must be rejected, got \(String(describing: wrongRate))") }

        engine.shutdown()
        engine.shutdown()                  // idempotent
        #expect(throws: WakeWordError.shutDown) { try engine.processAudio(Fixture.frame()) }
        #expect(throws: WakeWordError.shutDown) { try engine.updateSensitivity(0.4) }
        await #expect(throws: WakeWordError.shutDown) { try await engine.initialize() }
        #expect(bindings.destroyedSpotters.count == 1 && bindings.destroyedStreams.count == 1, "each native object is released exactly once")
    }

    @Test func aNewSensitivityBuildsAFreshStreamWithoutReloadingTheModel() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, sensitivity: 0.5)
        try await engine.initialize()
        try engine.updateSensitivity(1.0)

        #expect(bindings.spotterSettings.count == 1, "the three neural networks stay loaded")
        #expect(bindings.streamKeywords.count == 2)
        #expect(bindings.streamKeywords[1].hasPrefix("A B C :2.000 #0.060 @JARVIS"), "the responsive end: boost 2.0")
        #expect(bindings.destroyedStreams.count == 1, "the old stream is released")
        #expect(throws: WakeWordError.invalidConfiguration("sensitivity 1.5 is outside 0...1")) { try engine.updateSensitivity(1.5) }
        #expect(bindings.streamKeywords.count == 2)
        _ = try engine.processAudio(Fixture.frame())
        engine.shutdown()
        #expect(bindings.destroyedStreams.count == 2 && bindings.destroyedSpotters.count == 1)
    }

    @Test func moreSensitivityNeverMakesTheKeywordHarderToTrigger() {
        let tuning = KeywordTuning.default
        var previous = tuning.values(forSensitivity: 0)
        for step in 1...20 {
            let current = tuning.values(forSensitivity: Float(step) / 20)
            #expect(current.boost >= previous.boost, "boost never falls as sensitivity rises")
            #expect(current.threshold <= previous.threshold, "the threshold never rises as sensitivity rises")
            previous = current
        }
        let strict = tuning.values(forSensitivity: 0), loose = tuning.values(forSensitivity: 1)
        #expect(strict.boost == 1.0 && loose.boost == 2.0 && strict.threshold == 0.06 && loose.threshold == 0.06)
        #expect(tuning.values(forSensitivity: -3) == strict && tuning.values(forSensitivity: 9) == loose, "out-of-range values are clamped")
    }

    // MARK: Failures

    @Test func missingModelFilesAreNamedAndNeedTheUserToInstallThem() async throws {
        let model = try Fixture.model()
        model.cleanup()   // the files are gone
        let engine = Fixture.engine(FakeSherpa(), model: model.files)
        do {
            try await engine.initialize()
            Issue.record("expected failure")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("encoder.onnx") && detail.contains("tokens.txt"))
            #expect(error.recovery == .needsUserAction(.installEngineFiles))
        }
    }

    @Test func aLibraryThatCannotBeLoadedIsReportedAsAnAvailabilityProblem() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let engine = SherpaOnnxWakeWordEngine(
            configuration: .init(libraryURL: URL(fileURLWithPath: "/x/lib.dylib"), model: model.files, pronunciations: ["A"], integrity: .unverified),
            makeBindings: { () throws(WakeWordError) -> any SherpaBindings in throw .engineUnavailable("could not load lib.dylib: no such file") }
        )
        await #expect(throws: WakeWordError.engineUnavailable("could not load lib.dylib: no such file")) { try await engine.initialize() }
    }

    @Test func aSpotterThatCannotBeBuiltLeavesAnUnusableEngineNotAHalfAliveOne() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        bindings.failSpotter = NativeFailure(message: "the model files do not match each other")
        let engine = Fixture.engine(bindings, model: model.files)
        do {
            try await engine.initialize()
            Issue.record("expected failure")
        } catch {
            #expect(error == .engineUnavailable("the model files do not match each other"))
        }
        #expect(throws: WakeWordError.notInitialized) { try engine.processAudio(Fixture.frame()) }
    }

    @Test func aKeywordThatIsNotUnderstoodReleasesTheSpotterItAlreadyBuilt() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        bindings.failStream = NativeFailure(message: "the keyword definition was not understood")
        let engine = Fixture.engine(bindings, model: model.files)
        await #expect(throws: WakeWordError.engineUnavailable("the keyword definition was not understood")) { try await engine.initialize() }
        #expect(bindings.destroyedSpotters.count == 1, "nothing leaks when the second step fails")
    }

    @Test func aModelFileThatIsNotTheOneShippedIsRefusedBeforeTheLibraryCanChokeOnIt() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        // The library answers a bad model with an exception that aborts the whole process, so it must never see one.
        let wrong = ModelDigests(encoder: String(repeating: "0", count: 64), decoder: String(repeating: "1", count: 64),
                                 joiner: String(repeating: "2", count: 64), tokens: String(repeating: "3", count: 64))
        let engine = Fixture.engine(bindings, model: model.files, integrity: .verified(wrong))
        do {
            try await engine.initialize()
            Issue.record("expected failure")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("encoder.onnx") && detail.contains("tokens.txt") && detail.contains("fetch-sherpa.sh"))
            #expect(error.recovery == .needsUserAction(.installEngineFiles))
        }
        #expect(bindings.spotterSettings.isEmpty, "nothing reached the native layer")
    }

    @Test func aModelFileThatMatchesItsDigestIsAccepted() async throws {
        let model = try Fixture.model(encoder: "enc", decoder: "dec", joiner: "joi"); defer { model.cleanup() }
        let engine = Fixture.engine(FakeSherpa(), model: model.files, integrity: .verified(try Fixture.digests(of: model.files)))
        try await engine.initialize()
        engine.shutdown()
    }

    /// Each of the four files is checked on its own: damaging any one of them is refused, and only that one is named.
    @Test(arguments: ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"])
    func aDamagedFileIsRefusedWhicheverOfTheFourItIs(damaged name: String) async throws {
        let model = try Fixture.model(encoder: "enc", decoder: "dec", joiner: "joi"); defer { model.cleanup() }
        let pinned = try Fixture.digests(of: model.files)
        let victim = try #require(model.files.all.first { $0.lastPathComponent == name })
        var content = try Data(contentsOf: victim)
        content.append(0x20)   // one stray byte, as a truncated or edited download might have
        try content.write(to: victim)
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, integrity: .verified(pinned))
        do {
            try await engine.initialize()
            Issue.record("a damaged \(name) must be refused")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            let named = ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"].filter { detail.contains($0) }
            #expect(named == [name], "exactly the damaged file is named: \(detail)")
        }
        #expect(bindings.spotterSettings.isEmpty, "nothing reached the native layer")
    }

    /// A file the installation does know, in the wrong place, is not accepted: the check is per role, not "any known file".
    @Test func aFileOfTheRightKindInTheWrongRoleIsNotAccepted() async throws {
        let model = try Fixture.model(encoder: "enc", decoder: "dec", joiner: "joi"); defer { model.cleanup() }
        let pinned = try Fixture.digests(of: model.files)
        // The encoder and decoder files swap places; every file is one this version knows.
        let swapped = SherpaOnnxWakeWordEngine.ModelFiles(encoder: model.files.decoder, decoder: model.files.encoder, joiner: model.files.joiner, tokens: model.files.tokens)
        let engine = Fixture.engine(FakeSherpa(), model: swapped, integrity: .verified(pinned))
        do {
            try await engine.initialize()
            Issue.record("expected failure")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("decoder.onnx") && detail.contains("encoder.onnx"), "both files are in the wrong role: \(detail)")
        }
    }

    @Test func aPronunciationMadeOfSoundsTheModelDoesNotHaveIsRefusedNotPassedOn() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        // Handed to the library, an unknown sound makes it log an error and exit the process.
        let engine = Fixture.engine(bindings, model: model.files, pronunciations: ["A B C", "A ZZ Q"])
        do {
            try await engine.initialize()
            Issue.record("expected failure")
        } catch {
            guard case .invalidConfiguration(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("A ZZ Q") && detail.contains("ZZ") && detail.contains("Q"))
        }
        #expect(bindings.spotterSettings.isEmpty)
    }

    @Test func aPronunciationCannotSmuggleInTheLibrarysOwnSyntax() async throws {
        // A table in which even the *tokens* contain the library's syntax characters (the real one has "<sos/eos>"): such a
        // token must never be offered, or a pronunciation could carry a keyword separator, a boost, a threshold or a label.
        let table = "<blk> 0\nA 1\nB 2\nB/C 3\nD:1 4\n#E 5\n@F 6\n<sos/eos> 7\n"
        let model = try Fixture.model(tokens: table); defer { model.cleanup() }
        for evil in ["A B @OTHER", "A B :99", "A B #abc", "A/B", "A B/C", "A D:1", "A #E", "A @F", "<sos/eos>", "A <sos/eos>", "", "   "] {
            let engine = Fixture.engine(FakeSherpa(), model: model.files, pronunciations: [evil])
            do {
                try await engine.initialize()
                Issue.record("“\(evil)” must be refused")
            } catch {
                guard case .invalidConfiguration = error else { Issue.record("wrong error for “\(evil)”: \(error)"); continue }
            }
        }
        // …while the ordinary tokens of the same table still work.
        let fine = Fixture.engine(FakeSherpa(), model: model.files, pronunciations: ["A B"])
        try await fine.initialize()
        fine.shutdown()
    }

    /// The library compares bytes; Swift's `String` equality does not. A spelling that Swift considers the same token but
    /// the library does not know makes the library exit the process — at every launch, for as long as the file stays.
    @Test func aTokenSpelledInAnotherUnicodeFormIsNotTheTokenTheLibraryKnows() async throws {
        let table = Fixture.tokenTable + "\u{00E0} 5\nK 6\n"   // "à" as one character, and a plain K
        let model = try Fixture.model(tokens: table); defer { model.cleanup() }
        func result(_ pronunciation: String) async -> WakeWordError? {
            let engine = Fixture.engine(FakeSherpa(), model: model.files, pronunciations: [pronunciation])
            defer { engine.shutdown() }
            do throws(WakeWordError) { try await engine.initialize(); return nil } catch { return error }
        }
        #expect(await result("A \u{00E0}") == nil, "the exact bytes are accepted")
        #expect(await result("A K") == nil)
        if case .invalidConfiguration? = await result("A a\u{0300}") {} else { Issue.record("“a” + combining grave is the same letter to Swift, not to the library") }
        if case .invalidConfiguration? = await result("A \u{212A}") {} else { Issue.record("the Kelvin sign is not the letter K to the library") }
    }

    @Test func aHandEditedFileCannotMakeTheKeywordAutomatonAbsurd() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let most = Array(repeating: "A B C", count: PronunciationLimits.pronunciations)
        let engine = Fixture.engine(FakeSherpa(), model: model.files, pronunciations: most)
        try await engine.initialize()   // the limit itself is fine
        engine.shutdown()

        func refused(_ pronunciations: [String]) async -> String? {
            let engine = Fixture.engine(FakeSherpa(), model: model.files, pronunciations: pronunciations)
            do throws(WakeWordError) { try await engine.initialize(); return nil } catch {
                if case .invalidConfiguration(let detail) = error { return detail }
                return "wrong error \(error)"
            }
        }
        let tooMany = await refused(most + ["A B C"])
        #expect(tooMany?.contains("33") == true, "got \(String(describing: tooMany))")
        let longest = Array(repeating: "A", count: PronunciationLimits.soundsPerPronunciation).joined(separator: " ")
        #expect(await refused([longest]) == nil)
        let tooLong = await refused([longest + " B"])
        #expect(tooLong?.contains("49 sounds") == true, "got \(String(describing: tooLong))")
        // A message about a monster line stays short.
        let monster = await refused([String(repeating: "A ", count: 100_000)])
        #expect((monster?.count ?? 0) < 300, "the message is an excerpt, not the file")
    }

    @Test(arguments: [
        (0, 4, 1), (-3, 4, 1), (33, 4, 1), (Int.max, 4, 1),     // threads
        (1, 0, 1), (1, -1, 1), (1, 257, 1), (1, Int.max, 1),    // alternative readings
        (1, 4, -1), (1, 4, 65), (1, 4, Int.max),                // trailing blanks
    ])
    func nonsenseNativeSettingsAreRefusedBeforeTheyReachTheLibrary(threads: Int, paths: Int, blanks: Int) async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = SherpaOnnxWakeWordEngine(
            configuration: .init(libraryURL: URL(fileURLWithPath: "/x"), model: model.files, pronunciations: ["A B"],
                                 numThreads: threads, numTrailingBlanks: blanks, maxActivePaths: paths, integrity: .unverified),
            makeBindings: { bindings }
        )
        do {
            try await engine.initialize()
            Issue.record("threads \(threads), readings \(paths), blanks \(blanks) must be refused")
        } catch {
            guard case .invalidConfiguration = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(bindings.spotterSettings.isEmpty, "the library never saw them")
    }

    @Test func aTuningThatProducesNoNumberIsRefusedNotWrittenIntoTheKeyword() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = SherpaOnnxWakeWordEngine(
            configuration: .init(libraryURL: URL(fileURLWithPath: "/x"), model: model.files, pronunciations: ["A B"],
                                 tuning: KeywordTuning(boostAtZero: .nan, boostAtOne: 2, thresholdAtZero: 0.06, thresholdAtOne: 0.06), integrity: .unverified),
            makeBindings: { bindings }
        )
        do {
            try await engine.initialize()
            Issue.record("a NaN boost must be refused")
        } catch {
            guard case .invalidConfiguration = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(bindings.spotterSettings.isEmpty)
        // And a threshold of zero has no ratio to interpolate with: the tuning falls back to a straight line, never NaN.
        let odd = KeywordTuning(boostAtZero: 1, boostAtOne: 2, thresholdAtZero: 0, thresholdAtOne: 0.1)
        let value = odd.values(forSensitivity: 0.5)
        #expect(value.threshold.isFinite && value.threshold > 0 && value.threshold < 0.1)
        #expect(KeywordTuning.default.values(forSensitivity: .nan).boost.isFinite)
    }

    @Test func aShutdownWhileTheModelIsLoadingReleasesWhatWasBuilt() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let gate = DispatchSemaphore(value: 0)
        bindings.spotterGate = gate
        let engine = Fixture.engine(bindings, model: model.files)
        let loading = Task { () -> WakeWordError? in
            do throws(WakeWordError) { try await engine.initialize(); return nil } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(50))   // initialisation is now blocked inside the native call
        engine.shutdown()
        gate.signal()
        #expect(await loading.value == .shutDown)
        #expect(bindings.destroyedSpotters.count == 1 && bindings.destroyedStreams.count == 1)
    }

    @Test func aShutdownWhileANewStreamIsBeingBuiltLeavesNothingBehind() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files)
        try await engine.initialize()
        let gate = DispatchSemaphore(value: 0)
        bindings.streamGate = gate
        let before = bindings.streamAttempts
        // updateSensitivity is synchronous and will block inside the fake native call: run it on its own thread (#8).
        let updating = Task {
            await offPool { () -> WakeWordError? in
                do throws(WakeWordError) { try engine.updateSensitivity(1); return nil } catch { return error }
            }
        }
        for _ in 0..<500 where bindings.streamAttempts == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(bindings.streamAttempts == before + 1, "the update is blocked inside the native call")
        engine.shutdown()
        gate.signal()
        #expect(await updating.value == .shutDown)
        #expect(bindings.destroyedStreams.count == 2 && bindings.destroyedSpotters.count == 1, "the original and the new stream are both released")
    }

    @Test func twoInitializationsAtOnceKeepOneSetOfNativeObjectsAndNeitherFails() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let gate = DispatchSemaphore(value: 0)
        bindings.spotterGate = gate
        let engine = Fixture.engine(bindings, model: model.files)
        func initialising() -> Task<WakeWordError?, Never> {
            Task { () -> WakeWordError? in
                do throws(WakeWordError) { try await engine.initialize(); return nil } catch { return error }
            }
        }
        let first = initialising(), second = initialising()
        for _ in 0..<500 where bindings.spotterAttempts < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(bindings.spotterAttempts == 2, "both were inside the native call at the same time")
        gate.signal()
        gate.signal()
        #expect(await first.value == nil)
        #expect(await second.value == nil, "the second one finds the engine already ready: that is success, not an error")
        #expect(bindings.destroyedSpotters.count == 1 && bindings.destroyedStreams.count == 1, "the loser's native objects are released")
        _ = try engine.processAudio(Fixture.frame())   // and the engine is usable
        engine.shutdown()
        #expect(bindings.destroyedSpotters.count == 2 && bindings.destroyedStreams.count == 2, "each object released exactly once")
    }

    @Test func anEngineWithNoPronunciationsIsRefusedBeforeAnythingIsLoaded() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, pronunciations: [])
        await #expect(throws: WakeWordError.invalidConfiguration("no pronunciation of the keyword configured")) { try await engine.initialize() }
        #expect(bindings.spotterSettings.isEmpty)
    }
}

/// Runs `body` and returns the typed error it threw, if any.
func throwsError<T>(_ body: () throws(WakeWordError) -> T) -> WakeWordError? {
    do { _ = try body(); return nil } catch { return error }
}

// MARK: - The activity gate inside the engine

struct SherpaActivityGatingTests {
    static let gate = ActivityGate.Configuration()

    @Test func aQuietRoomNeverReachesTheNeuralModel() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate)
        try await engine.initialize()
        for _ in 0..<200 { #expect(try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) == nil) }
        #expect(bindings.fed.isEmpty, "twenty seconds of silence cost the model nothing")
        #expect(engine.activity.skipped == 200)
    }

    @Test func whenTheRoomGetsLouderTheModelStartsFreshAndHearsTheLeadInToo() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate)
        try await engine.initialize()
        for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        let before = bindings.resets
        _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud))
        #expect(bindings.resets == before + 1, "a clean slate for the new stretch of sound")
        #expect(bindings.fed.count == Self.gate.preRollFrames + 1, "the last moments of quiet, then the loud frame: \(bindings.fed.count)")
        #expect(bindings.fed.last == [Float](repeating: Fixture.loud, count: 1_600))
        _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud))
        #expect(bindings.resets == before + 1, "no reset while the sound continues")
    }

    @Test func theLeadInIsTheLastQuietFramesInTheOrderTheyArrived() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate)
        try await engine.initialize()
        // Every quiet frame is slightly different, so a lead-in that is the wrong frames, or the right ones reversed, shows.
        func quiet(_ index: Int) -> Float { Fixture.quiet + Float(index) * 0.00001 }
        for index in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: quiet(index))) }
        _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud))
        let leadIn = bindings.fed.dropLast().map { $0[0] }
        #expect(leadIn == (24..<30).map(quiet), "the six most recent quiet frames, oldest first: \(leadIn)")
        #expect(bindings.fed.last?[0] == Fixture.loud)
    }

    /// A frame of NaN, infinity or absurdly large numbers is not audio. Fed to the model it would poison the streaming state, and
    /// in a noisy room (gate always open) nothing would ever clean it.
    @Test(arguments: [Float.nan, Float.infinity, -Float.infinity, 1e30, 1e15])
    func aFrameThatIsNotAudioIsNeverFedAndTheModelStartsAfreshAfterIt(bad: Float) async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate)
        try await engine.initialize()
        for _ in 0..<5 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud)) }   // a noisy room: the gate is open
        let fed = bindings.fed.count, resets = bindings.resets
        #expect(try engine.processAudio(Fixture.frame(amplitude: bad)) == nil)
        #expect(bindings.fed.count == fed, "the bad frame never reaches the model")
        _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud))
        #expect(bindings.resets == resets + 1, "the model starts afresh at the next real sound")
        #expect(bindings.fed.allSatisfy { frame in frame.allSatisfy { $0.isFinite && abs($0) < 16 } }, "nothing but audio was ever fed")
    }

    @Test func aBadFrameInAQuietRoomIsDroppedWithoutOpeningTheGateOrJoiningTheLeadIn() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate)
        try await engine.initialize()
        for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        #expect(try engine.processAudio(Fixture.frame(amplitude: .nan)) == nil)
        #expect(bindings.fed.isEmpty, "a bad frame does not open the gate")
        for _ in 0..<3 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud))
        #expect(bindings.fed.count == 4, "the quiet moments before the bad frame are not trusted as lead-in; the three after it and the loud one are: \(bindings.fed.count)")
    }

    /// Without a gate (tools that evaluate the model) the stream is likewise restarted after a bad frame.
    @Test func withoutAGateABadFrameAlsoRestartsTheStream() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: nil)
        try await engine.initialize()
        _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud))
        _ = try engine.processAudio(Fixture.frame(amplitude: .infinity))
        #expect(bindings.fed.count == 1 && bindings.resets == 1)
    }

    @Test func aDetectionInsideTheLeadInIsNotLost() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        bindings.hear(onFeed: [3])   // one of the lead-in frames completes the word
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate)
        try await engine.initialize()
        for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        #expect(try engine.processAudio(Fixture.frame(amplitude: Fixture.loud)) != nil)
    }

    @Test func theModelKeepsListeningThroughTheHangoverThenRestsAgain() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        var configuration = Self.gate
        configuration.hangoverFrames = 5
        let engine = Fixture.engine(bindings, model: model.files, gate: configuration)
        try await engine.initialize()
        for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.loud))
        let fedAfterSpeech = bindings.fed.count
        for _ in 0..<5 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        #expect(bindings.fed.count == fedAfterSpeech + 5, "the end of the word, and what follows it, still reach the model")
        for _ in 0..<20 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        #expect(bindings.fed.count == fedAfterSpeech + 5, "…and then it rests again")
    }

    @Test func withoutAGateEveryFrameIsHeard() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: nil)
        try await engine.initialize()
        for _ in 0..<50 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        #expect(bindings.fed.count == 50 && bindings.resets == 0)
    }
}

// MARK: - Level normalisation

struct LevelNormaliserTests {
    static func decibels(_ gain: Float) -> Float { 20 * log10(gain) }

    @Test func aQuietBurstIsBroughtUpToTheTargetPeak() {
        var normaliser = LevelNormaliser(.init())            // target −6 dBFS
        let gain = normaliser.begin(peak: 0.03)              // −30.5 dBFS
        #expect(abs(0.03 * gain - powf(10, -6 / 20)) < 1e-5, "the peak lands on the target: \(0.03 * gain)")
        #expect(abs(Self.decibels(gain) - 24.46) < 0.05)
    }

    @Test func aFaintSoundIsNotBlownUpIntoNoise() {
        var normaliser = LevelNormaliser(.init())
        let gain = normaliser.begin(peak: 0.0001)
        #expect(abs(Self.decibels(gain) - 30) < 0.01, "at most +30 dB, not +70")
    }

    @Test func loudSpeechIsLeftAlone() {
        var normaliser = LevelNormaliser(.init())
        #expect(normaliser.begin(peak: 0.9) == 1 && normaliser.begin(peak: 0.6) == 1, "already above −6 dBFS: untouched")
    }

    @Test func louderSpeechLowersTheGainAtOnceForTheWholeFrame() {
        var normaliser = LevelNormaliser(.init())
        let first = normaliser.begin(peak: 0.01)
        let (from, to) = normaliser.advance(peak: 0.2)
        #expect(to < first && from == to, "an instant drop, with no ramp from the old gain: \(from) → \(to)")
        #expect(abs(0.2 * to - powf(10, -6 / 20)) < 1e-4)
    }

    @Test func quieterSpeechRaisesTheGainOnlyGradually() {
        var normaliser = LevelNormaliser(.init())
        _ = normaliser.begin(peak: 0.3)                      // gain ≈ 1.05
        var gains: [Float] = []
        for _ in 0..<5 {
            let (from, to) = normaliser.advance(peak: 0.01)  // the word trails off
            #expect(to >= from)
            gains.append(to)
        }
        #expect(gains == gains.sorted() && gains.last! < 3, "slowly: \(gains)")
        let wanted = powf(10, -6 / 20) / (0.3 * powf(0.5, 5 / 30))
        #expect(gains.last! < wanted * 1.01, "never past what the remembered peak asks for")
    }

    @Test func noFrameIsMadeLouderThanTheTarget_andTheGainTheSpeechAfterItNeedsIsKept() {
        var normaliser = LevelNormaliser(.init())
        // A click (peak 0.316, which counts for 0.1) opens a stretch: the speech around it will need +14 dB, the click itself only +4.
        let opening = normaliser.begin(level: 0.1, peak: 0.316)
        #expect(abs(0.316 * opening - powf(10, -6 / 20)) < 1e-4, "the click lands on the target, not above it: \(0.316 * opening)")
        #expect(normaliser.gain > 4.5, "while what the envelope asks for is still the speech's gain: \(normaliser.gain)")
        // Quiet frames follow; then a word at 0.08.
        let (from, to) = normaliser.advance(level: 0.0005, peak: 0.0005)
        #expect(from == opening && to > from, "the gain goes up in the quiet, ramped across the frame: \(from) → \(to)")
        let (wordFrom, wordTo) = normaliser.advance(level: 0.08, peak: 0.08)
        #expect(wordTo >= wordFrom && abs(0.08 * wordTo - powf(10, -6 / 20)) < 0.1, "the word is brought close to the target: \(0.08 * wordTo)")
    }

    @Test func aPeakyFrameIsNotBlownUpEvenInsideLoudSpeechsGain() {
        var normaliser = LevelNormaliser(.init())
        _ = normaliser.begin(peak: 0.05)                                        // gain 10 for speech
        let (_, to) = normaliser.advance(level: 0.05, peak: 0.4)                // a frame whose peak (not its RMS-based level) is much higher
        #expect(0.4 * to <= powf(10, -6 / 20) + 1e-4, "that frame is held at the target: \(0.4 * to)")
    }

    @Test func numbersThatAreNotPeaksAreIgnored() {
        var normaliser = LevelNormaliser(.init())
        _ = normaliser.begin(peak: 0.05)
        let before = normaliser.gain
        _ = normaliser.advance(peak: .nan)
        _ = normaliser.advance(peak: -3)
        #expect(normaliser.gain.isFinite && normaliser.gain >= before)
        var fresh = LevelNormaliser(.init())
        #expect(fresh.begin(peak: .nan) == 1 && fresh.begin(peak: .infinity) == 1)
    }

    @Test func aClickCountsForLessThanItsPeak() {
        let normaliser = LevelNormaliser(.init())
        // 12 ms of click at −10 dBFS inside a 100 ms frame: a peak of 0.316 with an RMS of about 0.02 (a crest of 15).
        #expect(abs(normaliser.level(peak: 0.316, rms: 0.0204) - 4 * 0.0204) < 1e-6, "no more than four times the RMS")
        // Speech: a crest of about 3 counts for what it is.
        #expect(normaliser.level(peak: 0.3, rms: 0.1) == 0.3)
        #expect(normaliser.level(peak: .nan, rms: 0.1) == 0 && normaliser.level(peak: 0.3, rms: .infinity) == 0 && normaliser.level(peak: -1, rms: 0.1) == 0)
        var open = LevelNormaliser.Configuration()
        open.crestLimit = 1_000
        #expect(LevelNormaliser(open).level(peak: 0.316, rms: 0.0204) == 0.316, "with a limit nobody reaches, the peak is the peak")
    }

    @Test func nonsenseSettingsAreClamped() {
        var configuration = LevelNormaliser.Configuration()
        configuration.targetPeakDecibels = .nan
        configuration.maximumGainDecibels = 500
        configuration.maximumAttenuationDecibels = -4
        configuration.releaseHalfLifeFrames = 0
        configuration.riseFraction = 9
        configuration.crestLimit = .infinity
        let sane = LevelNormaliser(configuration).configuration
        #expect(sane.crestLimit == LevelNormaliser.Configuration().crestLimit)
        #expect(sane.targetPeakDecibels == -6 && sane.maximumGainDecibels == 60 && sane.maximumAttenuationDecibels == 0)
        #expect(sane.releaseHalfLifeFrames == 1 && sane.riseFraction == 1)
        configuration.targetPeakDecibels = 12
        #expect(LevelNormaliser(configuration).configuration.targetPeakDecibels == 0)
    }

    @Test func attenuationIsOnlyAppliedWhenAskedFor() {
        var configuration = LevelNormaliser.Configuration()
        configuration.maximumAttenuationDecibels = 6
        var normaliser = LevelNormaliser(configuration)
        let gain = normaliser.begin(peak: 1.0)
        #expect(abs(Self.decibels(gain) - -6) < 0.01, "−6 dBFS asked of a full-scale peak: exactly the −6 dB allowed: \(Self.decibels(gain))")
    }
}

struct SherpaLevelNormalisationTests {
    static let gate = ActivityGate.Configuration()

    @Test func quietSpeechReachesTheModelAtTheTargetLevel_andSoDoesItsLeadIn() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate, normaliser: .init())
        try await engine.initialize()
        for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.02))   // speech at arm's length: −34 dBFS
        let gain = powf(10, -6 / 20) / 0.02
        #expect(bindings.fed.count == 7)
        #expect(abs((bindings.fed.last?[0] ?? 0) - 0.02 * gain) < 1e-4, "the speech frame lands on the target peak")
        for earlier in bindings.fed.dropLast() {
            #expect(abs(earlier[0] - Fixture.quiet * gain) < 1e-4, "the lead-in has the same gain as the speech after it: \(earlier[0])")
        }
    }

    @Test(arguments: [false, true])
    func aClickJustBeforeTheWordDoesNotHoldTheGainDown(whileAStretchIsAlreadyRunning: Bool) async throws {
        func fedWord(_ configuration: LevelNormaliser.Configuration) async throws -> (word: Float, loudest: Float) {
            let model = try Fixture.model(); defer { model.cleanup() }
            let bindings = FakeSherpa()
            let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate, normaliser: configuration)
            try await engine.initialize()
            for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
            // Either the click itself opens the stretch of sound, or something quieter has (a breath, a word) and the click comes inside it.
            if whileAStretchIsAlreadyRunning { _ = try engine.processAudio(Fixture.frame(amplitude: 0.02)) }
            // A key struck: 12 ms of loud buzz in an otherwise quiet 100 ms frame — a high peak, little energy (a crest of about 11).
            var click = [Float](repeating: Fixture.quiet, count: 1_600)
            for index in 0..<192 { click[index] = 0.5 * expf(-Float(index) / 25) * (index % 2 == 0 ? 1 : -1) }
            _ = try engine.processAudio(AudioFrame(samples: click, sampleRate: 16_000, sequence: 0, captureTime: .zero))
            for _ in 0..<4 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }   // half a second later…
            _ = try engine.processAudio(Fixture.frame(amplitude: 0.02))                               // …the word, at arm's length
            return (bindings.fed.last?[0] ?? 0, bindings.fed.map { $0.map(abs).max() ?? 0 }.max() ?? 0)
        }
        var unlimited = LevelNormaliser.Configuration()
        unlimited.crestLimit = 1_000
        let limited = try await fedWord(.init()), plain = try await fedWord(unlimited)
        #expect(limited.word > plain.word * 1.5, "the word reaches the model at \(limited.word), not at \(plain.word), after a click")
        #expect(limited.loudest <= powf(10, -6 / 20) + 1e-3, "and nothing is blown up past the target: \(limited.loudest)")
    }

    @Test func theGainFollowsTheSpeechWithinAStretchAndStartsAgainWithTheNext() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        var gate = Self.gate
        gate.hangoverFrames = 2
        let engine = Fixture.engine(bindings, model: model.files, gate: gate, normaliser: .init())
        try await engine.initialize()
        for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.02))
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.2))     // the speaker gets louder
        #expect(abs((bindings.fed.last?[0] ?? 0) - powf(10, -6 / 20)) < 1e-3, "louder speech is brought down to the target at once")
        for _ in 0..<40 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }   // the stretch ends
        let before = bindings.fed.count
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.005))   // a much fainter voice, later
        let next = Array(bindings.fed[before...])
        // 0.005 wants +34 dB, but +30 dB is the most it gets: 0.005 × 31.62. (Starting from the loud stretch's gain it would be 0.005 × 1.58.)
        #expect(abs((next.last?[0] ?? 0) - 0.005 * powf(10, 30 / 20)) < 1e-3, "a new stretch starts from its own gain, not the loud one's: \(next.last?[0] ?? 0)")
    }

    @Test func loudSpeechAndRoomsWithoutANormaliserAreFedAsTheyCome() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let loud = FakeSherpa()
        let withNormaliser = Fixture.engine(loud, model: model.files, gate: Self.gate, normaliser: .init())
        try await withNormaliser.initialize()
        for _ in 0..<30 { _ = try withNormaliser.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        _ = try withNormaliser.processAudio(Fixture.frame(amplitude: 0.6))
        #expect(loud.fed.last == [Float](repeating: 0.6, count: 1_600), "already above the target: untouched")

        let plain = FakeSherpa()
        let without = Fixture.engine(plain, model: model.files, gate: Self.gate, normaliser: nil)
        try await without.initialize()
        for _ in 0..<30 { _ = try without.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        _ = try without.processAudio(Fixture.frame(amplitude: 0.02))
        #expect(plain.fed.last == [Float](repeating: 0.02, count: 1_600), "no normaliser: the audio as it is")
    }

    @Test func theResultNeverLeavesTheRangeTheModelExpects() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate, normaliser: .init())
        try await engine.initialize()
        for _ in 0..<30 { _ = try engine.processAudio(Fixture.frame(amplitude: Fixture.quiet)) }
        for amplitude in [Float(0.004), 0.9, 0.003, 12, 0.0045, 0.9] { _ = try engine.processAudio(Fixture.frame(amplitude: amplitude)) }
        #expect(bindings.fed.allSatisfy { frame in frame.allSatisfy { abs($0) <= 1 } }, "nothing is pushed past full scale")
    }

    @Test func withoutAGateTheFirstFrameBeginsAndTheRestFollow() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: nil, normaliser: .init())
        try await engine.initialize()
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.02))
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.02))
        #expect(bindings.fed.count == 2)
        #expect(abs(bindings.fed[0][0] - powf(10, -6 / 20)) < 1e-3 && abs(bindings.fed[1][0] - powf(10, -6 / 20)) < 1e-2)
    }

    @Test func aBadFrameEndsTheStretch() async throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let bindings = FakeSherpa()
        let engine = Fixture.engine(bindings, model: model.files, gate: Self.gate, normaliser: .init())
        try await engine.initialize()
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.3))
        _ = try engine.processAudio(Fixture.frame(amplitude: .nan))
        _ = try engine.processAudio(Fixture.frame(amplitude: 0.02))
        #expect(abs((bindings.fed.last?[0] ?? 0) - powf(10, -6 / 20)) < 1e-3, "the gain starts again from the next real sound, not from the 0.3 before")
    }
}

// MARK: - The gate by itself

struct ActivityGateTests {
    /// One frame at `level` dBFS; returns whether the gate is open for it. (A mutating call cannot sit inside `#expect`.)
    static func step(_ gate: inout ActivityGate, _ level: Float, times: Int = 1) -> [Bool] {
        (0..<times).map { _ in gate.update(levelDecibels: level) }
    }

    @Test func itOpensOnASoundWellAboveTheRoomAndRestsAfterTheHangover() {
        var gate = ActivityGate(.init())
        #expect(Self.step(&gate, -65, times: 50).allSatisfy { !$0 })
        #expect(gate.noiseFloorDecibels < -64 && gate.noiseFloorDecibels > -66)
        #expect(Self.step(&gate, -40) == [true], "25 dB above the floor")
        #expect(Self.step(&gate, -65, times: 15).allSatisfy { $0 }, "open through the hangover")
        #expect(Self.step(&gate, -65) == [false], "and closed after it")
    }

    @Test func aSoundJustAboveTheFloorDoesNotOpenIt() {
        var gate = ActivityGate(.init())
        _ = Self.step(&gate, -65, times: 50)
        #expect(Self.step(&gate, -60) == [false], "5 dB is breathing, not speech")
        #expect(Self.step(&gate, -56) == [true], "9 dB is")
    }

    @Test func aConversationDoesNotDragTheFloorUpAndCloseTheGateOnItself() {
        var gate = ActivityGate(.init())
        _ = Self.step(&gate, -65, times: 100)
        _ = Self.step(&gate, -30, times: 70)   // seven seconds of talking out of the last ten
        #expect(gate.noiseFloorDecibels < -60, "the floor is a low percentile of the window, not its average: \(gate.noiseFloorDecibels)")
        #expect(Self.step(&gate, -30) == [true])
    }

    @Test func aNoisyRoomKeepsItOpenSoNothingIsMissed() {
        var gate = ActivityGate(.init())
        #expect(Self.step(&gate, -35, times: 200).allSatisfy { $0 }, "above −48 dBFS is always worth a look")
    }

    @Test func aLevelThatIsNotANumberTellsTheGateNothing() {
        var gate = ActivityGate(.init())
        _ = Self.step(&gate, -65, times: 50)
        #expect(Self.step(&gate, .nan) == [false] && Self.step(&gate, .infinity) == [false] && Self.step(&gate, -.infinity) == [false])
        #expect(gate.noiseFloorDecibels < -64 && gate.noiseFloorDecibels > -66, "the floor is untouched: \(gate.noiseFloorDecibels)")
        _ = Self.step(&gate, -40)
        #expect(Self.step(&gate, .nan) == [true], "an open gate stays open through a bad level")
    }

    @Test func nonsenseSettingsAreClampedNotTrappedOn() {
        var configuration = ActivityGate.Configuration()
        configuration.floorPercentile = .nan
        configuration.floorWindowFrames = -4
        configuration.hangoverFrames = -2
        configuration.preRollFrames = -1
        var gate = ActivityGate(configuration)
        _ = Self.step(&gate, -60, times: 10)   // would trap on a NaN percentile or an empty window
        #expect(gate.configuration.floorWindowFrames == 1 && gate.configuration.hangoverFrames == 0 && gate.configuration.preRollFrames == 0)
        #expect(gate.configuration.floorPercentile == ActivityGate.Configuration().floorPercentile)
        configuration.floorPercentile = 7
        #expect(ActivityGate(configuration).configuration.floorPercentile == 1)
        configuration.floorPercentile = -1
        #expect(ActivityGate(configuration).configuration.floorPercentile == 0)
    }

    @Test func theVeryFirstFrameDoesNotOpenAQuietRoom() {
        var gate = ActivityGate(.init())
        #expect(Self.step(&gate, -70) == [false])
    }
}

// MARK: - Keyword definitions

struct SherpaKeywordDefinitionTests {
    @Test func oneEntryPerPronunciationEachWithTheSameLabelSeparatedBySlashes() {
        let text = SherpaOnnxBackend.keywordDefinition(pronunciations: ["JH AA1 R V AH0 S", "JH AA1 V IH0 S"], sensitivity: 0.5, tuning: .default)
        #expect(text == "JH AA1 R V AH0 S :1.500 #0.060 @JARVIS/JH AA1 V IH0 S :1.500 #0.060 @JARVIS")
    }

    static func file(_ content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pron-\(UUID().uuidString).txt")
        try content.write(to: url)
        return url
    }

    @Test func aUserPronunciationFileHoldsOneSequenceOfSoundsPerLineWithCommentsAndBlanksIgnored() throws {
        let url = try Self.file(Data("""
        # my accent
        HH AA1 R B IH0 S   # the "h" and the "b"

        \tY   AA1\tR B IH0 S
        """.utf8)); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SherpaOnnxBackend.parsePronunciations(from: url) == ["HH AA1 R B IH0 S", "Y AA1 R B IH0 S"], "tabs and runs of blanks between sounds are single spaces")
    }

    @Test func aFileWithABomWindowsLineEndingsAndUnicodeLineSeparatorsIsReadAsLines() throws {
        let text = "JH AA1 R V AH0 S\r\nHH AA1 R B IH0 S\u{2028}Y AA1 R B IH0 S\u{0085}JH AA1 V IH0 S\r\n"
        let url = try Self.file(Data([0xEF, 0xBB, 0xBF] + Array(text.utf8))); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SherpaOnnxBackend.parsePronunciations(from: url) == ["JH AA1 R V AH0 S", "HH AA1 R B IH0 S", "Y AA1 R B IH0 S", "JH AA1 V IH0 S"])
    }

    @Test func nothingIsQuietlyDroppedAnymore() throws {
        // Lines that carry the library's own syntax used to vanish without a word (and `:` ones did not, which was inconsistent).
        // Now every line is kept, and the vetting against the model's sounds refuses the ones that cannot be pronunciations.
        let url = try Self.file(Data("JH AA1 R V IH0 S @OTHER :9\nJH AA1 R V AH0 S/ JH AA1 R B IH0 S\nJH AA1 R V AH0 S :9\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SherpaOnnxBackend.parsePronunciations(from: url)?.count == 3)
    }

    @Test func aFileOfCommentsAloneLeavesTheBuiltInListInForce() throws {
        let url = try Self.file(Data("# nothing here yet\n\n   \n".utf8)); defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SherpaOnnxBackend.parsePronunciations(from: url) == nil)
    }

    @Test func aFileThatCannotBeUsedSaysWhyInsteadOfBeingIgnored() throws {
        func problem(_ data: Data) throws -> String? {
            let url = try Self.file(data); defer { try? FileManager.default.removeItem(at: url) }
            do throws(WakeWordError) { _ = try SherpaOnnxBackend.parsePronunciations(from: url); return nil } catch {
                if case .invalidConfiguration(let detail) = error { return detail }
                return "wrong error \(error)"
            }
        }
        #expect(try problem(Data([0xFF, 0xFE, 0x4A, 0x00]))?.contains("not UTF-8") == true, "UTF-16 or Latin-1 text")
        #expect(try problem(Data(repeating: 0x41, count: PronunciationLimits.fileBytes + 1))?.contains("larger than") == true)
        #expect(try problem(Data(repeating: 0x41, count: PronunciationLimits.fileBytes)) == nil, "a file exactly at the limit is read (and then judged by what it says)")
        // A folder where the file should be: unreadable, and said so.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pron-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try SherpaOnnxBackend.parsePronunciations(from: directory); Issue.record("a directory is not a pronunciation file") } catch {
            if case .invalidConfiguration(let detail) = error { #expect(detail.contains("cannot be read")) } else { Issue.record("wrong error \(error)") }
        }
    }

    /// Only the first `PronunciationLimits.fileBytes + 1` bytes are ever read, however big the file.
    @Test func aHugeFileIsNotReadInFull() throws {
        let url = try Self.file(Data(repeating: 0x41, count: 50 * 1_024 * 1_024)); defer { try? FileManager.default.removeItem(at: url) }
        let began = ContinuousClock.now
        do { _ = try SherpaOnnxBackend.parsePronunciations(from: url); Issue.record("expected a refusal") } catch {}
        #expect(ContinuousClock.now - began < .seconds(2))
    }

    @Test func theDefaultPronunciationsCoverTheDictionaryFormAndTheCommonAccents() {
        let defaults = SherpaOnnxBackend.phoneModel.pronunciations
        #expect(defaults.contains("JH AA1 R V AH0 S"), "the dictionary pronunciation")
        #expect(defaults.contains("JH AA1 V IH0 S"), "without the r")
        #expect(defaults.contains("JH AA1 R B IH0 S"), "b for v")
        #expect(Set(defaults).count == defaults.count)
    }
}

// MARK: - Descriptor

struct SherpaDescriptorTests {
    static func tree(library: Bool = true, models: Bool = true, custom: String? = nil, customData: Data? = nil) throws -> (EngineEnvironment, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-tree-\(UUID().uuidString)")
        let lib = root.appendingPathComponent("lib"), data = root.appendingPathComponent("data/sherpa-kws")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if library { try Data([0]).write(to: lib.appendingPathComponent("libsherpa-onnx-c-api.dylib")) }
        if models {
            let profile = SherpaOnnxBackend.phoneModel
            for name in [profile.encoder, profile.decoder, profile.joiner, profile.tokens] { try Data([0]).write(to: data.appendingPathComponent(name)) }
        }
        if let custom { try custom.write(to: root.appendingPathComponent("data/jarvis_pronunciations.txt"), atomically: true, encoding: .utf8) }
        if let customData { try customData.write(to: root.appendingPathComponent("data/jarvis_pronunciations.txt")) }
        let environment = EngineEnvironment(resources: EngineResourceLocator(
            searchDirectories: [root.appendingPathComponent("data")], libraryDirectories: [lib]
        ))
        return (environment, { try? FileManager.default.removeItem(at: root) })
    }

    @Test func itNeedsNoCredentialsAndSaysSo() {
        let descriptor = SherpaOnnxBackend.descriptor
        #expect(descriptor.id == "sherpa-onnx")
        #expect(descriptor.credentials.isEmpty, "no key, no account")
        #expect(descriptor.capabilities == .init(supportsLiveSensitivity: true, reportsConfidence: false))
        #expect(!descriptor.isDeveloperOnly)
        #expect(descriptor.summary.contains("No account"))
    }

    @Test func preflightSaysWhatIsMissingAndHowToFixIt() throws {
        let (environment, cleanup) = try Self.tree(library: false, models: false); defer { cleanup() }
        guard case .unavailable(let reason) = SherpaOnnxBackend.descriptor.preflight(environment) else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("fetch-sherpa.sh"))
    }

    @Test func aDamagedOrForeignModelIsReportedByPreflightWithoutLoadingAnything() throws {
        let (environment, cleanup) = try Self.tree(); defer { cleanup() }   // one-byte stand-ins for the model files
        guard case .unavailable(let reason) = SherpaOnnxBackend.descriptor.preflight(environment) else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("Damaged or unexpected") && reason.contains("fetch-sherpa.sh"), "got: \(reason)")
    }

    @Test func theLibraryIsOnlyEverTakenFromALibraryDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-trust-\(UUID().uuidString)")
        let data = root.appendingPathComponent("user-models")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("sherpa-kws"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A "library" dropped into the folder a user (or anything running as the user) can write to.
        try Data([0]).write(to: data.appendingPathComponent("libsherpa-onnx-c-api.dylib"))
        let profile = SherpaOnnxBackend.phoneModel
        for name in [profile.encoder, profile.decoder, profile.joiner, profile.tokens] { try Data([0]).write(to: data.appendingPathComponent("sherpa-kws/\(name)")) }
        let environment = EngineEnvironment(resources: EngineResourceLocator(searchDirectories: [data], libraryDirectories: []))
        #expect(SherpaOnnxBackend.locateFiles(in: environment) == nil, "data directories never provide code")
    }

    @Test func onlyTheJarvisKeywordIsSupported() throws {
        let (environment, cleanup) = try Self.tree(); defer { cleanup() }
        var other = environment
        other.keywords = [WakeKeyword(id: "computer", displayName: "Computer")]
        do {
            _ = try SherpaOnnxBackend.descriptor.makeEngine(other)
            Issue.record("expected failure")
        } catch {
            if case .invalidConfiguration = error {} else { Issue.record("wrong error \(error)") }
        }
    }

    @Test func aMissingInstallationIsAnInstallProblemNotACrash() throws {
        let (environment, cleanup) = try Self.tree(models: false); defer { cleanup() }
        do {
            _ = try SherpaOnnxBackend.descriptor.makeEngine(environment)
            Issue.record("expected failure")
        } catch {
            #expect(error.recovery == .needsUserAction(.installEngineFiles))
        }
    }

    @Test func aPronunciationFileFromTheUserReplacesTheBuiltInOnes() throws {
        let (environment, cleanup) = try Self.tree(custom: "HH AA1 R B IH0 S\n"); defer { cleanup() }
        #expect(try SherpaOnnxBackend.locateFiles(in: environment)?.pronunciations.get() == ["HH AA1 R B IH0 S"])
        let (plain, cleanupPlain) = try Self.tree(); defer { cleanupPlain() }
        #expect(try SherpaOnnxBackend.locateFiles(in: plain)?.pronunciations.get() == SherpaOnnxBackend.phoneModel.pronunciations)
    }

    /// What `makeEngine` hands the engine is what the user and the shipped constants say — not merely *an* engine.
    @Test func theEngineTheDescriptorBuildsCarriesTheShippedChecksTheUsersSensitivityAndTheirPronunciations() throws {
        let (base, cleanup) = try Self.tree(custom: "HH AA1 R B IH0 S\n"); defer { cleanup() }
        var environment = base
        environment.sensitivity = 0.8
        let engine = try #require(try SherpaOnnxBackend.descriptor.makeEngine(environment) as? SherpaOnnxWakeWordEngine)
        #expect(engine.configuration.integrity == .verified(try #require(SherpaOnnxBackend.phoneModel.digests)), "the shipped digests are enforced")
        #expect(engine.configuration.sensitivity == 0.8)
        #expect(engine.configuration.pronunciations == ["HH AA1 R B IH0 S"])
        #expect(engine.configuration.tuning == KeywordTuning.default)
        #expect(engine.configuration.maxActivePaths == SherpaOnnxBackend.defaultMaxActivePaths)
        #expect(engine.configuration.activityGate != nil, "the quiet-room gate is on")
        #expect(engine.configuration.levelNormaliser == LevelNormaliser.Configuration(), "the level stage is on, with its shipped settings")
        #expect(engine.configuration.libraryURL.lastPathComponent == "libsherpa-onnx-c-api.dylib")
    }

    /// `preflight` is for the UI; the runtime builds the engine directly. So the engine's own `initialize()` is what stops a
    /// damaged installation, and this proves it does — even with a library file that is not a library.
    @Test func aDamagedInstallationIsRefusedWhenTheEngineStartsBeforeAnythingIsLoaded() async throws {
        let (environment, cleanup) = try Self.tree(); defer { cleanup() }   // one-byte stand-ins for every file
        let engine = try SherpaOnnxBackend.descriptor.makeEngine(environment)
        do {
            try await engine.initialize()
            Issue.record("a damaged installation must not start")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("damaged or unexpected model file(s)"), "got: \(detail)")
            #expect(error.recovery == .needsUserAction(.installEngineFiles))
        }
    }

    @Test(arguments: [
        ("not text", Data([0xFF, 0xFE, 0x4A, 0x00]), "not UTF-8"),
        ("too big", Data(repeating: 0x41, count: PronunciationLimits.fileBytes + 1), "larger than"),
    ])
    func aPronunciationFileThatCannotBeUsedMakesTheEngineUnavailableWithTheReason(_ name: String, _ data: Data, _ expected: String) throws {
        let (environment, cleanup) = try Self.tree(customData: data); defer { cleanup() }
        // (The model files here are stand-ins, so the digest check would also object; the file problem is reported first.)
        guard case .unavailable(let reason) = SherpaOnnxBackend.descriptor.preflight(environment) else { Issue.record("\(name): expected unavailable"); return }
        #expect(reason.contains("jarvis_pronunciations.txt") && reason.contains(expected) && reason.contains("Fix or delete"), "\(name): \(reason)")
        do {
            _ = try SherpaOnnxBackend.descriptor.makeEngine(environment)
            Issue.record("\(name): the engine must not be built from a file that cannot be used")
        } catch {
            if case .invalidConfiguration = error {} else { Issue.record("\(name): wrong error \(error)") }
        }
    }
}
