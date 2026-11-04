import Foundation
import Testing
@testable import WakeWordKit

/// The lifecycle contract every ``WakeWordEngine`` must honour, exercised on the mock. A new
/// engine's test suite should run the same assertions against its own type.
struct EngineLifecycleContractTests {
    static func frame(_ value: Float = 0, count: Int = 512, sequence: UInt64 = 0) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: value, count: count), sampleRate: 16_000, sequence: sequence, captureTime: .zero)
    }

    @Test func processingBeforeInitializationFails() {
        let engine = MockWakeWordEngine()
        #expect(throws: WakeWordError.notInitialized) { try engine.processAudio(Self.frame()) }
    }

    @Test func initializeThenProcessThenShutdown() async throws {
        let engine = MockWakeWordEngine()
        try await engine.initialize()
        #expect(try engine.processAudio(Self.frame()) == nil)
        engine.shutdown()
        #expect(engine.isShutDown)
        #expect(throws: WakeWordError.shutDown) { try engine.processAudio(Self.frame()) }
        #expect(engine.callLog == .init(initializeCalls: 1, processCalls: 1, shutdownCalls: 1, sensitivityUpdates: []))
    }

    @Test func shutdownIsIdempotentAndAShutDownEngineCannotBeRevived() async throws {
        let engine = MockWakeWordEngine()
        try await engine.initialize()
        engine.shutdown()
        engine.shutdown()
        await #expect(throws: WakeWordError.shutDown) { try await engine.initialize() }
    }

    @Test func initializationFailureIsReportedWithItsOwnError() async {
        var behavior = MockWakeWordEngine.Behavior()
        behavior.initializeError = .credentialMissing(CredentialKey(engineID: "mock", name: "token"))
        let engine = MockWakeWordEngine(behavior: behavior)
        await #expect(throws: WakeWordError.credentialMissing(CredentialKey(engineID: "mock", name: "token"))) {
            try await engine.initialize()
        }
        #expect(throws: WakeWordError.notInitialized) { try engine.processAudio(Self.frame()) }
    }

    @Test func wrongSizedFramesAreRejectedNotSilentlyAccepted() async throws {
        let engine = MockWakeWordEngine()
        try await engine.initialize()
        #expect(throws: WakeWordError.invalidFrame(expected: 512, actual: 100)) {
            try engine.processAudio(Self.frame(count: 100))
        }
    }

    @Test func sensitivityIsAppliedLiveWhenSupportedAndRangeChecked() async throws {
        let engine = MockWakeWordEngine()
        try await engine.initialize()
        try engine.updateSensitivity(0.8)
        #expect(engine.currentSensitivity == 0.8)
        #expect(throws: WakeWordError.self) { try engine.updateSensitivity(1.5) }
        #expect(throws: WakeWordError.self) { try engine.updateSensitivity(-0.1) }
        #expect(engine.callLog.sensitivityUpdates == [0.8])
    }

    @Test func enginesThatCannotChangeSensitivityInPlaceAskForReinitialization() async throws {
        var behavior = MockWakeWordEngine.Behavior()
        behavior.supportsLiveSensitivity = false
        let engine = MockWakeWordEngine(behavior: behavior)
        try await engine.initialize()
        #expect(throws: WakeWordError.requiresReinitialization) { try engine.updateSensitivity(0.9) }
    }

    @Test func initializationCanTakeTimeWithoutBlockingTheCaller() async throws {
        var behavior = MockWakeWordEngine.Behavior()
        behavior.initializeDelay = .milliseconds(80)
        let engine = MockWakeWordEngine(behavior: behavior)
        let started = ContinuousClock.now
        try await engine.initialize()
        #expect(ContinuousClock.now - started >= .milliseconds(70))
    }
}

struct MockEngineBehaviourTests {
    @Test func scriptedDetectionsFireOnTheRequestedFrames() async throws {
        var behavior = MockWakeWordEngine.Behavior()
        behavior.detectAtFrames = [2, 5]
        behavior.confidence = 0.9
        let engine = MockWakeWordEngine(behavior: behavior)
        try await engine.initialize()
        var hits: [Int] = []
        for index in 0..<8 {
            if let result = try engine.processAudio(EngineLifecycleContractTests.frame(sequence: UInt64(index))) {
                hits.append(index)
                #expect(result == DetectionResult(keyword: .jarvis, confidence: 0.9))
            }
        }
        #expect(hits == [2, 5])
    }

    @Test func triggerFiresOnTheNextFrameOnly() async throws {
        let engine = MockWakeWordEngine()
        try await engine.initialize()
        #expect(try engine.processAudio(EngineLifecycleContractTests.frame()) == nil)
        engine.trigger()
        #expect(try engine.processAudio(EngineLifecycleContractTests.frame()) != nil)
        #expect(try engine.processAudio(EngineLifecycleContractTests.frame()) == nil)
    }

