import Foundation
import Testing
import WakeWordKit
@testable import PorcupineBackend

// MARK: - Fake native layer

/// Stands in for libpv_porcupine so the engine's own logic — frame conversion, keyword mapping,
/// error translation, handle ownership — is verified without an AccessKey or the real library.
final class FakeBindings: PorcupineBindings, @unchecked Sendable {
    struct CreateCall: Equatable {
        var accessKey: String, modelPath: String, device: String, keywordPaths: [String], sensitivities: [Float]
    }
    private struct State {
        var creates: [CreateCall] = []
        var processed: [[Int16]] = []
        var destroyed: [UInt] = []
        var indices: [Int32] = []
        var nextHandle: UInt = 0x1000
    }
    private let state = Protected(State())
    let version = "fake"
    let sampleRate: Int
    let frameLength: Int
    var failOnCreate: NativeFailure?
    var failOnProcess: NativeFailure?
    /// When set, `makeHandle` blocks until the semaphore is signalled (to test races with shutdown).
    var createGate: DispatchSemaphore?

    init(sampleRate: Int = 16_000, frameLength: Int = 512) {
        self.sampleRate = sampleRate
        self.frameLength = frameLength
    }

    var creates: [CreateCall] { state.withLock { $0.creates } }
    var processed: [[Int16]] { state.withLock { $0.processed } }
    var destroyed: [UInt] { state.withLock { $0.destroyed } }
    func script(_ indices: [Int32]) { state.withLock { $0.indices = indices } }

    func makeHandle(accessKey: String, modelPath: String, device: String, keywordPaths: [String], sensitivities: [Float]) throws(NativeFailure) -> OpaquePointer {
        createGate?.wait()
        if let failOnCreate { throw failOnCreate }
        return state.withLock { state in
            state.creates.append(.init(accessKey: accessKey, modelPath: modelPath, device: device, keywordPaths: keywordPaths, sensitivities: sensitivities))
            state.nextHandle += 0x10
            return OpaquePointer(bitPattern: state.nextHandle)!
        }
    }

    func process(handle: OpaquePointer, pcm: UnsafePointer<Int16>) throws(NativeFailure) -> Int32 {
        if let failOnProcess { throw failOnProcess }
        let copy = Array(UnsafeBufferPointer(start: pcm, count: frameLength))
        return state.withLock { state in
            state.processed.append(copy)
            return state.indices.isEmpty ? -1 : state.indices.removeFirst()
        }
    }

    func destroy(handle: OpaquePointer) {
        state.withLock { $0.destroyed.append(UInt(bitPattern: handle)) }
    }
}

enum Fixture {
    static let secret = "FAKE-ACCESS-KEY-0123456789abcdef=="

    /// Real files on disk so the engine's existence checks pass.
    static func files() throws -> (model: URL, keyword: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porcupine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = directory.appendingPathComponent("porcupine_params.pv")
        let keyword = directory.appendingPathComponent("jarvis_mac.ppn")
        try Data([0]).write(to: model)
        try Data([0]).write(to: keyword)
        return (model, keyword, { try? FileManager.default.removeItem(at: directory) })
    }

    static func engine(
        bindings: FakeBindings,
        model: URL, keyword: URL,
        accessKey: String = Fixture.secret,
        sensitivity: Float = 0.5
    ) -> PorcupineWakeWordEngine {
        PorcupineWakeWordEngine(
            configuration: .init(
                accessKey: accessKey,
                libraryURL: URL(fileURLWithPath: "/nonexistent/libpv_porcupine.dylib"),
                modelURL: model,
                keywords: [(.jarvis, keyword)],
                sensitivity: sensitivity
            ),
            makeBindings: { bindings }
        )
    }

    static func frame(_ samples: [Float]? = nil, count: Int = 512, rate: Int = 16_000) -> AudioFrame {
        AudioFrame(samples: samples ?? [Float](repeating: 0, count: count), sampleRate: rate, sequence: 0, captureTime: .zero)
    }
}

// MARK: - Engine behaviour

