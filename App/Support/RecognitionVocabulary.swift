import Contacts
import Foundation
import FridayCore
import os

/// The words the speech recogniser should expect that no language model knows: the names of the applications on
/// this Mac, the person's Music playlists and their contacts' first names. "Open Obsidian", "play Deep Focus" and
/// "text Íñigo" are transcribed right only when the recogniser has seen those names.
///
/// Nothing here asks for a permission: playlists are read only when Music automation is already allowed (and
/// Music is running, so macOS can say so without launching it), contacts only when Contacts access was granted
/// earlier. The list is cached and refreshed in the background, so asking for it never delays a listen.
actor RecognitionVocabulary {
    private static let logger = Logger(subsystem: "com.alejandro.friday", category: "vocabulary")

    private let engine: ActionEngine
    private let integrations: [any AppIntegration]
    private let refreshInterval: Duration
    private var words: [String] = []
    private var refreshedAt: ContinuousClock.Instant?
    private var refresh: Task<Void, Never>?

    init(engine: ActionEngine, integrations: [any AppIntegration], refreshInterval: Duration = .seconds(15 * 60)) {
        self.engine = engine
        self.integrations = integrations
        self.refreshInterval = refreshInterval
    }

    /// The current list, at once; a refresh is started when it is stale.
    func current() -> [String] {
        if let refreshedAt, refreshedAt.duration(to: .now) < refreshInterval {} else { scheduleRefresh() }
        return words
    }

    /// Collects everything again (installed apps, playlists, contacts) and waits for it.
    func update() async {
        scheduleRefresh()
        await refresh?.value
    }

    private func scheduleRefresh() {
        guard refresh == nil else { return }
        let engine = engine, integrations = integrations
        // Collected off the actor: enumerating folders and contacts must not hold up a listen asking for the list.
        refresh = Task.detached(priority: .utility) { [weak self] in
            let collected = await Self.collect(engine: engine, integrations: integrations)
            await self?.store(collected)
        }
    }

    private func store(_ collected: [String]) {
        words = collected
        refreshedAt = .now
        refresh = nil
        Self.logger.info("recognition vocabulary: \(collected.count, privacy: .public) names")
    }

    static func collect(engine: ActionEngine, integrations: [any AppIntegration]) async -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in installedApplicationNames() + (await musicPlaylistNames(engine: engine, integrations: integrations)) + contactGivenNames() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1, trimmed.count <= 60, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    // MARK: Sources

    static let applicationFolders = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
    ]

    /// Display names of the application bundles in the usual folders (one level deep; no Spotlight, no launching).
    static func installedApplicationNames(folders: [String] = applicationFolders) -> [String] {
        let manager = FileManager.default
        var names: [String] = []
        for folder in folders {
            guard let entries = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (folder as NSString).appendingPathComponent(entry)
                let bundle = Bundle(path: path)
                let declared = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                if let declared, !declared.isEmpty { names.append(declared) } else { names.append(String(entry.dropLast(4))) }
            }
        }
        return names
    }

    /// Playlist names through the Music integration's own tool — only when it reports itself ready, which means
    /// Music is running and automation is already allowed, so running the tool cannot show a prompt.
    static func musicPlaylistNames(engine: ActionEngine, integrations: [any AppIntegration]) async -> [String] {
        guard let music = integrations.first(where: { $0.id == .music }) else { return [] }
        guard await music.status().state == .ready else { return [] }
        let response = await engine.execute(
            ToolCall(tool: .musicListPlaylists, arguments: ["limit": .int(500)]), session: "vocabulary", recordHistory: false)
        guard response.success, let playlists = response.results.first?.data?["playlists"]?.arrayValue else { return [] }
        return playlists.compactMap { $0["name"]?.stringValue }
    }

    /// Contacts' given names (and nicknames), only when access was granted before; never asks.
    static func contactGivenNames(limit: Int = 2000) -> [String] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor])
        request.unifyResults = true
        var names: [String] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, stop in
            if !contact.givenName.isEmpty { names.append(contact.givenName) }
            if !contact.nickname.isEmpty { names.append(contact.nickname) }
            if names.count >= limit { stop.pointee = true }
        }
        return names
    }
}