    @Test func loudnessTriggerNeedsSustainedLevelAndSensitivityMovesTheThreshold() async throws {
        var behavior = MockWakeWordEngine.Behavior()
        behavior.loudnessTrigger = .init(consecutiveFrames: 3)
        let engine = MockWakeWordEngine(behavior: behavior, sensitivity: 0.5)
        try await engine.initialize()

        let loud = EngineLifecycleContractTests.frame(0.2) // ≈ -14 dBFS
        #expect(try engine.processAudio(loud) == nil)
        #expect(try engine.processAudio(loud) == nil)
        #expect(try engine.processAudio(loud) != nil, "third consecutive loud frame should fire")

        // A quiet frame breaks the run.
        #expect(try engine.processAudio(loud) == nil)
        #expect(try engine.processAudio(EngineLifecycleContractTests.frame(0)) == nil)
        #expect(try engine.processAudio(loud) == nil)
        #expect(try engine.processAudio(loud) == nil)

        // Lower sensitivity demands a louder sound than 0.02 (≈ -34 dBFS), higher accepts it.
        let moderate = EngineLifecycleContractTests.frame(0.03)
        try engine.updateSensitivity(0.0)
        for _ in 0..<5 { #expect(try engine.processAudio(moderate) == nil) }
        try engine.updateSensitivity(1.0)
        var fired = false
        for _ in 0..<3 { fired = try engine.processAudio(moderate) != nil || fired }
        #expect(fired)
    }

    @Test func thresholdMappingIsMonotonic() {
        let thresholds = stride(from: Float(0), through: 1, by: 0.25).map(MockWakeWordEngine.loudnessThreshold(sensitivity:))
        #expect(thresholds == thresholds.sorted(by: >))
    }
}

struct RegistryAndCredentialTests {
    static let production = EngineDescriptor(
        id: "real", displayName: "Real", summary: "", capabilities: .init(supportsLiveSensitivity: false, reportsConfidence: false),
        makeEngine: { _ in MockWakeWordEngine() }
    )

    @Test func developerOnlyEnginesAreHiddenUnlessDeveloperModeIsOn() {
        let registry = WakeWordEngineRegistry([MockWakeWordEngine.descriptor(), Self.production])
        #expect(registry.selectable(developerMode: false).map(\.id) == ["real"])
        #expect(registry.selectable(developerMode: true).map(\.id) == ["mock", "real"])
    }

    @Test func defaultEnginePrefersAProductionEngine() {
        #expect(WakeWordEngineRegistry([MockWakeWordEngine.descriptor(), Self.production]).defaultEngineID == "real")
        #expect(WakeWordEngineRegistry([MockWakeWordEngine.descriptor()]).defaultEngineID == "mock")
        #expect(WakeWordEngineRegistry([]).defaultEngineID == nil)
    }

    @Test func descriptorsBuildEnginesFromAnEnvironment() throws {
        let registry = WakeWordEngineRegistry([MockWakeWordEngine.descriptor()])
        let engine = try #require(registry["mock"]).makeEngine(EngineEnvironment(sensitivity: 0.3))
        #expect(engine.identifier == "mock")
        #expect((engine as? MockWakeWordEngine)?.currentSensitivity == 0.3)
        #expect(registry["missing"] == nil)
    }

    @Test func resourceLocatorFindsFilesInPriorityOrder() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try Data([1]).write(to: second.appendingPathComponent("model.bin"))
        let locator = EngineResourceLocator(searchDirectories: [first, second])
        #expect(locator.locate("model.bin") == second.appendingPathComponent("model.bin"))
        try Data([2]).write(to: first.appendingPathComponent("model.bin"))
        #expect(locator.locate("model.bin") == first.appendingPathComponent("model.bin"))
        #expect(locator.locate("absent.bin") == nil)
    }

    @Test func nativeLibrariesAreOnlyTakenFromLibraryDirectoriesNeverFromDataDirectories() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("locator-split-\(UUID().uuidString)")
        let data = root.appendingPathComponent("user-models"), code = root.appendingPathComponent("bundle-frameworks")
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: code, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        // Something that looks like a library dropped into the folder a user (or malware running as them) can write to.
        try Data([1]).write(to: data.appendingPathComponent("libengine.dylib"))
        let locator = EngineResourceLocator(searchDirectories: [data], libraryDirectories: [code])
        #expect(locator.locate("libengine.dylib") != nil, "it is a fine *data* file")
        #expect(locator.locateLibrary("libengine.dylib") == nil, "but it is never loadable code")