struct PorcupineEngineLogicTests {
    @Test func initializationPassesTheConfigurationToTheNativeLibrary() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword, sensitivity: 0.7)
        try await engine.initialize()

        #expect(bindings.creates == [.init(
            accessKey: Fixture.secret, modelPath: files.model.path, device: "cpu:1",
            keywordPaths: [files.keyword.path], sensitivities: [0.7]
        )])
        #expect(engine.audioRequirements == AudioRequirements(sampleRate: 16_000, frameLength: 512))
        #expect(engine.identifier == "porcupine")
    }

    @Test func requirementsComeFromTheLibraryNotFromHardcodedConstants() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let engine = Fixture.engine(bindings: FakeBindings(sampleRate: 8_000, frameLength: 256), model: files.model, keyword: files.keyword)
        try await engine.initialize()
        #expect(engine.audioRequirements == AudioRequirements(sampleRate: 8_000, frameLength: 256))
    }

    @Test func theNativeLibraryIsResolvedOnceNotOnEveryFrame() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let resolutions = Protected(0)
        let engine = PorcupineWakeWordEngine(
            configuration: .init(
                accessKey: Fixture.secret, libraryURL: URL(fileURLWithPath: "/nonexistent/libpv_porcupine.dylib"),
                modelURL: files.model, keywords: [(.jarvis, files.keyword)]
            ),
            makeBindings: { resolutions.withLock { $0 += 1 }; return bindings }
        )
        try await engine.initialize()
        for _ in 0..<200 { _ = try engine.processAudio(Fixture.frame()) }
        engine.shutdown()
        #expect(resolutions.get() == 1, "symbol lookup is an initialisation cost, never a per-frame one")
        #expect(bindings.processed.count == 200)
        #expect(bindings.destroyed.count == 1)
    }

    @Test func aLibraryThatDisappearsMidRunDoesNotBreakAnEngineThatIsAlreadyListening() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let available = Protected(true)
        let engine = PorcupineWakeWordEngine(
            configuration: .init(
                accessKey: Fixture.secret, libraryURL: URL(fileURLWithPath: "/nonexistent/libpv_porcupine.dylib"),
                modelURL: files.model, keywords: [(.jarvis, files.keyword)]
            ),
            makeBindings: { () throws(WakeWordError) -> any PorcupineBindings in
                guard available.get() else { throw .engineUnavailable("the library vanished") }
                return bindings
            }
        )
        try await engine.initialize()
        available.withLock { $0 = false }   // an update replaces the app's files while it listens
        _ = try engine.processAudio(Fixture.frame())
        engine.shutdown()
        #expect(bindings.destroyed.count == 1, "the handle is still released with the bindings it was created with")
    }

    @Test func initializingTwiceDoesNotCreateASecondNativeInstance() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword)
        try await engine.initialize()
        try await engine.initialize()
        #expect(bindings.creates.count == 1)
    }

    @Test func framesAreConvertedToSixteenBitPCMAndKeywordIndicesMapToKeywords() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        bindings.script([-1, 0, -1])
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword)
        try await engine.initialize()

        var ramp = [Float](repeating: 0, count: 512)
        ramp[0] = 0.5; ramp[1] = -0.5; ramp[2] = 1.0; ramp[3] = -1.0; ramp[4] = 3.0
        #expect(try engine.processAudio(Fixture.frame(ramp)) == nil)
        let result = try engine.processAudio(Fixture.frame())
        #expect(result == DetectionResult(keyword: .jarvis, confidence: nil))
        #expect(try engine.processAudio(Fixture.frame()) == nil)

        #expect(Array(bindings.processed[0].prefix(5)) == [16384, -16384, 32767, -32768, 32767])
        #expect(bindings.processed.count == 3)
    }

    @Test func framesThatDoNotMatchTheLibrariesRequirementsAreRejectedBeforeReachingIt() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword)
        try await engine.initialize()
        #expect(throws: WakeWordError.invalidFrame(expected: 512, actual: 100)) { try engine.processAudio(Fixture.frame(count: 100)) }
        #expect(throws: WakeWordError.self) { try engine.processAudio(Fixture.frame(rate: 48_000)) }
        #expect(bindings.processed.isEmpty)
    }

    @Test func lifecycleIsEnforced() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword)
        #expect(throws: WakeWordError.notInitialized) { try engine.processAudio(Fixture.frame()) }

        try await engine.initialize()
        engine.shutdown()
        engine.shutdown() // idempotent
        #expect(bindings.destroyed.count == 1, "the native handle must be released exactly once")
        #expect(throws: WakeWordError.shutDown) { try engine.processAudio(Fixture.frame()) }
        await #expect(throws: WakeWordError.shutDown) { try await engine.initialize() }
    }

    @Test func shutdownBeforeInitializationNeverTouchesTheNativeLibrary() {
        let bindings = FakeBindings()
        let engine = Fixture.engine(bindings: bindings, model: URL(fileURLWithPath: "/x"), keyword: URL(fileURLWithPath: "/y"))
        engine.shutdown()
        #expect(bindings.destroyed.isEmpty)
        #expect(bindings.creates.isEmpty)
    }

    @Test func aShutdownDuringSlowInitializationReleasesTheNewlyCreatedHandle() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let gate = DispatchSemaphore(value: 0)
        bindings.createGate = gate
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword)

        let initialisation = Task { () -> WakeWordError? in
            do throws(WakeWordError) { try await engine.initialize(); return nil } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(100)) // let the native call start and block
        engine.shutdown()
        gate.signal()

        #expect(await initialisation.value == .shutDown)
        #expect(bindings.destroyed.count == 1, "the handle created after shutdown must not leak")
    }

    @Test func sensitivityChangesAskForANewEngineBecausePorcupineFixesThemAtConstruction() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let engine = Fixture.engine(bindings: FakeBindings(), model: files.model, keyword: files.keyword)
        try await engine.initialize()
        #expect(throws: WakeWordError.requiresReinitialization) { try engine.updateSensitivity(0.9) }
        #expect(throws: WakeWordError.self) { try engine.updateSensitivity(2) }
    }

    @Test func sensitivityOutsideTheValidRangeIsClampedAtConstruction() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        try await Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword, sensitivity: 4).initialize()
        #expect(bindings.creates.first?.sensitivities == [1])
    }

    // MARK: failures

    @Test func aMissingAccessKeyFailsBeforeAnyNativeCall() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword, accessKey: "")
        await #expect(throws: WakeWordError.credentialMissing(PorcupineBackend.accessKeyCredential)) { try await engine.initialize() }
        #expect(bindings.creates.isEmpty)
    }

    @Test func missingModelFilesAreReportedAsAnInstallProblem() async {
        let engine = Fixture.engine(
            bindings: FakeBindings(), model: URL(fileURLWithPath: "/nope/model.pv"), keyword: URL(fileURLWithPath: "/nope/jarvis.ppn")
        )
        do {
            try await engine.initialize()
            Issue.record("expected failure")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("model.pv") && detail.contains("jarvis.ppn"))
            #expect(error.recovery == .needsUserAction(.installEngineFiles))
        }
    }

    @Test func nativeInitialisationFailuresAreTranslatedAndNeverLeakTheKey() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let key = PorcupineBackend.accessKeyCredential

        func failure(_ status: PorcupineStatus, _ messages: [String]) -> NativeFailure {
            NativeFailure(status: status, statusName: "PV_STATUS_TEST", messages: messages)
        }
        let cases: [(NativeFailure, (WakeWordError) -> Bool)] = [
            (failure(.invalidArgument, ["AccessKey is invalid."]), { if case .credentialRejected(let rejected, _) = $0 { rejected == key } else { false } }),
            (failure(.invalidArgument, ["keyword file has incorrect format"]), { if case .invalidConfiguration = $0 { true } else { false } }),
            (failure(.activationError, ["License is expired."]), { if case .credentialRejected = $0 { true } else { false } }),
            (failure(.keyError, ["AccessKey was revoked"]), { if case .credentialRejected = $0 { true } else { false } }),
            (failure(.activationRefused, ["refused"]), { if case .credentialRejected = $0 { true } else { false } }),
            // No verdict at all: offline looks exactly like this, so it must not be called a bad key.
            (failure(.activationError, ["activation failed"]), { if case .licenceCheckFailed = $0 { true } else { false } }),
            (failure(.keyError, []), { if case .licenceCheckFailed = $0 { true } else { false } }),
            (failure(.activationLimitReached, ["AccessKey \(Fixture.secret) has reached it's temporary device limit"]), { if case .licenceLimit = $0 { true } else { false } }),
            (failure(.activationThrottled, ["throttled"]), { if case .licenceLimit = $0 { true } else { false } }),
            (failure(.ioError, ["could not resolve host"]), { if case .networkUnavailable = $0 { true } else { false } }),
            (failure(.activationError, ["connect failed: network is unreachable"]), { if case .networkUnavailable = $0 { true } else { false } }),
            (failure(.ioError, ["cannot read model file"]), { if case .engineUnavailable = $0 { true } else { false } }),
            (failure(.outOfMemory, []), { if case .internalFailure = $0 { true } else { false } }),
            (failure(.runtimeError, ["boom"]), { if case .internalFailure = $0 { true } else { false } }),
        ]
        for (native, expectation) in cases {
            let bindings = FakeBindings()
            bindings.failOnCreate = native
            let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword)
            do {
                try await engine.initialize()
                Issue.record("expected \(native.status) to fail")
            } catch {
                #expect(expectation(error), "\(native.status) \(native.messages) mapped to \(error)")
                #expect(!(error.errorDescription ?? "").contains(Fixture.secret), "the key leaked into: \(error)")
                #expect(!"\(error)".contains(Fixture.secret), "the key leaked into: \(error)")
            }
            // A failed initialisation leaves the engine unusable, not half-alive.
            #expect(throws: WakeWordError.notInitialized) { try engine.processAudio(Fixture.frame()) }
        }
    }

    @Test func licenceAndNetworkFailuresCarryTheRightRecovery() {
        let key = PorcupineBackend.accessKeyCredential
        let network = PorcupineErrorMapping.map(.init(status: .ioError, statusName: "IO", messages: ["network unreachable"]), credential: key, secrets: [])
        #expect(network.recovery == .retryAutomatically)
        let limit = PorcupineErrorMapping.map(.init(status: .activationLimitReached, statusName: "LIMIT", messages: []), credential: key, secrets: [])
        #expect(limit.recovery == .needsUserAction(.reviewLicence))
        let rejected = PorcupineErrorMapping.map(.init(status: .activationError, statusName: "ACT", messages: ["License is expired."]), credential: key, secrets: [])
        #expect(rejected.recovery == .needsUserAction(.provideCredential(key)))
        let unanswered = PorcupineErrorMapping.map(.init(status: .activationError, statusName: "ACT", messages: []), credential: key, secrets: [])
        #expect(unanswered == .licenceCheckFailed(key, detail: "ACT"), "the runtime decides, from connectivity, whether this is the network")
        #expect(unanswered.recovery == .manualRetryOnly, "…and online it is surfaced with Try Again: the key may be fine")
    }

    @Test func theKeyIsNeverPartOfALicenceCheckMessage() {
        let key = PorcupineBackend.accessKeyCredential
        let mapped = PorcupineErrorMapping.map(
            .init(status: .activationError, statusName: "ACT", messages: ["activation for \(Fixture.secret) failed"]),
            credential: key, secrets: [Fixture.secret]
        )
        guard case .licenceCheckFailed(_, let detail) = mapped else { Issue.record("wrong error \(mapped)"); return }
        #expect(!detail.contains(Fixture.secret))
        #expect(!(mapped.localizedDescription).contains(Fixture.secret))
    }

    @Test func processingFailuresAreReportedWithoutTheKey() async throws {
        let files = try Fixture.files(); defer { files.cleanup() }
        let bindings = FakeBindings()
        let engine = Fixture.engine(bindings: bindings, model: files.model, keyword: files.keyword)
        try await engine.initialize()
        bindings.failOnProcess = NativeFailure(status: .runtimeError, statusName: "RUNTIME", messages: ["bad state \(Fixture.secret)"])
        do {
            _ = try engine.processAudio(Fixture.frame())
            Issue.record("expected failure")
        } catch {
            guard case .processingFailed(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(!detail.contains(Fixture.secret))
            #expect(detail.contains("RUNTIME"))
        }
    }
}

