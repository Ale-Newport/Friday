import Foundation
import WakeWordKit

/// Registration point for the Porcupine engine: how it is described to the UI, which files it
/// needs, and how to build it. The composition root adds ``PorcupineBackend/descriptor`` to the
/// registry; nothing else in the application references this module.
public enum PorcupineBackend {
    public static let engineID = PorcupineWakeWordEngine.engineID
    public static let accessKeyCredential = PorcupineWakeWordEngine.accessKeyCredential

    /// File names the engine looks for, below any of the environment's search directories.
    enum FileName {
        static let library = "libpv_porcupine.dylib"
        static let model = "porcupine_params.pv"
        /// A user-trained replacement (for example tuned to an accent) wins over the built-in model.
        static let customJarvis = "jarvis_custom.ppn"
        static let builtInJarvis = "jarvis_mac.ppn"
    }

    public static let consoleURL = URL(string: "https://console.picovoice.ai/")!

    public static var descriptor: EngineDescriptor {
        EngineDescriptor(
            id: engineID,
            displayName: "Picovoice Porcupine",
            summary: "On-device keyword spotting with the built-in “Jarvis” model. Requires a Picovoice AccessKey, "
                + "which is validated online when the engine starts; audio never leaves the Mac.",
            credentials: [
                CredentialRequirement(
                    key: accessKeyCredential,
                    title: "Picovoice AccessKey",
                    explanation: "Created in the Picovoice Console and stored in your Keychain — never in files or logs. "
                        + "Picovoice ended its free tier on 30 June 2026, so the key must belong to a plan that allows your use.",
                    helpURL: consoleURL
                )
            ],
            capabilities: EngineCapabilities(supportsLiveSensitivity: false, reportsConfidence: false),
            preflight: { environment in
                let files = locateFiles(in: environment)
                guard files.missing.isEmpty, let library = files.library else {
                    return .unavailable(reason: "Missing \(files.missing.joined(separator: ", ")). Run Scripts/fetch-porcupine.sh and rebuild.")
                }
                // Loading (not just finding) the library catches a wrong architecture or a code-signing
                // problem now, with the system's own explanation, instead of at first use.
                if case .failure(let error) = inspectLibrary(at: library) {
                    return .unavailable(reason: error.errorDescription ?? "The engine library could not be loaded.")
                }
                return .ready
            },
            makeEngine: { environment throws(WakeWordError) in
                let key = try environment.credentials.requireSecret(for: accessKeyCredential)
                guard environment.keywords == [.jarvis] else {
                    throw .invalidConfiguration("the Porcupine backend ships a model for \"Jarvis\" only")
                }
                let files = locateFiles(in: environment)
                guard let library = files.library, let model = files.model, let jarvis = files.jarvis else {
                    throw .engineUnavailable("missing \(files.missing.joined(separator: ", "))")
                }
                return PorcupineWakeWordEngine(configuration: .init(
                    accessKey: key,
                    libraryURL: library,
                    modelURL: model,
                    keywords: [(.jarvis, jarvis)],
                    sensitivity: environment.sensitivity
                ))
            }
        )
    }

    /// Facts reported by the native library itself (no AccessKey or network needed).
    public struct LibraryInfo: Equatable, Sendable {
        public let version: String
        public let sampleRate: Int
        public let frameLength: Int
    }

    /// Loads the library at `url` and reads its constants. Never initialises an engine.
    public static func inspectLibrary(at url: URL) -> Result<LibraryInfo, WakeWordError> {
        do {
            let bindings = try LibraryBindings.load(from: url)
            return .success(LibraryInfo(version: bindings.version, sampleRate: bindings.sampleRate, frameLength: bindings.frameLength))
        } catch {
            return .failure(error)
        }
    }

    struct Files {
        var library: URL?
        var model: URL?
        var jarvis: URL?
        var missing: [String] {
            var names: [String] = []
            if library == nil { names.append(FileName.library) }
            if model == nil { names.append(FileName.model) }
            if jarvis == nil { names.append(FileName.builtInJarvis) }
            return names
        }
    }

    static func locateFiles(in environment: EngineEnvironment) -> Files {
        let resources = environment.resources
        return Files(
            // Native code: only from the library directories (the app bundle), never from the user-writable models folder.
            library: resources.locateLibrary(FileName.library),
            model: resources.locate(FileName.model),
            jarvis: resources.locate(FileName.customJarvis) ?? resources.locate(FileName.builtInJarvis)
        )
    }
}
