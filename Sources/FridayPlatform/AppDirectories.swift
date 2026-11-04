import Foundation

/// Where Jarvis keeps its (small) on-disk state. Nothing here ever contains audio.
///
/// The folder is "Jarvis Wake Word", not plain "Jarvis": a Mac can easily hold another project called Jarvis
/// (this one's neighbour does), and two programs must not share — or tidy up — each other's folder.
public struct AppDirectories: Sendable {
    public static let defaultName = "Friday"

    public let applicationSupport: URL
    /// Things that can be made again if they are lost (macOS may clear it when space runs short).
    public let caches: URL

    public init(appName: String = AppDirectories.defaultName, base: URL? = nil, cachesBase: URL? = nil) {
        let root = base
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        applicationSupport = root.appendingPathComponent(appName, isDirectory: true)
        let cachesRoot = cachesBase
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        caches = cachesRoot.appendingPathComponent(appName, isDirectory: true)
    }

    /// Optional user-supplied engine files (for example a keyword model trained for your accent).
    /// Engines search here after their bundled resources.
    public var userModels: URL { applicationSupport.appendingPathComponent("Models", isDirectory: true) }

    /// Speech made with the Mac's voices that voice learning checks against (never recordings of a person).
    public var referenceSpeech: URL { caches.appendingPathComponent("ReferenceSpeech", isDirectory: true) }

    public var accuracyResults: URL { applicationSupport.appendingPathComponent("accuracy-results.json") }

    public func ensureUserModelsExists() {
        try? FileManager.default.createDirectory(at: userModels, withIntermediateDirectories: true)
    }
}
