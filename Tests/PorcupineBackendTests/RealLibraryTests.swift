import Foundation
import Testing
import WakeWordKit
@testable import PorcupineBackend

/// Tests against the real `libpv_porcupine.dylib`. They run when the library has been fetched
/// (`Scripts/fetch-porcupine.sh`) and are skipped otherwise. None of them needs an AccessKey or
/// network access: they verify that the ABI, constants and error paths of the actual binary match
/// what the backend assumes. (A real detection test needs a valid key — see docs/TESTING.md.)
enum RealLibrary {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/Porcupine")
    static let library = root.appendingPathComponent("lib/libpv_porcupine.dylib")
    static let model = root.appendingPathComponent("models/porcupine_params.pv")
    static let keyword = root.appendingPathComponent("keywords/jarvis_mac.ppn")
    static var isAvailable: Bool {
        [library, model, keyword].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

@Suite(.enabled(if: RealLibrary.isAvailable, "run Scripts/fetch-porcupine.sh to enable"))
struct RealLibraryTests {
    @Test func theLibraryLoadsAndExposesTheConstantsTheBackendAssumes() throws {
        let bindings = try LibraryBindings.load(from: RealLibrary.library)
        #expect(bindings.sampleRate == 16_000)
        #expect(bindings.frameLength == 512)
        #expect(bindings.version.hasPrefix("4."), "the backend and vendored header target Porcupine 4.x; got \(bindings.version)")
    }

    @Test func loadingTheSameLibraryTwiceReusesTheTable() throws {
        let first = try LibraryBindings.load(from: RealLibrary.library)
        let second = try LibraryBindings.load(from: RealLibrary.library)
        #expect(first === second)
    }

    @Test func aMissingLibraryIsAnEngineAvailabilityProblem() {
        do {
            _ = try LibraryBindings.load(from: URL(fileURLWithPath: "/nonexistent/libpv_porcupine.dylib"))
            Issue.record("expected failure")
        } catch {
            guard case .engineUnavailable = error else { Issue.record("wrong error \(error)"); return }
            #expect(error.recovery == .needsUserAction(.installEngineFiles))
        }
    }

    @Test func aFileThatIsNotALibraryIsRejectedCleanly() {
        do {
            _ = try LibraryBindings.load(from: RealLibrary.keyword) // a .ppn is not a Mach-O
            Issue.record("expected failure")
        } catch {
            guard case .engineUnavailable = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    /// A syntactically invalid key is rejected by the library locally, so this exercises the real
    /// `pv_porcupine_init` and the real error stack without contacting any server.
    @Test func aMalformedAccessKeyIsRejectedAsACredentialProblemWithoutLeakingIt() async {
        let malformed = "this-is-not-a-picovoice-key"
        let engine = PorcupineWakeWordEngine(configuration: .init(
            accessKey: malformed, libraryURL: RealLibrary.library, modelURL: RealLibrary.model,
            keywords: [(.jarvis, RealLibrary.keyword)]
        ))
        do {
            try await engine.initialize()
            Issue.record("a malformed key must not initialise")
        } catch {
            #expect(error.isCredentialProblem, "got \(error)")
            #expect(!"\(error)".contains(malformed))
            #expect(!(error.errorDescription ?? "").contains(malformed))
        }
        #expect(throws: WakeWordError.notInitialized) {
            try engine.processAudio(AudioFrame(samples: [Float](repeating: 0, count: 512), sampleRate: 16_000, sequence: 0, captureTime: .zero))
        }
        engine.shutdown()
    }
}