// MARK: - Descriptor

enum EnvironmentFixture {
    static func with(search: [URL], libraries: [URL]) -> EngineEnvironment {
        EngineEnvironment(resources: EngineResourceLocator(searchDirectories: search, libraryDirectories: libraries))
    }
}

struct PorcupineDescriptorTests {
    static func environment(searching directories: [URL] = [], key: String? = nil, keywords: [WakeKeyword] = [.jarvis]) -> EngineEnvironment {
        let credentials = InMemoryCredentialStore()
        if let key { try? credentials.setSecret(key, for: PorcupineBackend.accessKeyCredential) }
        return EngineEnvironment(keywords: keywords, credentials: credentials, resources: EngineResourceLocator(searchDirectories: directories))
    }

    @Test func advertisesItselfAsAnAccessKeyEngineWithoutLiveSensitivity() {
        let descriptor = PorcupineBackend.descriptor
        #expect(descriptor.id == "porcupine")
        #expect(descriptor.credentials.map(\.key) == [PorcupineBackend.accessKeyCredential])
        #expect(descriptor.credentials.first?.helpURL == PorcupineBackend.consoleURL)
        #expect(descriptor.capabilities == .init(supportsLiveSensitivity: false, reportsConfidence: false))
        #expect(!descriptor.isDeveloperOnly)
    }

