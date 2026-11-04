import Foundation

/// Where an engine may look for its files, in priority order.
///
/// **Data and code are searched separately on purpose.** Models and keyword files may come from places
/// the user can write to (a "drop your custom model here" folder). Native *libraries* are code that would
/// run inside this process with its microphone permission, so they are only ever taken from
/// `libraryDirectories` — the app bundle (or, for command-line tools, a vendor folder) — never from a
/// user-writable location.
public struct EngineResourceLocator: Sendable {
    /// Where models and other data files may be found.
    public var searchDirectories: [URL]
    /// Where native libraries may be found. Keep this to locations the user cannot casually write to.
    public var libraryDirectories: [URL]

    public init(searchDirectories: [URL] = [], libraryDirectories: [URL] = []) {
        self.searchDirectories = searchDirectories
        self.libraryDirectories = libraryDirectories
    }

    /// Returns the first existing regular data file named `relativePath` below any search directory.
    public func locate(_ relativePath: String) -> URL? {
        Self.firstFile(named: relativePath, in: searchDirectories)
    }

    /// Returns the first existing native library named `relativePath` below a *library* directory.
    public func locateLibrary(_ relativePath: String) -> URL? {
        Self.firstFile(named: relativePath, in: libraryDirectories)
    }

    private static func firstFile(named relativePath: String, in directories: [URL]) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }
}

/// Everything an engine factory may depend on. Notably absent: UI, audio capture, the
/// application's settings model. Adding a new engine never requires widening this struct unless
/// the engine needs a genuinely new kind of input.
public struct EngineEnvironment: Sendable {
    public var keywords: [WakeKeyword]
    /// Normalised sensitivity in `[0, 1]`.
    public var sensitivity: Float
    public var credentials: any CredentialReading
    public var resources: EngineResourceLocator

    public init(
        keywords: [WakeKeyword] = [.jarvis],
        sensitivity: Float = 0.5,
        credentials: any CredentialReading = InMemoryCredentialStore(),
        resources: EngineResourceLocator = EngineResourceLocator()
    ) {
        self.keywords = keywords
        self.sensitivity = sensitivity
        self.credentials = credentials
        self.resources = resources
    }
}

public enum EngineAvailability: Equatable, Sendable {
    /// Required files are present. (Says nothing about credentials or licences.)
    case ready
    /// Cannot work in this build/installation, with a reason suitable for display.
    case unavailable(reason: String)

    public var isReady: Bool { self == .ready }
}

public struct EngineCapabilities: Equatable, Sendable {
    /// `updateSensitivity` applies instantly, without rebuilding the engine.
    public var supportsLiveSensitivity: Bool
    /// The engine reports `DetectionResult.confidence`.
    public var reportsConfidence: Bool

    public init(supportsLiveSensitivity: Bool, reportsConfidence: Bool) {
        self.supportsLiveSensitivity = supportsLiveSensitivity
        self.reportsConfidence = reportsConfidence
    }
}

/// Describes one selectable detection engine: how to present it and how to build it.
public struct EngineDescriptor: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let credentials: [CredentialRequirement]
    public let capabilities: EngineCapabilities
    /// Engines intended for development only (the mock) are hidden unless developer mode is on.
    public let isDeveloperOnly: Bool
    /// A cheap, side-effect-free check used by the UI (for example "model files present?").
    public let preflight: @Sendable (EngineEnvironment) -> EngineAvailability
    public let makeEngine: @Sendable (EngineEnvironment) throws(WakeWordError) -> any WakeWordEngine
    /// How the engine can be taught the person's voice; nil for an engine that cannot.
    public let voiceTrainer: VoiceTrainer?

    public init(
        id: String,
        displayName: String,
        summary: String,
        credentials: [CredentialRequirement] = [],
        capabilities: EngineCapabilities,
        isDeveloperOnly: Bool = false,
        preflight: @escaping @Sendable (EngineEnvironment) -> EngineAvailability = { _ in .ready },
        voiceTrainer: VoiceTrainer? = nil,
        makeEngine: @escaping @Sendable (EngineEnvironment) throws(WakeWordError) -> any WakeWordEngine
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.credentials = credentials
        self.capabilities = capabilities
        self.isDeveloperOnly = isDeveloperOnly
        self.preflight = preflight
        self.voiceTrainer = voiceTrainer
        self.makeEngine = makeEngine
    }
}

/// The set of engines the application can choose from. Built once in the composition root.
public struct WakeWordEngineRegistry: Sendable {
    public let all: [EngineDescriptor]

    public init(_ descriptors: [EngineDescriptor]) {
        precondition(Set(descriptors.map(\.id)).count == descriptors.count, "duplicate engine identifiers")
        self.all = descriptors
    }

    public subscript(id: String) -> EngineDescriptor? {
        all.first { $0.id == id }
    }

    /// Engines to show in pickers.
    public func selectable(developerMode: Bool) -> [EngineDescriptor] {
        all.filter { developerMode || !$0.isDeveloperOnly }
    }

    /// The first non-developer engine — used when a stored selection no longer exists.
    public var defaultEngineID: String? {
        (all.first { !$0.isDeveloperOnly } ?? all.first)?.id
    }
}