        try Data([2]).write(to: code.appendingPathComponent("libengine.dylib"))
        #expect(locator.locateLibrary("libengine.dylib") == code.appendingPathComponent("libengine.dylib"))
        #expect(EngineResourceLocator(searchDirectories: [data]).locateLibrary("libengine.dylib") == nil, "no library directories, no libraries")
    }

    @Test func directoriesAreNotMistakenForFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("locator-dir-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root.appendingPathComponent("model.bin"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        #expect(EngineResourceLocator(searchDirectories: [root], libraryDirectories: [root]).locate("model.bin") == nil)
        #expect(EngineResourceLocator(searchDirectories: [root], libraryDirectories: [root]).locateLibrary("model.bin") == nil)
    }

    @Test func requiringASecretTellsAnUnreadableStoreFromAnEmptyOne() throws {
        struct LockedStore: CredentialReading {
            func secret(for key: CredentialKey) -> String? { nil }
            func accessProblem(for key: CredentialKey) -> String? { "the Keychain is locked" }
        }
        let key = CredentialKey(engineID: "x", name: "token")

        let empty = InMemoryCredentialStore()
        #expect(throws: WakeWordError.credentialMissing(key)) { try empty.requireSecret(for: key) }

        #expect(throws: WakeWordError.credentialUnreadable(key, detail: "the Keychain is locked")) { try LockedStore().requireSecret(for: key) }

        try empty.setSecret("abc-123", for: key)
        #expect(try empty.requireSecret(for: key) == "abc-123")

        let error = WakeWordError.credentialUnreadable(key, detail: "locked")
        #expect(error.recovery == .manualRetryOnly)
        #expect(!error.isCredentialProblem, "the user may have saved a key; the editor is not the fix")
        #expect(error.localizedDescription.contains("Keychain") && error.localizedDescription.contains("token"))
        #expect(error.recoverySuggestion?.contains("Try Again") == true)
    }

    @Test func inMemoryCredentialsRoundTripAndEmptyValuesRemove() throws {
        let store = InMemoryCredentialStore()
        let key = CredentialKey(engineID: "x", name: "token")
        #expect(store.secret(for: key) == nil)
        try store.setSecret("abc-123", for: key)
        #expect(store.secret(for: key) == "abc-123")
        try store.setSecret("", for: key)
        #expect(store.secret(for: key) == nil)
    }

    @Test func redactionRemovesSecretsThatNativeLibrariesEchoInErrors() {
        let secret = "AbCdEf1234567890=="
        let message = "AccessKey \(secret) has reached its temporary device limit (\(secret))"
        let cleaned = SecretRedactor.redact(message, secrets: [secret])
        #expect(!cleaned.contains(secret))
        #expect(cleaned == "AccessKey •••• has reached its temporary device limit (••••)")
        #expect(SecretRedactor.redact("abc", secrets: ["abc"]) == "abc", "tiny strings are not treated as secrets")
    }

    @Test func errorsDescribeTheirRecovery() {
        let key = CredentialKey(engineID: "engine-x", name: "ApiKey")
        #expect(WakeWordError.networkUnavailable("offline").recovery == .retryAutomatically)
        #expect(WakeWordError.credentialMissing(key).recovery == .needsUserAction(.provideCredential(key)))
        #expect(WakeWordError.credentialRejected(key, detail: "bad").recovery == .needsUserAction(.provideCredential(key)))
        #expect(WakeWordError.licenceLimit("limit").recovery == .needsUserAction(.reviewLicence))
        #expect(WakeWordError.engineUnavailable("x").recovery == .needsUserAction(.installEngineFiles))
        #expect(WakeWordError.processingFailed("x").recovery == .manualRetryOnly)
        #expect(WakeWordError.licenceLimit("x").isCredentialProblem)
        #expect(!WakeWordError.processingFailed("x").isCredentialProblem)
    }
}

struct BroadcasterTests {
    @Test func everySubscriberReceivesEveryElementInOrder() async {
        let broadcaster = Broadcaster<Int>()
        let a = broadcaster.stream(), b = broadcaster.stream()
        for value in 1...3 { broadcaster.send(value) }
        broadcaster.finish()
        var seenA: [Int] = [], seenB: [Int] = []
        for await value in a { seenA.append(value) }
        for await value in b { seenB.append(value) }
        #expect(seenA == [1, 2, 3])
        #expect(seenB == [1, 2, 3])
    }

    @Test func aCancelledSubscriberIsRemoved() async {
        let broadcaster = Broadcaster<Int>()
        let task = Task { for await _ in broadcaster.stream() {} }
        // Wait for the subscription to register.
        while broadcaster.subscriberCount == 0 { await Task.yield() }
        task.cancel()
        _ = await task.value
        for _ in 0..<100 where broadcaster.subscriberCount != 0 { await Task.yield() }
        #expect(broadcaster.subscriberCount == 0)
    }
}