    @Test func preflightNamesWhateverIsMissing() {
        let result = PorcupineBackend.descriptor.preflight(Self.environment())
        guard case .unavailable(let reason) = result else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("libpv_porcupine.dylib") && reason.contains("porcupine_params.pv") && reason.contains("jarvis_mac.ppn"))
        #expect(reason.contains("fetch-porcupine.sh"))
    }

    @Test func buildingWithoutAKeyIsACredentialProblemNotACrash() {
        do {
            _ = try PorcupineBackend.descriptor.makeEngine(Self.environment())
            Issue.record("expected failure")
        } catch {
            #expect(error == .credentialMissing(PorcupineBackend.accessKeyCredential))
        }
    }

    @Test func anUnreadableKeychainIsNotReportedAsAMissingKey() {
        struct LockedStore: CredentialReading {
            func secret(for key: CredentialKey) -> String? { nil }
            func accessProblem(for key: CredentialKey) -> String? { "the Keychain is locked" }
        }
        let environment = EngineEnvironment(credentials: LockedStore())
        do {
            _ = try PorcupineBackend.descriptor.makeEngine(environment)
            Issue.record("expected failure")
        } catch {
            #expect(error == .credentialUnreadable(PorcupineBackend.accessKeyCredential, detail: "the Keychain is locked"))
        }
    }

    @Test func theNativeLibraryIsNeverTakenFromAFolderTheUserCanWriteTo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lib-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0]).write(to: directory.appendingPathComponent("libpv_porcupine.dylib"))
        try Data([0]).write(to: directory.appendingPathComponent("porcupine_params.pv"))
        try Data([0]).write(to: directory.appendingPathComponent("jarvis_mac.ppn"))

        // As the app configures it: the Models folder is data-only.
        let dataOnly = EnvironmentFixture.with(search: [directory], libraries: [])
        let located = PorcupineBackend.locateFiles(in: dataOnly)
        #expect(located.library == nil)
        #expect(located.model != nil && located.jarvis != nil, "models and keywords may still come from there")
        #expect(located.missing == ["libpv_porcupine.dylib"])
        if case .unavailable(let reason) = PorcupineBackend.descriptor.preflight(dataOnly) {
            #expect(reason.contains("libpv_porcupine.dylib"))
        } else {
            Issue.record("a library in a data folder must not make the engine available")
        }

        let trusted = EnvironmentFixture.with(search: [directory], libraries: [directory])
        #expect(PorcupineBackend.locateFiles(in: trusted).library?.lastPathComponent == "libpv_porcupine.dylib")
    }

    @Test func onlyTheJarvisKeywordIsSupported() {
        do {
            _ = try PorcupineBackend.descriptor.makeEngine(Self.environment(
                key: "k", keywords: [WakeKeyword(id: "computer", displayName: "Computer")]
            ))
            Issue.record("expected failure")
        } catch {
            if case .invalidConfiguration = error {} else { Issue.record("wrong error \(error)") }
        }
    }

    @Test func aCustomTrainedKeywordFileOverridesTheBuiltInModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("jarvis_mac.ppn"))
        #expect(PorcupineBackend.locateFiles(in: Self.environment(searching: [directory])).jarvis?.lastPathComponent == "jarvis_mac.ppn")
        try Data([2]).write(to: directory.appendingPathComponent("jarvis_custom.ppn"))
        #expect(PorcupineBackend.locateFiles(in: Self.environment(searching: [directory])).jarvis?.lastPathComponent == "jarvis_custom.ppn")
    }
}
