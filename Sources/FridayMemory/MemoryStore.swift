import Foundation
import FridayCore

/// Friday's local, privacy-conscious persistent memory.
///
/// Everything lives in one SQLite file (WAL mode, owner-only permissions) under the user's Application Support
/// folder; nothing is ever sent anywhere. Four kinds of memory share the file:
///
/// * **Memory items** – preferences, entities, knowledge, workflows and tasks the user or Friday chose to keep,
///   searched accent- and case-insensitively (FTS5 with bm25 when SQLite offers it, token scoring otherwise).
/// * **Conversation turns** – recent messages per session, capped at ``maxTurnsPerSession``.
/// * **Task records** – what Friday is working on, so it can answer "what are you doing?" after a restart.
/// * **Routines** – learned workflows: trigger phrases in any language plus the tool calls they expand to.
///
/// The actor owns the SQLite handle outright, so no `@unchecked Sendable` is needed anywhere.
public actor MemoryStore {
    public static let schemaVersion = 1
    /// Oldest turns beyond this many per session are trimmed on insert.
    public static let maxTurnsPerSession = 400
    public static let defaultRetentionDays = 365

    private let connection: SQLiteConnection
    /// `true` when `CREATE VIRTUAL TABLE … USING fts5` succeeded at open time.
    public let hasFullTextSearch: Bool
    public nonisolated let databaseURL: URL?
    private var enabled: Bool
    private var retention: Int?

    /// `~/Library/Application Support/<Friday folder>/memory.sqlite`.
    public static func defaultDatabaseURL() -> URL {
        JarvisPaths.applicationSupportDirectory().appendingPathComponent("memory.sqlite")
    }

    /// Opens (creating when needed) the database at `databaseURL` with owner-only permissions.
    public init(databaseURL: URL) throws {
        JarvisPaths.ensurePrivateDirectory(databaseURL.deletingLastPathComponent())
        try self.init(path: databaseURL.path, fileURL: databaseURL, fullTextSearch: true)
    }

    /// A throw-away store that lives only in memory; used by tests and previews.
    public static func inMemory() throws -> MemoryStore {
        try MemoryStore(path: ":memory:", fileURL: nil, fullTextSearch: true)
    }

    /// Test hook: an in-memory store that skips the FTS5 probe so the token-scoring fallback can be exercised.
    static func inMemory(fullTextSearch: Bool) throws -> MemoryStore {
        try MemoryStore(path: ":memory:", fileURL: nil, fullTextSearch: fullTextSearch)
    }

    private init(path: String, fileURL: URL?, fullTextSearch: Bool) throws {
        let connection = try SQLiteConnection(path: path)
        if let fileURL {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try connection.execute("PRAGMA journal_mode = WAL")
        }
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA synchronous = NORMAL")
        try Self.migrate(connection)
        let fts = fullTextSearch && Self.enableFullTextSearch(connection)
        self.connection = connection
        self.databaseURL = fileURL
        self.hasFullTextSearch = fts
        self.enabled = (try Self.setting(connection, "enabled")).map { $0 != "0" } ?? true
        if let stored = try Self.setting(connection, "retention_days") {
            self.retention = Int(stored).flatMap { $0 > 0 ? $0 : nil }
        } else {
            self.retention = Self.defaultRetentionDays
        }
        JarvisLog.persistence.info("Memory store opened (fts5: \(fts, privacy: .public)).")
    }

    // MARK: - Schema

    private static let schemaV1 = """
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS memory_items (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            key TEXT,
            content TEXT NOT NULL,
            folded TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_used_at REAL,
            use_count INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS memory_items_key ON memory_items(key) WHERE key IS NOT NULL;
        CREATE INDEX IF NOT EXISTS memory_items_kind ON memory_items(kind, updated_at DESC);
        CREATE TABLE IF NOT EXISTS conversation_turns (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            language TEXT,
            created_at REAL NOT NULL,
            tool_summary TEXT
        );
        CREATE INDEX IF NOT EXISTS conversation_turns_session ON conversation_turns(session_id, seq);
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            detail TEXT,
            payload TEXT
        );
        CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status, updated_at DESC);
        CREATE TABLE IF NOT EXISTS routines (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            folded_name TEXT NOT NULL UNIQUE,
            phrases TEXT NOT NULL,
            steps TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_run_at REAL,
            run_count INTEGER NOT NULL DEFAULT 0
        );
        """

    private static func migrate(_ db: SQLiteConnection) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        var version = try db.scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_version")
        while version < schemaVersion {
            let next = version + 1
            try db.transaction {
                switch next {
                case 1: try db.execute(schemaV1)
                default: break
                }
                try db.run("DELETE FROM schema_version")
                try db.run("INSERT INTO schema_version (version) VALUES (?)", [SQLiteValue(next)])
            }
            version = next
        }
    }

    /// Probes FTS5 inside a savepoint; a SQLite built without it simply leaves us with token scoring.
    private static func enableFullTextSearch(_ db: SQLiteConnection) -> Bool {
        let created: Void? = db.attempt {
            try db.execute(
                "CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(item_id UNINDEXED, folded, tokenize='unicode61')")
        }
        guard created != nil else { return false }
        // Rebuild when the index and the table disagree (first run after an upgrade, or an interrupted write).
        if let items = try? db.scalarInt("SELECT COUNT(*) FROM memory_items"),
            let indexed = try? db.scalarInt("SELECT COUNT(*) FROM memory_fts"), items != indexed
        {
            _ = db.attempt {
                try db.run("DELETE FROM memory_fts")
                try db.run("INSERT INTO memory_fts (item_id, folded) SELECT id, folded FROM memory_items")
            }
        }
        return true
    }

    private static func setting(_ db: SQLiteConnection, _ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?.string("value")
    }

    private func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try connection.run(
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)])
        } else {
            try connection.run("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Settings

    public var isEnabled: Bool { enabled }

    /// When off, ``remember(kind:key:content:source:now:)`` throws ``MemoryError/disabled`` and recall returns
    /// nothing; existing memories are kept untouched. Persisted.
    public func setEnabled(_ value: Bool) throws {
        try setSetting("enabled", value ? "1" : "0")
        enabled = value
    }

    /// Days after which unpinned, unused items and old conversation turns are removed by ``prune(now:)``.
    /// `nil` keeps everything forever.
    public var retentionDays: Int? { retention }

    public func setRetentionDays(_ days: Int?) throws {
        let value = days.flatMap { $0 > 0 ? $0 : nil }
        try setSetting("retention_days", value.map(String.init) ?? "0")
        retention = value
    }

    /// Deletes what has outlived ``retentionDays``. Returns how many items and turns were removed.
    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        guard let retention else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(retention) * 86_400)
        return try connection.transaction {
            let stale = try connection.query(
                "SELECT id FROM memory_items WHERE pinned = 0 AND MAX(updated_at, COALESCE(last_used_at, 0)) < ?",
                [SQLiteValue(cutoff)])
            for row in stale {
                guard let id = row.string("id") else { continue }
                try deleteItemRow(id)
            }
            let turns = try connection.run("DELETE FROM conversation_turns WHERE created_at < ?", [SQLiteValue(cutoff)])
            return stale.count + turns
        }
    }

    // MARK: - Memory items

    /// Stores a memory. When `key` is given and already exists the item is updated in place; keys are folded
    /// (lower-case, accent-free) so `Coffee` and `café` refer to the same slot. Without a key, an item of the
    /// same kind with identical (folded) content is reused instead of duplicated.
    @discardableResult
    public func remember(
        kind: MemoryKind, key: String? = nil, content: String, source: String = "user", now: Date = Date()
    ) throws -> MemoryItem {
        guard enabled else { throw MemoryError.disabled }
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw MemoryError.invalidInput("content is empty") }
        let key = key.map(TextFolding.fold).flatMap { $0.isEmpty ? nil : $0 }
        let folded = Self.searchText(key: key, content: content)
        return try connection.transaction {
            let existing: MemoryItem?
            if let key {
                existing = try fetchItems("WHERE key = ?", [.text(key)], limit: 1).first
            } else {
                existing = try fetchItems("WHERE key IS NULL AND kind = ? AND folded = ?", [.text(kind.rawValue), .text(folded)], limit: 1).first
            }
            if var item = existing {
                item.kind = kind
                item.content = content
                item.source = source
                item.updatedAt = now
                try connection.run(
                    "UPDATE memory_items SET kind = ?, content = ?, folded = ?, source = ?, updated_at = ? WHERE id = ?",
                    [.text(kind.rawValue), .text(content), .text(folded), .text(source), SQLiteValue(now), .text(item.id.uuidString)])
                try reindex(item.id, folded: folded)
                return item
            }
            let item = MemoryItem(kind: kind, key: key, content: content, source: source, createdAt: now, updatedAt: now)
            try connection.run(
                """
                INSERT INTO memory_items (id, kind, key, content, folded, source, created_at, updated_at, last_used_at, use_count, pinned)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, 0)
                """,
                [.text(item.id.uuidString), .text(kind.rawValue), SQLiteValue(key), .text(content), .text(folded), .text(source), SQLiteValue(now), SQLiteValue(now)])
            try reindex(item.id, folded: folded)
            return item
        }
    }

    /// Finds the memories most relevant to `query`, best first.
    ///
    /// Ranking: an exact (folded) key match outranks everything; then full-text hits ordered by how many query
    /// words they cover (plus bm25 when FTS5 is available), boosted by use count, recency and pinning.
    /// Matching is case- and accent-insensitive, so "canción" finds "cancion" and vice versa.
    public func recall(query: String, kinds: [MemoryKind] = [], limit: Int = 8, now: Date = Date()) throws -> [MemoryItem] {
        guard enabled, limit > 0 else { return [] }
        let folded = TextFolding.fold(query)
        guard !folded.isEmpty else { return [] }
        var tokens = TextFolding.tokens(folded).filter { $0.count >= 2 }
        if tokens.isEmpty { tokens = TextFolding.tokens(folded) }
        let kindClause: String
        var kindBindings: [SQLiteValue] = []
        if kinds.isEmpty {
            kindClause = ""
        } else {
            kindClause = " AND m.kind IN (" + kinds.map { _ in "?" }.joined(separator: ", ") + ")"
            kindBindings = kinds.map { .text($0.rawValue) }
        }

        var candidates: [UUID: (item: MemoryItem, base: Double)] = [:]
        func offer(_ item: MemoryItem, _ base: Double) {
            if let current = candidates[item.id], current.base >= base { return }
            candidates[item.id] = (item, base)
        }

        // 1. Exact key.
        for row in try connection.query("SELECT m.* FROM memory_items m WHERE m.key = ?" + kindClause, [.text(folded)] + kindBindings) {
            if let item = Self.item(from: row) { offer(item, 1_000) }
        }

        // 2. Full-text search with bm25.
        if hasFullTextSearch, !tokens.isEmpty {
            let match = tokens.map { "\"\($0)\"" + ($0.count >= 3 ? "*" : "") }.joined(separator: " OR ")
            let rows = try connection.query(
                "SELECT m.*, bm25(memory_fts) AS rank FROM memory_fts JOIN memory_items m ON m.id = memory_fts.item_id WHERE memory_fts MATCH ?"
                    + kindClause + " ORDER BY rank LIMIT ?",
                [.text(match)] + kindBindings + [SQLiteValue(max(limit * 4, 32))])
            for row in rows {
                guard let item = Self.item(from: row) else { continue }
                let coverage = PhraseMatching.coverage(queryTokens: tokens, foldedText: row.string("folded") ?? "")
                let bm25 = max(0, -(row.double("rank") ?? 0))
                offer(item, 100 * max(coverage, 0.2) + min(20, bm25 * 5))
            }
        }

        // 3. Substring scan: the only path without FTS5, and a safety net when FTS found little.
        if !hasFullTextSearch || candidates.count < limit {
            var needles = tokens.filter { $0.count >= 3 }
            if needles.isEmpty { needles = [folded] }
            let clauses = needles.map { _ in "m.folded LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            let rows = try connection.query(
                "SELECT m.* FROM memory_items m WHERE (" + clauses + ")" + kindClause + " ORDER BY m.updated_at DESC LIMIT ?",
                needles.map { .text("%" + Self.escapeLike($0) + "%") } + kindBindings + [SQLiteValue(max(limit * 4, 32))])
            for row in rows {
                guard let item = Self.item(from: row) else { continue }
                let coverage = PhraseMatching.coverage(queryTokens: tokens, foldedText: row.string("folded") ?? "")
                offer(item, 100 * max(coverage, 0.25))
            }
        }

        let ranked = candidates.values.map { entry -> (item: MemoryItem, score: Double) in
            let item = entry.item
            let useBoost = min(Double(item.useCount), 25) * 1.5
            let age = now.timeIntervalSince(max(item.updatedAt, item.lastUsedAt ?? .distantPast))
            let recencyBoost = 8 * max(0, 1 - age / (30 * 86_400))
            return (item, entry.base + useBoost + recencyBoost + (item.pinned ? 10 : 0))
        }
        .sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.item.updatedAt > right.item.updatedAt
        }
        return ranked.prefix(limit).map(\.item)
    }

    /// Records that a memory was used: bumps `useCount` and `lastUsedAt`, which raises it in future recalls.
    public func touch(id: UUID, now: Date = Date()) throws {
        let changed = try connection.run(
            "UPDATE memory_items SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?",
            [SQLiteValue(now), .text(id.uuidString)])
        guard changed > 0 else { throw MemoryError.notFound }
    }

    public func setPinned(id: UUID, _ pinned: Bool) throws {
        let changed = try connection.run("UPDATE memory_items SET pinned = ? WHERE id = ?", [SQLiteValue(pinned), .text(id.uuidString)])
        guard changed > 0 else { throw MemoryError.notFound }
    }

    public func forget(id: UUID) throws {
        try connection.transaction {
            guard try deleteItemRow(id.uuidString) else { throw MemoryError.notFound }
        }
    }

    /// Removes every item of `kind`, or everything when `kind` is `nil`. Returns the number removed.
    @discardableResult
    public func forgetAll(kind: MemoryKind? = nil) throws -> Int {
        try connection.transaction {
            let removed: Int
            if let kind {
                removed = try connection.run("DELETE FROM memory_items WHERE kind = ?", [.text(kind.rawValue)])
            } else {
                removed = try connection.run("DELETE FROM memory_items")
            }
            if hasFullTextSearch {
                try connection.run("DELETE FROM memory_fts WHERE item_id NOT IN (SELECT id FROM memory_items)")
            }
            return removed
        }
    }

    /// Items newest first (pinned ones on top), optionally restricted to one kind.
    public func items(kind: MemoryKind? = nil, limit: Int = 100) throws -> [MemoryItem] {
        if let kind {
            return try fetchItems("WHERE kind = ? ORDER BY pinned DESC, updated_at DESC", [.text(kind.rawValue)], limit: limit)
        }
        return try fetchItems("ORDER BY pinned DESC, updated_at DESC", [], limit: limit)
    }

    public func item(id: UUID) throws -> MemoryItem? {
        try fetchItems("WHERE id = ?", [.text(id.uuidString)], limit: 1).first
    }

    /// Looks a key up; the key is folded the same way ``remember(kind:key:content:source:now:)`` folds it.
    public func item(key: String) throws -> MemoryItem? {
        try fetchItems("WHERE key = ?", [.text(TextFolding.fold(key))], limit: 1).first
    }

    public func count(kind: MemoryKind? = nil) throws -> Int {
        if let kind { return try connection.scalarInt("SELECT COUNT(*) FROM memory_items WHERE kind = ?", [.text(kind.rawValue)]) }
        return try connection.scalarInt("SELECT COUNT(*) FROM memory_items")
    }

    // MARK: Entities

    public static func entityKey(kind: String, name: String) -> String {
        "entity:" + TextFolding.fold(kind) + ":" + TextFolding.fold(name)
    }

    /// Remembers a named thing (`contact`, `playlist`, `app`, `document`, `project`, `place`…) under a stable key
    /// so meeting it again updates the same memory.
    @discardableResult
    public func rememberEntity(kind: String, name: String, detail: String? = nil, source: String = "tool", now: Date = Date()) throws -> MemoryItem {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !kind.isEmpty else { throw MemoryError.invalidInput("entity kind and name are required") }
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = kind + ": " + name + (detail.flatMap { $0.isEmpty ? nil : " — " + $0 } ?? "")
        return try remember(kind: .entity, key: Self.entityKey(kind: kind, name: name), content: content, source: source, now: now)
    }

    public func entities(kind: String, limit: Int = 100) throws -> [MemoryItem] {
        let prefix = "entity:" + TextFolding.fold(kind) + ":"
        return try fetchItems(
            "WHERE kind = 'entity' AND key LIKE ? ESCAPE '\\' ORDER BY updated_at DESC",
            [.text(Self.escapeLike(prefix) + "%")], limit: limit)
    }

    // MARK: Item helpers

    private static func searchText(key: String?, content: String) -> String {
        TextFolding.fold((key.map { $0 + " " } ?? "") + content)
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    private func fetchItems(_ clause: String, _ bindings: [SQLiteValue], limit: Int) throws -> [MemoryItem] {
        try connection.query("SELECT * FROM memory_items " + clause + " LIMIT ?", bindings + [SQLiteValue(max(0, limit))])
            .compactMap(Self.item(from:))
    }

    private static func item(from row: SQLiteRow) -> MemoryItem? {
        guard let id = row.string("id").flatMap(UUID.init(uuidString:)),
            let kind = row.string("kind").flatMap(MemoryKind.init(rawValue:)),
            let content = row.string("content"), let created = row.date("created_at"), let updated = row.date("updated_at")
        else { return nil }
        return MemoryItem(
            id: id, kind: kind, key: row.string("key"), content: content, source: row.string("source") ?? "user",
            createdAt: created, updatedAt: updated, lastUsedAt: row.date("last_used_at"), useCount: row.int("use_count") ?? 0,
            pinned: row.bool("pinned"))
    }

    private func reindex(_ id: UUID, folded: String) throws {
        guard hasFullTextSearch else { return }
        try connection.run("DELETE FROM memory_fts WHERE item_id = ?", [.text(id.uuidString)])
        try connection.run("INSERT INTO memory_fts (item_id, folded) VALUES (?, ?)", [.text(id.uuidString), .text(folded)])
    }

    /// Deletes one item row and its index entry. Returns `false` when there was no such row.
    @discardableResult
    private func deleteItemRow(_ id: String) throws -> Bool {
        let removed = try connection.run("DELETE FROM memory_items WHERE id = ?", [.text(id)])
        if hasFullTextSearch { try connection.run("DELETE FROM memory_fts WHERE item_id = ?", [.text(id)]) }
        return removed > 0
    }

    // MARK: - Conversation memory

    @discardableResult
    public func appendTurn(
        session: String, role: String, text: String, language: String? = nil, toolSummary: String? = nil, now: Date = Date()
    ) throws -> ConversationTurn {
        let session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw MemoryError.invalidInput("session is empty") }
        let turn = ConversationTurn(sessionID: session, role: role, text: text, language: language, createdAt: now, toolSummary: toolSummary)
        try connection.transaction {
            try connection.run(
                "INSERT INTO conversation_turns (id, session_id, role, text, language, created_at, tool_summary) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(turn.id.uuidString), .text(session), .text(role), .text(text), SQLiteValue(language), SQLiteValue(now), SQLiteValue(toolSummary)])
            try connection.run(
                """
                DELETE FROM conversation_turns WHERE session_id = ? AND seq NOT IN
                    (SELECT seq FROM conversation_turns WHERE session_id = ? ORDER BY seq DESC LIMIT ?)
                """,
                [.text(session), .text(session), SQLiteValue(Self.maxTurnsPerSession)])
        }
        return turn
    }

    /// The last `limit` turns of a session in chronological order.
    public func recentTurns(session: String, limit: Int = 20) throws -> [ConversationTurn] {
        let rows = try connection.query(
            "SELECT * FROM (SELECT * FROM conversation_turns WHERE session_id = ? ORDER BY seq DESC LIMIT ?) ORDER BY seq ASC",
            [.text(session), SQLiteValue(max(0, limit))])
        return rows.compactMap(Self.turn(from:))
    }

    @discardableResult
    public func clearConversation(session: String) throws -> Int {
        try connection.run("DELETE FROM conversation_turns WHERE session_id = ?", [.text(session)])
    }

    @discardableResult
    public func clearAllConversations() throws -> Int {
        try connection.run("DELETE FROM conversation_turns")
    }

    /// Sessions by most recent activity; the title is the first thing the user said.
    public func sessions(limit: Int = 20) throws -> [ConversationSession] {
        let rows = try connection.query(
            """
            SELECT session_id, MAX(created_at) AS last_activity, COUNT(*) AS turn_count,
                (SELECT text FROM conversation_turns u WHERE u.session_id = t.session_id AND u.role = 'user' ORDER BY u.seq LIMIT 1) AS title
            FROM conversation_turns t GROUP BY session_id ORDER BY last_activity DESC LIMIT ?
            """,
            [SQLiteValue(max(0, limit))])
        return rows.compactMap { row in
            guard let id = row.string("session_id"), let last = row.date("last_activity") else { return nil }
            return ConversationSession(id: id, title: row.string("title"), lastActivity: last, turnCount: row.int("turn_count") ?? 0)
        }
    }

    public func turnCount(session: String? = nil) throws -> Int {
        if let session { return try connection.scalarInt("SELECT COUNT(*) FROM conversation_turns WHERE session_id = ?", [.text(session)]) }
        return try connection.scalarInt("SELECT COUNT(*) FROM conversation_turns")
    }

    private static func turn(from row: SQLiteRow) -> ConversationTurn? {
        guard let id = row.string("id").flatMap(UUID.init(uuidString:)), let session = row.string("session_id"),
            let role = row.string("role"), let text = row.string("text"), let created = row.date("created_at")
        else { return nil }
        return ConversationTurn(
            id: id, sessionID: session, role: role, text: text, language: row.string("language"), createdAt: created,
            toolSummary: row.string("tool_summary"))
    }

    // MARK: - Task memory

    /// Inserts the record, or replaces the one with the same id.
    public func recordTask(_ record: TaskRecord) throws {
        let payload = try record.payload.map { value -> String in
            guard let text = String(data: try JSONEncoder().encode(value), encoding: .utf8) else { throw MemoryError.encoding("task payload") }
            return text
        }
        try connection.run(
            """
            INSERT INTO tasks (id, title, status, created_at, updated_at, detail, payload) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, status = excluded.status, updated_at = excluded.updated_at,
                detail = excluded.detail, payload = excluded.payload
            """,
            [.text(record.id.uuidString), .text(record.title), .text(record.status), SQLiteValue(record.createdAt), SQLiteValue(record.updatedAt), SQLiteValue(record.detail), SQLiteValue(payload)])
    }

    /// Changes a task's status (and detail when given) and returns the stored record.
    @discardableResult
    public func updateTask(id: UUID, status: String, detail: String? = nil, now: Date = Date()) throws -> TaskRecord {
        let changed: Int
        if let detail {
            changed = try connection.run("UPDATE tasks SET status = ?, detail = ?, updated_at = ? WHERE id = ?", [.text(status), .text(detail), SQLiteValue(now), .text(id.uuidString)])
        } else {
            changed = try connection.run("UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?", [.text(status), SQLiteValue(now), .text(id.uuidString)])
        }
        guard changed > 0, let record = try task(id: id) else { throw MemoryError.notFound }
        return record
    }

    /// Tasks most recently updated first, optionally filtered by status.
    public func tasks(status: String? = nil, limit: Int = 50) throws -> [TaskRecord] {
        let rows: [SQLiteRow]
        if let status {
            rows = try connection.query("SELECT * FROM tasks WHERE status = ? ORDER BY updated_at DESC LIMIT ?", [.text(status), SQLiteValue(max(0, limit))])
        } else {
            rows = try connection.query("SELECT * FROM tasks ORDER BY updated_at DESC LIMIT ?", [SQLiteValue(max(0, limit))])
        }
        return try rows.compactMap(Self.task(from:))
    }

    public func task(id: UUID) throws -> TaskRecord? {
        try connection.query("SELECT * FROM tasks WHERE id = ?", [.text(id.uuidString)]).first.flatMap(Self.task(from:))
    }

    public func deleteTask(id: UUID) throws {
        guard try connection.run("DELETE FROM tasks WHERE id = ?", [.text(id.uuidString)]) > 0 else { throw MemoryError.notFound }
    }

    private static func task(from row: SQLiteRow) throws -> TaskRecord? {
        guard let id = row.string("id").flatMap(UUID.init(uuidString:)), let title = row.string("title"), let status = row.string("status"),
            let created = row.date("created_at"), let updated = row.date("updated_at")
        else { return nil }
        var payload: JSONValue?
        if let text = row.string("payload"), let data = text.data(using: .utf8) {
            do { payload = try JSONDecoder().decode(JSONValue.self, from: data) } catch { throw MemoryError.encoding("task payload") }
        }
        return TaskRecord(id: id, title: title, status: status, createdAt: created, updatedAt: updated, detail: row.string("detail"), payload: payload)
    }

    // MARK: - Routines

    /// Saves a routine, replacing an existing one with the same (folded) name.
    @discardableResult
    public func saveRoutine(name: String, phrases: [String], steps: [ToolCall], now: Date = Date()) throws -> Routine {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !name.isEmpty else { throw MemoryError.invalidInput("routine name is empty") }
        guard !phrases.isEmpty else { throw MemoryError.invalidInput("a routine needs at least one trigger phrase") }
        guard !steps.isEmpty else { throw MemoryError.invalidInput("a routine needs at least one step") }
        let foldedName = TextFolding.fold(name)
        let existing = try routine(named: name)
        let routine = Routine(
            id: existing?.id ?? UUID(), name: name, phrases: phrases, steps: steps, createdAt: existing?.createdAt ?? now,
            lastRunAt: existing?.lastRunAt, runCount: existing?.runCount ?? 0)
        try connection.run(
            """
            INSERT INTO routines (id, name, folded_name, phrases, steps, created_at, last_run_at, run_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, folded_name = excluded.folded_name, phrases = excluded.phrases, steps = excluded.steps
            """,
            [
                .text(routine.id.uuidString), .text(name), .text(foldedName), .text(try Self.encodeJSON(phrases, what: "routine phrases")),
                .text(try Self.encodeJSON(steps, what: "routine steps")), SQLiteValue(routine.createdAt), SQLiteValue(routine.lastRunAt),
                SQLiteValue(routine.runCount),
            ])
        return routine
    }

    public func routines() throws -> [Routine] {
        try connection.query("SELECT * FROM routines ORDER BY name COLLATE NOCASE").compactMap(Self.routine(from:))
    }

    public func routine(id: UUID) throws -> Routine? {
        try connection.query("SELECT * FROM routines WHERE id = ?", [.text(id.uuidString)]).first.flatMap(Self.routine(from:))
    }

    public func routine(named name: String) throws -> Routine? {
        try connection.query("SELECT * FROM routines WHERE folded_name = ?", [.text(TextFolding.fold(name))]).first.flatMap(Self.routine(from:))
    }

    public func deleteRoutine(id: UUID) throws {
        guard try connection.run("DELETE FROM routines WHERE id = ?", [.text(id.uuidString)]) > 0 else { throw MemoryError.notFound }
    }

    /// The routine one of whose trigger phrases best matches `text`: the folded text contains the folded phrase, or
    /// the two are at least 85 % similar (Damerau-Levenshtein), so "empieza a estudiar" triggers "empezar a estudiar".
    public func findRoutine(matching text: String) throws -> Routine? {
        var best: (routine: Routine, score: Double)?
        for routine in try routines() {
            for phrase in routine.phrases {
                guard let score = PhraseMatching.score(text: text, phrase: phrase) else { continue }
                if best == nil || score > best!.score { best = (routine, score) }
            }
        }
        return best?.routine
    }

    public func markRoutineRun(id: UUID, now: Date = Date()) throws {
        let changed = try connection.run("UPDATE routines SET last_run_at = ?, run_count = run_count + 1 WHERE id = ?", [SQLiteValue(now), .text(id.uuidString)])
        guard changed > 0 else { throw MemoryError.notFound }
    }

    private static func routine(from row: SQLiteRow) -> Routine? {
        guard let id = row.string("id").flatMap(UUID.init(uuidString:)), let name = row.string("name"), let created = row.date("created_at"),
            let phrases: [String] = try? decodeJSON(row.string("phrases") ?? "[]", what: "routine phrases"),
            let steps: [ToolCall] = try? decodeJSON(row.string("steps") ?? "[]", what: "routine steps")
        else { return nil }
        return Routine(id: id, name: name, phrases: phrases, steps: steps, createdAt: created, lastRunAt: row.date("last_run_at"), runCount: row.int("run_count") ?? 0)
    }

    private static func encodeJSON<T: Encodable>(_ value: T, what: String) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let text = String(data: try encoder.encode(value), encoding: .utf8) else { throw MemoryError.encoding(what) }
            return text
        } catch let error as MemoryError {
            throw error
        } catch {
            throw MemoryError.encoding(what)
        }
    }

    private static func decodeJSON<T: Decodable>(_ text: String, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw MemoryError.encoding(what)
        }
    }

    // MARK: - Export

    /// Everything in the store as pretty-printed JSON (see ``MemoryExport``).
    public func export(now: Date = Date()) throws -> Data {
        let snapshot = MemoryExport(
            exportedAt: now, enabled: enabled, retentionDays: retention,
            items: try fetchItems("ORDER BY created_at", [], limit: Int(Int32.max)),
            conversations: try connection.query("SELECT * FROM conversation_turns ORDER BY seq").compactMap(Self.turn(from:)),
            tasks: try tasks(limit: Int(Int32.max)), routines: try routines())
        do {
            return try MemoryExport.encoder.encode(snapshot)
        } catch {
            throw MemoryError.encoding("export")
        }
    }

    /// Loads an export produced by ``export(now:)``, adding to (and updating) what is already stored.
    /// Returns the number of records read.
    @discardableResult
    public func restore(_ data: Data) throws -> Int {
        let snapshot: MemoryExport
        do {
            snapshot = try MemoryExport.decoder.decode(MemoryExport.self, from: data)
        } catch {
            throw MemoryError.encoding("export")
        }
        try connection.transaction {
            for item in snapshot.items {
                let folded = Self.searchText(key: item.key, content: item.content)
                try connection.run(
                    """
                    INSERT INTO memory_items (id, kind, key, content, folded, source, created_at, updated_at, last_used_at, use_count, pinned)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, key = excluded.key, content = excluded.content, folded = excluded.folded,
                        source = excluded.source, updated_at = excluded.updated_at, last_used_at = excluded.last_used_at,
                        use_count = excluded.use_count, pinned = excluded.pinned
                    ON CONFLICT(key) WHERE key IS NOT NULL DO UPDATE SET content = excluded.content, folded = excluded.folded, updated_at = excluded.updated_at
                    """,
                    [
                        .text(item.id.uuidString), .text(item.kind.rawValue), SQLiteValue(item.key), .text(item.content), .text(folded),
                        .text(item.source), SQLiteValue(item.createdAt), SQLiteValue(item.updatedAt), SQLiteValue(item.lastUsedAt),
                        SQLiteValue(item.useCount), SQLiteValue(item.pinned),
                    ])
            }
            if hasFullTextSearch {
                try connection.run("DELETE FROM memory_fts")
                try connection.run("INSERT INTO memory_fts (item_id, folded) SELECT id, folded FROM memory_items")
            }
            for turn in snapshot.conversations {
                try connection.run(
                    "INSERT OR IGNORE INTO conversation_turns (id, session_id, role, text, language, created_at, tool_summary) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.text(turn.id.uuidString), .text(turn.sessionID), .text(turn.role), .text(turn.text), SQLiteValue(turn.language), SQLiteValue(turn.createdAt), SQLiteValue(turn.toolSummary)])
            }
            for task in snapshot.tasks { try recordTask(task) }
            for routine in snapshot.routines {
                try connection.run(
                    """
                    INSERT INTO routines (id, name, folded_name, phrases, steps, created_at, last_run_at, run_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, folded_name = excluded.folded_name, phrases = excluded.phrases,
                        steps = excluded.steps, last_run_at = excluded.last_run_at, run_count = excluded.run_count
                    ON CONFLICT(folded_name) DO UPDATE SET phrases = excluded.phrases, steps = excluded.steps
                    """,
                    [
                        .text(routine.id.uuidString), .text(routine.name), .text(TextFolding.fold(routine.name)),
                        .text(try Self.encodeJSON(routine.phrases, what: "routine phrases")), .text(try Self.encodeJSON(routine.steps, what: "routine steps")),
                        SQLiteValue(routine.createdAt), SQLiteValue(routine.lastRunAt), SQLiteValue(routine.runCount),
                    ])
            }
        }
        return snapshot.items.count + snapshot.conversations.count + snapshot.tasks.count + snapshot.routines.count
    }
}
